{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE NamedFieldPuns #-}
module Todou.Store where


import Amazonka qualified
import Amazonka.S3 qualified as Amazonka
import Amazonka.S3.GetObject qualified
import Amazonka.S3.ListObjectsV2 qualified as Amazonka
import Amazonka.S3.Types.Object (Object(..))
import Conduit qualified
import Control.Applicative (Alternative((<|>)))
import Control.Concurrent (threadDelay, forkIO, ThreadId, readMVar, modifyMVar_, modifyMVar)
import Control.Concurrent.MVar (MVar, newMVar)
import Control.Exception (try, SomeException, Exception (..))
import Control.Monad (unless, forM_, forever, join, void, guard)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isSpace)
import Data.Coerce (coerce)
import Data.Functor ((<&>))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, maybeToList, isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.IO qualified as Text
import Data.Time
    ( Day,
      defaultTimeLocale,
      parseTimeM,
      formatTime, addDays, diffDays)
import Network.URI qualified as URI
import System.Directory (listDirectory)
import System.Environment qualified as Environment
import System.FilePath (takeExtension, (</>), takeBaseName)
import Text.Read (readMaybe)
import Data.Bits (Bits(..))
import Data.Bifunctor (Bifunctor(..))
import Data.Word (Word8)
import Todou.Domain.Todo (Todo(..), Entry (..), Todo (..), EntryId (..), Buffer (..), pattern TodoLoaded, pattern TodoNotExists, pattern TodoNotLoaded, getBufferDayRange)
import Todou.Option ( Bucket, StorageOption(..) )


------------------------------
-- Parsing


data IniSection
  = EntrySection Entry
  | MetaSection Day
  deriving Show


trim :: Text -> Text
trim = Text.dropAround isSpace


parseKVs :: [Text] -> ([(Text, Text)], [Text])
parseKVs [] = ([], [])
parseKVs (l:ls)
  | Text.null (Text.strip l) = parseKVs ls          -- Skip empty lines
  | "[" `Text.isPrefixOf` Text.strip l = ([], l:ls) -- Stop at next section
  | otherwise =
      case Text.breakOn "=" l of
        (k, v) | not (Text.null v) ->
          let key                   = Text.strip k
              firstVal              = Text.drop 1 v -- drop the '='
              (fullVal, rest)       = collectMultiline firstVal ls
              nextKV                = (key, Text.strip fullVal)
              (otherKVs, finalRest) = parseKVs rest
          in (nextKV : otherKVs, finalRest)
        _ -> parseKVs ls                            -- Ignore lines without '='


collectMultiline :: Text -> [Text] -> (Text, [Text])
collectMultiline currentVal [] = (currentVal, [])
collectMultiline currentVal (l:ls) =
  let trimmed = Text.stripEnd currentVal
  in if "\\" `Text.isSuffixOf` trimmed
     then collectMultiline (Text.dropEnd 1 trimmed <> "\n" <> l) ls
     else (currentVal, l:ls)


parseEntry :: [Text] -> Maybe Entry
parseEntry [] = Nothing
parseEntry (l:ls) = do
  guard ("[entry]" `Text.isPrefixOf` l)

  let kvs      = fst (parseKVs ls)
  entryId     <- lookup "id" kvs >>= readMaybe . Text.unpack <&> EntryId
  description <- lookup "description" kvs
  let detail   = fromMaybe "" (lookup "detail" kvs)
  let tags     = fromMaybe mempty (lookup "tags" kvs <&> Text.words)

  pure Entry
    { entryId       = entryId
    , description   = description
    , detail        = detail
    , tags          = tags
    , completedDate = lookup "completedDate" kvs >>= parseDate . Text.unpack
    }


parseDate :: String -> Maybe Day
parseDate = parseTimeM True defaultTimeLocale "%Y-%m-%d"


