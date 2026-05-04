{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE PatternSynonyms #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Todou.Server where
-- Backend for Todou app

import Control.Concurrent (readMVar)
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO(..))
import Data.Aeson (ToJSON(..), (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.FileEmbed (embedFileRelative)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.String.Interpolate (iii)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Lazy qualified as LText
import Data.Text.Lazy.Encoding qualified as LText
import Data.Time
    ( Day,
      defaultTimeLocale,
      parseTimeM,
      formatTime,
      getCurrentTime,
      utcToLocalTime,
      utc,
      LocalTime(..),
      fromGregorian)
import Lucid (Html, head_, meta_, div_, link_, title_, body_, rel_, href_, httpEquiv_, content_, charset_, lang_, name_, html_, id_, script_, src_, type_, sizes_)
import Lucid qualified
import Network.HTTP.Types (status500)
import Network.Wai.Middleware.RequestLogger (logStdout)
import Text.Read (readMaybe)
import Web.Scotty (get, scotty, html, raw, setHeader, post, Parsable(..), json, ActionM, body, captureParam, status, text, middleware, delete, redirect, put, queryParamMaybe, captureParamMaybe, header, formParamMaybe, notFound)
import Web.Cookie (parseCookies)
import Data.Time.Calendar.Month (pattern MonthDay, Month)
import Todou.Domain.Stat (CFR (..), createCFSegmentFromMonth)
import Todou.Domain.Todo (Todo(..), Entry (..), Todo (..), EntryId (..), Buffer (..), pattern TodoLoaded, pattern TodoNotExists, pattern TodoNotLoaded, Model(..), updateTodo, deleteEntry, updateEntry, insertTodo, todoToModel)
import Todou.Domain.Stat qualified as Stat
import Todou.Option
import Todou.Store (Handle, getBufferMVar, flush, getPresences, loadTodo, modifyBuffer)
import Web.Scotty.Trans (ActionT)
import Data.List (iterate')


------------------------------
-- Orphan


instance Parsable Day where
  parseParam s =
    case parseTimeM @Maybe @Day True defaultTimeLocale "%Y-%m-%d" (LText.unpack s) of
      Just date -> Right date
      Nothing   -> Left  "Invalid date format. expecting: %Y-%m-%d"


instance Parsable Month where
  parseParam s =
    case parseTimeM @Maybe @Month True defaultTimeLocale "%Y-%m" (LText.unpack s) of
      Just month -> Right month
      Nothing   -> Left  "Invalid date format. expecting: %Y-%m"


instance Parsable EntryId where
  parseParam s =
    case readMaybe (Text.unpack . LText.toStrict $ s) of
      Just n  -> Right (EntryId n)
      Nothing -> Left "Invalid EntryId"


------------------------------
-- Server


newtype Ok a = Ok a


instance ToJSON a => ToJSON (Ok a) where
  toJSON (Ok a) =
    Aeson.object
      [ "ok"   .= True
      , "data" .=  a
      ]

newtype Err a = Err a


instance ToJSON a => ToJSON (Err a) where
  toJSON (Err e) =
    Aeson.object
      [ "ok"  .= False
      , "err" .= e
      ]


raw' :: ByteString -> ActionM ()
raw' = raw . ByteString.fromStrict


json', javascript, css, png, ico, svg, plain :: ByteString -> ActionM ()
json' bytes      = setHeader "Content-Type" "application/json" >> raw' bytes
javascript bytes = setHeader "Content-Type" "application/javascript" >> raw' bytes
css bytes        = setHeader "Content-Type" "text/css" >> raw' bytes
png bytes        = setHeader "Content-Type" "image/png" >> raw' bytes
ico bytes        = setHeader "Content-Type" "image/vnd.microsoft.icon" >> raw' bytes
svg bytes        = setHeader "Content-Type" "image/svg+xml" >> raw' bytes
plain bytes      = setHeader "Content-Type" "text/plain" >> raw' bytes


-- A tranpoline page that sets the cookies
trampoline :: Text -> Html ()
trampoline href =
  html_ do
    head_ do
      script_ do
        [iii| let timezone = new Intl.DateTimeFormat('en-US', { timeZoneName: 'short' })
                        .formatToParts(new Date())
                        .find(part => part.type === 'timeZoneName')
                        .value;
                      document.cookie = "timezone=; path=/; max-age=0";
                      document.cookie = `timezone=${timezone}; path=/; max-age=${7*24*60*60}`;
                      window.location.href = "#{href}"
                    |]


-- | The initial html with the SPA code. A script will write the current date
-- string into the `window` object. The frontend code will use this date string
-- to route to a todo page locally.
initView :: LocalTime -> Html ()
initView localTime =
  html_ [ lang_ "en" ] do
    head_ do
      meta_ [ charset_ "UTF-8" ]
      meta_ [ name_ "viewport", content_ "width=device-width, initial-scale=1.0, viewport-fit=cover, maximum-scale=1, user-scalable=no" ]
      meta_ [ httpEquiv_ "X-UA-Compatible", content_ "ie=edge" ]
      meta_ [ name_ "mobile-web-app-capable", content_ "yes" ]
      meta_ [ name_ "apple-mobile-web-app-capable", content_ "yes" ]
      meta_ [ name_ "apple-mobile-web-app-title", content_ "Todou"]
      meta_ [ name_ "apple-mobile-web-app-status-bar-style", content_ "default" ]
      link_ [ rel_ "apple-touch-icon", sizes_ "180x180", href_ "/apple-touch-icon.png"]
      link_ [ rel_ "stylesheet", href_ "/main.css" ]
      link_ [ rel_ "manifest", href_ "/manifest.json" ]
      title_ "Todou"
    body_ do
      div_ [ id_ "app" ] mempty
      let date = LText.decodeUtf8 (Aeson.encode (localTime.localDay))
      script_ [iii| window.__INITIAL__DATE__ = #{date} |]
      script_ [ src_ "main.js", type_ "module" ] (mempty @Text)


nowInlocalTime :: MonadIO m => ByteString -> m LocalTime
nowInlocalTime tz = do
  now <- liftIO getCurrentTime
  let timeZone  = fromMaybe utc (readMaybe (Char8.unpack tz))
  pure (utcToLocalTime timeZone now)


formatDayYMD :: Day -> Text
formatDayYMD d = Text.pack (formatTime defaultTimeLocale  "%Y-%m-%d" d)


getTimeZoneFromCookies :: ActionT IO (Maybe ByteString)
getTimeZoneFromCookies = do
  mCookies <- header "Cookie"
  pure (mCookies >>= lookup "timezone" . parseCookies . Text.encodeUtf8 . LText.toStrict)


index :: ActionT IO ()
index = do
  getTimeZoneFromCookies >>= \case
    Just tz -> do
      localTime <- nowInlocalTime tz
      html . Lucid.renderText $ initView localTime
    Nothing -> html . Lucid.renderText $ trampoline "/"


server :: Options -> Handle -> IO ()
server Options { port, quite } handle = scotty port do
  when (not quite) do
    middleware logStdout

  -- static files are embeded.
  get "/main.js"                      do javascript $(embedFileRelative "data/todou/main.js")
  get "/todo.js"                      do javascript $(embedFileRelative "data/todou/todo.js")
  get "/stat.js"                      do javascript $(embedFileRelative "data/todou/stat.js")
  get "/lib.js"                       do javascript $(embedFileRelative "data/todou/lib.js")
  get "/vdom.js"                      do javascript $(embedFileRelative "data/todou/vdom.js")
  get "/web-app-manifest-192x192.png" do png        $(embedFileRelative "data/todou/web-app-manifest-192x192.png")
  get "/web-app-manifest-512x512.png" do png        $(embedFileRelative "data/todou/web-app-manifest-512x512.png")
  get "/apple-touch-icon.png"         do png        $(embedFileRelative "data/todou/apple-touch-icon.png")
  get "/favicon.ico"                  do ico        $(embedFileRelative "data/todou/favicon.ico")
  get "/manifest.json"                do json'      $(embedFileRelative "data/todou/manifest.json")
  get "/main.css"                     do css        $(embedFileRelative "data/todou/main.css")
  get "/left-arrow.svg"               do svg        $(embedFileRelative "data/todou/left-arrow.svg")
  get "/right-arrow.svg"              do svg        $(embedFileRelative "data/todou/right-arrow.svg")
  get "/x.svg"                        do svg        $(embedFileRelative "data/todou/x.svg")
  get "/calendar.svg"                 do svg        $(embedFileRelative "data/todou/calendar.svg")
  get "/today.svg"                    do svg        $(embedFileRelative "data/todou/today.svg")
  get "/stat.svg"                     do svg        $(embedFileRelative "data/todou/stat.svg")
  get "/back.svg"                     do svg        $(embedFileRelative "data/todou/back.svg")
  get "/favicon.svg"                  do svg        $(embedFileRelative "data/todou/favicon.svg")
  get "/rev"                          do plain      $(embedFileRelative "data/todou/rev")


  get "/" index


  -- render the todo data for one date.
  get "/api/todo/:date" do
    date <- captureParam @Day "date"

    when (date > fromGregorian 9999 12 31) do
      redirect "/404"

    let bufferMvar = getBufferMVar handle

    buffer <- liftIO do
      flush handle -- flush on refresh
      readMVar bufferMvar

    (presenceMap, firstDay) <- liftIO $ getPresences buffer >>= \case
      Just (p, d) -> pure (p, Just d)
      Nothing -> pure ("", Nothing)

    eModel <- case Map.lookup date buffer.todos of
      TodoLoaded todo -> do
        pure (Right (todoToModel todo))
      TodoNotLoaded -> do
        liftIO (loadTodo handle date) >>= \case
          Just todo -> pure (Right (todoToModel todo))
          Nothing   -> pure (Left "Can't find the todo data")
      TodoNotExists -> do -- not in storage, create an empty one
        let newTodo = Todo { entries = [], date = date, dirty = True }
        pure (Right (todoToModel newTodo))

    case eModel of
      Right model -> do
        json model
          { presenceMap = presenceMap
          , firstDay    = firstDay
          }
      Left err -> do
        status status500
        text err


  -- Show statistic page
  get "/api/stat" do

    getTimeZoneFromCookies >>= \case
      Just tz -> do
        date <- queryParamMaybe @Day "date" >>= \case
          Just d  -> pure d
          Nothing -> do
            localTime <- nowInlocalTime tz
            pure localTime.localDay

        let bufferMvar = getBufferMVar handle

        buffer <- liftIO do
          flush handle -- flush on refresh
          readMVar bufferMvar

        (presenceMap, firstDay) <- liftIO $ getPresences buffer >>= \case
          Just (p, d) -> pure (p, Just d)
          Nothing -> pure ("", Nothing)

        let MonthDay month _ = date
            months = iterate' pred month
            start1 = months !! 0
            start2 = months !! 1
            start3 = months !! 2
            end    = month
            seg1   = foldr1 (<>) [ createCFSegmentFromMonth m buffer.todos | m <- [start1..end] ]
            seg2   = foldr1 (<>) [ createCFSegmentFromMonth m buffer.todos | m <- [start2..end] ]
            seg3   = foldr1 (<>) [ createCFSegmentFromMonth m buffer.todos | m <- [start3..end] ]

        json Stat.Model { date        = date
                        , cfd1Month   = Stat.toCFD (CFRMonthRange start1 end) seg1
                        , cfd2Month   = Stat.toCFD (CFRMonthRange start2 end) seg2
                        , cfd3Month   = Stat.toCFD (CFRMonthRange start3 end) seg3
                        , presenceMap = presenceMap
                        , firstDay    = firstDay
                        }

      Nothing ->
        html . Lucid.renderText $ trampoline "/stat"


  -- add a new entry
  post "/api/entry/:date/:id" do
    date        <- captureParam @Day "date"
    entryId     <- captureParam @EntryId "id"
    description <- Text.decodeUtf8 . ByteString.toStrict <$> body
    let newEntry =
          Entry
            { entryId       = entryId
            , description   = description
            , detail        = ""
            , tags          = []
            , completedDate = Nothing
            }
    liftIO $ loadTodo handle date >>= \case
      Just todo -> do -- update existing todo
        let newTodo = todo
              { entries = todo.entries <> [newEntry]
              , dirty   = True
              }
        modifyBuffer handle do
          pure . updateTodo date (const newTodo)
      Nothing -> do -- create new todo if necessary
        let newTodo = Todo
              { entries = [newEntry]
              , date    = date
              , dirty = True
              }
        modifyBuffer handle do
          pure . insertTodo date newTodo
    json (Ok ())


  -- update an entry
  put "/api/entry/:date/:id" do
    date         <- captureParam @Day "date"
    mEntryId     <- captureParamMaybe @EntryId "id"
    mCompletedAt <- formParamMaybe @Day "completedDate"
    mDescription <- formParamMaybe @Text "description"
    mDetail      <- formParamMaybe @Text "detail"
    mTags        <- formParamMaybe @Text "tags"
    let toNewEntry e = e
          { -- if completion date is in the past, force it to be completed in the same day
            completedDate = fmap (max date) mCompletedAt
          , description   = fromMaybe e.description mDescription
          , detail        = fromMaybe e.detail mDetail
          , tags          = fromMaybe e.tags (fmap Text.words mTags)
          }
    case mEntryId of
      Just entryId -> do
        hasChecked <- liftIO $ loadTodo handle date >>= \case
          Just _ -> do
            let f = updateEntry entryId toNewEntry
            modifyBuffer handle do
              pure . updateTodo date f
            pure True
          Nothing -> pure False
        if hasChecked
           then json (Ok ())
           else json (Err @Text "todo data doesn't exist")
      Nothing -> do
        hasChecked <- liftIO $ loadTodo handle date >>= \case
          Just _ -> do
            let f todo = todo { entries = fmap toNewEntry todo.entries
                              , dirty   = True
                              } :: Todo
            modifyBuffer handle do
              pure . updateTodo date f
            pure True
          Nothing -> pure False
        if hasChecked
           then json (Ok ())
           else json (Err @Text "todo data doesn't exist")


  -- delete an entry
  delete "/api/entry/:date/:id" do
    date    <- captureParam @Day "date"
    entryId <- captureParam @EntryId "id"
    hasDeleted <- liftIO $ loadTodo handle date >>= \case
      Just _ -> do
        modifyBuffer handle do
          pure . updateTodo date (deleteEntry entryId)
        pure True
      Nothing -> pure False
    if hasDeleted
       then json (Ok ())
       else json (Err @Text "can't find matching todo data")


  -- delete completed entries
  delete "/api/entries/:date" do
    date       <- captureParam @Day "date"
    completed  <- queryFlag "completed"
    hasDeleted <- liftIO $ loadTodo handle date >>= \case
      Just _
        | completed -> do
            let f todo = todo { entries = filter (not . (isJust . (.completedDate))) todo.entries
                              , dirty   = True
                              } :: Todo
            modifyBuffer handle (pure . updateTodo date f)
            pure True
        | otherwise -> pure False
      Nothing -> pure False
    if hasDeleted
       then json (Ok ())
       else json (Err @Text "nothing is deleted")


  notFound index


------------------------------
-- Scotty.Extended


queryFlag :: LText.Text -> ActionM Bool
queryFlag name = do
  mVal <- queryParamMaybe name :: ActionM (Maybe Text)
  pure $ case mVal of
    Just ""     -> True
    Just "true" -> True
    Just "1"    -> True
    _           -> False