parseMeta :: [Text] -> Maybe Day
parseMeta []     = Nothing
parseMeta (l:ls) = do
  guard ("[date]" `Text.isPrefixOf` l)
  let kvs = fst (parseKVs ls)
  lookup "date" kvs >>= parseDate . Text.unpack


parseSection :: [Text] -> Maybe IniSection
parseSection ls = do
  EntrySection <$> parseEntry ls
  <|> MetaSection <$> parseMeta ls


-- | Split a file into list of entries
splitSections  :: [Text] -> [[Text]]
splitSections = snd . foldr
  (\line (buf, result) ->
    let stripped = Text.strip line
     in
      if "[" `Text.isPrefixOf` stripped
         then ([], filter (/= mempty) (line:buf):result)
         else (line:buf, result)
    )
  ([], [])


parseIni :: Text -> Maybe [IniSection]
parseIni txt = traverse parseSection (splitSections . Text.lines  $ txt)


parseTodo :: Text -> Maybe Todo
parseTodo txt = do
  sections <- parseIni txt
  let (entries, mDate) = foldr (\section (es, md) ->
        case section of
          EntrySection e   -> (e:es, md)
          MetaSection date -> (es, Just date)
        )
        ([], Nothing)
        sections
  date <- mDate
  pure Todo
    { entries = entries
    , date    = date
    , dirty   = False
    }


dumpTodo :: Todo -> Text
dumpTodo (Todo { entries, date }) = Text.unlines (fmap Text.unlines ls)
  where
    ls = mconcat
        [ [ dumpDate date ]
        , fmap dumpEntry entries
        ]


dumpDate :: Day -> [Text]
dumpDate date =
  [ "[date]"
  , Text.pack ("date = " <> formatTime defaultTimeLocale  "%Y-%m-%d" date)
  ]


dumpEntry :: Entry -> [Text]
dumpEntry (Entry { entryId = EntryId entryId, description, detail, tags, completedDate }) =
  [ "[entry]"
  , "id = " <> Text.pack (show entryId)
  , "description = " <> (formatMultiline description)
  , "detail = " <>  (formatMultiline detail)
  , "tags = " <> Text.unwords tags
  , case completedDate of
      Just day -> "completedDate = " <> (Text.pack (formatTime defaultTimeLocale "%Y-%m-%d" day))
      Nothing  -> mempty
  ]


-- | Converts internal newlines into the " \ " continuation format
-- Trailing newlines are removed.
formatMultiline :: Text -> Text
formatMultiline txt =
  Text.replace "\n" " \\\n" (Text.stripEnd txt)


------------------------------
-- Storage.S3


createS3Env :: IO Amazonka.Env
createS3Env = do
  mUrl <- lookupAWSEndpointURL
  let setEndpointURL =
        case mUrl of
          Just url ->
            case url.uriAuthority of
              Nothing -> id
              Just auth -> do
                let host = Char8.pack auth.uriRegName
                let port = fromMaybe 443 . readMaybe $ auth.uriPort
                Amazonka.setEndpoint True host port
          Nothing -> id
  let service = setEndpointURL Amazonka.defaultService
  Amazonka.configureService service <$> Amazonka.newEnv Amazonka.discover
  where
    lookupAWSEndpointURL = do
      Environment.lookupEnv "AWS_ENDPOINT_URL" <&> \case
        Nothing -> Nothing
        Just "" -> Nothing
        Just v  -> URI.parseURI v


------------------------------
-- Handle


data Handle
  = FileSystemHandle FilePath (MVar Buffer)
  | S3Handle Amazonka.Env Bucket (MVar Buffer)


-- | Create a new handle with all state required to operate the storage.
createHandle :: StorageOption -> IO Handle
createHandle options = do
  case options of
    StorageFileSystem dir -> do
      files <- filter (\path -> takeExtension path == ".todou") <$> listDirectory dir
      let todos =
            foldr (\path acc -> do
                      let dateStr = takeBaseName path
                      case parseTimeM @Maybe @Day True defaultTimeLocale "%Y-%m-%d" dateStr of
                        Just day -> Map.insert day Nothing acc
                        Nothing -> acc
                  )
                  mempty
                  files
      ref <- newMVar Buffer { todos = todos, dirtyCounts = 0 }
      pure $ FileSystemHandle dir ref

    StorageS3 bucket -> do
      env <- createS3Env
      let request = Amazonka.newListObjectsV2 (Amazonka.BucketName bucket)
      resp <- Amazonka.runResourceT $ Amazonka.send env request
      let dates = fmap (\o -> coerce o.key) (fromMaybe []  resp.contents)
      let todos =
            foldr (\date acc -> do
                      case parseTimeM @Maybe @Day True defaultTimeLocale "%Y-%m-%d" (Text.unpack date) of
                        Just day -> Map.insert day Nothing acc
                        Nothing -> acc
                  )
                  mempty
                  dates
      ref <- newMVar Buffer { todos = todos, dirtyCounts = 0 }
      pure $ S3Handle env bucket ref

    StorageNull ->
      error "impossible"


getBufferMVar :: Handle -> MVar Buffer
getBufferMVar ((FileSystemHandle _ bufferMvar )) = bufferMvar
getBufferMVar ((S3Handle _ _ bufferMvar ))       = bufferMvar


withBuffer :: Handle -> (Buffer -> IO (Buffer, a)) -> IO a
withBuffer handle = modifyMVar (getBufferMVar handle)


getBuffer :: Handle -> IO Buffer
getBuffer handle = readMVar $ getBufferMVar handle


modifyBuffer :: Handle -> (Buffer -> IO Buffer) -> IO ()
modifyBuffer handle = modifyMVar_ (getBufferMVar handle)


-- | Load Todo if it's not already cached in Buffer.
loadTodo :: Handle -> Day -> IO (Maybe Todo)
loadTodo handle date = do
  modifyBuffer handle \buffer -> do
    case Map.lookup date buffer.todos of
      TodoLoaded _ -> pure buffer
      TodoNotExists -> pure buffer
      TodoNotLoaded -> loadTodoFromStorage handle date buffer
  buffer <- readMVar (getBufferMVar handle)
  pure do
    join (Map.lookup date buffer.todos)


loadTodoFromStorage :: Handle -> Day -> Buffer -> IO Buffer
loadTodoFromStorage handle date buffer = do
  let dateStr = formatTime defaultTimeLocale  "%Y-%m-%d" date
  case handle of
    FileSystemHandle dir _ -> do
      mTodo <- parseTodo <$> Text.readFile (dir </> dateStr <> ".todou")
      case mTodo of
        Just todo -> pure do
          buffer { todos = Map.alter (\_ -> TodoLoaded todo) date buffer.todos }
        Nothing -> pure buffer
    S3Handle env bucket _ -> do
      let request = Amazonka.newGetObject (Amazonka.BucketName bucket) (Amazonka.ObjectKey (Text.pack dateStr))
      chunks <- Amazonka.runResourceT do
        resp <- Amazonka.send env request
        Conduit.runConduit $ resp.body.body Conduit..| Conduit.sinkList
      let mTodo = parseTodo . Text.decodeUtf8 . LBS.toStrict . LBS.fromChunks $ chunks
      case mTodo of
        Just todo -> pure do
          buffer { todos = Map.alter (\_ -> TodoLoaded todo) date buffer.todos }
        Nothing -> pure buffer


-- | Load all todos into model
loadAllTodos :: Handle -> Day -> Day -> IO ()
loadAllTodos handle from to =
  let loop d = do
        _ <- loadTodo handle d
        if d > to
           then pure ()
           else do
             loop (1 `addDays` d)
   in loop from


-- | Flush in memory todo to storage
flush :: Handle -> IO ()
flush handle = do
  modifyBuffer handle \buffer -> do
    unless (buffer.dirtyCounts == 0) do
      forM_ buffer.todos \case
        Nothing -> pure ()
        Just (Todo { dirty = False }) -> pure ()
        Just todo@(Todo { dirty = True }) -> flushOnDirty handle todo
    pure $ buffer
      { dirtyCounts = 0
      , todos = Map.map (fmap (\todo -> if todo.dirty then todo { dirty = False } else todo)) buffer.todos
      }


flushOnDirty :: Handle -> Todo -> IO ()
flushOnDirty handle todo@(Todo { date }) = do
  let dateStr = formatTime defaultTimeLocale  "%Y-%m-%d" date
  case handle of
    FileSystemHandle dirPath _ -> do
      let path = dirPath </> dateStr <> ".todou"
      Text.writeFile path (dumpTodo todo)
    S3Handle env bucket _ -> do
      let req = Amazonka.newPutObject
            (Amazonka.BucketName bucket)
            (Amazonka.ObjectKey (Text.pack dateStr))
            (Amazonka.toBody (dumpTodo todo))
      void . Amazonka.runResourceT $ Amazonka.send env req


-- | A presence map is a fixed size bitset. The size of the bitset is
-- propotional to the total days between the first and last recorded day
-- day with a todo record.
-- Each day corresponds to 2 bits
--  - m & 1        : whether the day is present
--  - m & (1 << 1) : whether all enties is completed
--
-- A byte can reside 4 such units, each unit is called a segment. This bit
-- set structure need to be unpacked by the frontend.
getPresences :: Buffer -> IO (Maybe (ByteString, Day))
getPresences buffer@Buffer { todos } =
  case getBufferDayRange buffer of
    Nothing         -> pure Nothing
    Just (from, to) -> do
      let cleanup (d, mTodo) = case mTodo of
                                 Just (Todo { entries = []} ) -> Nothing
                                 Nothing                      -> Nothing
                                 other                        -> Just (d, other)
          collect = \mTodo -> case mTodo of
                                Just (Todo { entries }) ->
                                  [ all (isJust . (.completedDate)) entries -- completed
                                  ]
                                Nothing -> []
          summary = -- a map from Day to bools.
            Map.fromList
            . fmap (second collect)
            . mconcat
            . fmap maybeToList
            . fmap cleanup
            $ Map.toList todos

      let bytes = daysToBytes summary from to
      pure (Just (bytes, from))
  where
    bitsPerDay = 2 -- this is the total bits per day.

    daysToBytes :: Map Day [Bool] -> Day -> Day -> ByteString
    daysToBytes summary start end = fst (ByteString.unfoldrN nBytes go start)
      where
        totalDays = fromIntegral (diffDays end start + 1)
        nBytes    = ((bitsPerDay * totalDays) + 7) `div` 8
        go d
          | d > end   = Nothing
          | otherwise = Just (packOneByte d 0 0)

        packOneByte d idx acc
          | idx >= 8 || d > end = (acc, d)
          | otherwise           = case Map.lookup d summary of
                                    -- day presents, set presence bits
                                    Just flags -> packOneByte (addDays 1 d) (idx + bitsPerDay)
                                                $ let setOn True c  = flip (setBit @Word8) c
                                                      setOn False _ = id
                                                   in case flags of
                                                        (completed:_) ->
                                                          setOn completed (idx + 1)    -- bit 1
                                                          $ setBit acc idx             -- bit 0
                                                        _ -> error "invalid flag format"
                                    -- skip
                                    Nothing -> packOneByte (addDays 1 d) (idx + bitsPerDay) acc


------------------------------
-- Daemon


spawnFlusher :: Handle -> IO ThreadId
spawnFlusher handle = forkIO . forever $ do
  result <- try  do flush handle
  case result of
    Left (e :: SomeException) -> putStrLn (displayException e)
    Right _ -> pure ()
  threadDelay flushPeriod
  where
    flushPeriod = 5 * 1000000
