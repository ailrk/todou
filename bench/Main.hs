{-# LANGUAGE PatternSynonyms #-}
module Main where

import Control.Concurrent (readMVar)
import Control.Exception (evaluate)
import Criterion
import Criterion.Main (defaultMain)
import Data.List (iterate')
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Calendar.Month (pattern MonthDay)
import Todou.Domain.Stat (CFR(..), createCFSegmentFromMonth, toCFD)
import Todou.Domain.Todo
import Todou.Option (StorageOption(..))
import Todou.Store
import UnliftIO.Temporary (withTempDirectory)
import Data.Map qualified as Map
import Control.DeepSeq (force)


testDate :: Day
testDate = fromGregorian 2024 1 15


-- | Make a fresh handle pointing at a temp dir
mkHandle :: FilePath -> IO Handle
mkHandle dir = createHandle (StorageFileSystem dir)


-- | Insert n entries into a single date
seedEntries :: Handle -> Day -> Int -> IO ()
seedEntries handle date n =
  mapM_ (insertOne handle date) [1..n]
  where
    insertOne h d i = do
      let entry = Entry
            { entryId       = EntryId i
            , description   = "entry " <> Text.pack (show i)
            , detail        = ""
            , tags          = []
            , completedDate = Nothing
            }
      modifyBuffer h \buf ->
        case Map.lookup d buf.todos of
          TodoLoaded todo ->
            pure buf { todos = Map.insert d (Just todo { entries = todo.entries <> [entry], dirty = True }) buf.todos }
          _ ->
            pure buf { todos = Map.insert d (Just Todo { entries = [entry], date = d, dirty = True }) buf.todos }


-- | Seed entries across 30 days
seedMonth :: Handle -> Int -> IO ()
seedMonth handle totalEntries = mapM_ seedDay [1..30]
  where
    perDay = totalEntries `div` 30
    seedDay dayN =
      let date = fromGregorian 2024 1 dayN
      in seedEntries handle date perDay


------------------------------
-- Parse / serialise


sampleTodoText :: Int -> Text
sampleTodoText n = Text.unlines $
  [ "[date]", "date = 2024-01-15" ] <>
  concatMap mkEntry [1..n]
  where
    mkEntry i =
      [ "[entry]"
      , "id = " <> Text.pack (show i)
      , "description = entry " <> Text.pack (show i)
      , "detail = "
      , "tags = "
      ]


benchParseTodo :: Int -> IO ()
benchParseTodo n = do
  let txt = sampleTodoText n
  _ <- evaluate (force (parseTodo txt))
  pure ()


benchDumpTodo :: Todo -> IO ()
benchDumpTodo todo = evaluate (force (dumpTodo todo)) >> pure ()


------------------------------
-- Store operations


benchLoadTodo :: Handle -> IO ()
benchLoadTodo handle = do
  _ <- loadTodo handle testDate
  pure ()


benchModifyBuffer :: Handle -> IO ()
benchModifyBuffer handle =
  modifyBuffer handle \buf -> pure buf


benchGetPresences :: Handle -> IO ()
benchGetPresences handle = do
  buf <- readMVar (getBufferMVar handle)
  _ <- getPresences buf
  pure ()


------------------------------
-- Flush


benchFlush :: Handle -> IO ()
benchFlush handle = flush handle


------------------------------
-- Stat


benchStat :: Handle -> Day -> IO ()
benchStat handle date = do
  buf <- readMVar (getBufferMVar handle)
  let MonthDay month _ = date
      months = iterate' pred month
      start1 = months !! 0
      end    = month
      seg    = foldr1 (<>) [ createCFSegmentFromMonth m buf.todos | m <- [start1..end] ]
  _ <- evaluate (force (toCFD (CFRMonthRange start1 end) seg))
  pure ()


------------------------------
-- Main


main :: IO ()
main = withTempDirectory "/tmp" "todou-bench" \tmpDir -> do
  handle <- mkHandle tmpDir

  putStrLn "Seeding data..."
  seedMonth handle 1000
  putStrLn "Done"

  defaultMain
    [ bgroup "parse"
        [ env (pure (sampleTodoText 10))             \txt         -> bench "parseTodo  10 entries" $ nf parseTodo txt
        , env (pure (sampleTodoText 50))             \txt         -> bench "parseTodo  50 entries" $ nf parseTodo txt
        , env (pure (sampleTodoText 200))            \txt         -> bench "parseTodo 200 entries" $ nf parseTodo txt
        , env (pure (parseTodo (sampleTodoText 50))) \(~(Just t)) -> bench "dumpTodo   50 entries" $ nf dumpTodo t
        ]

    , bgroup "store"
        [ bench "loadTodo (cached)"      $ nfIO (benchLoadTodo handle)
        , bench "modifyBuffer (noop)"    $ nfIO (benchModifyBuffer handle)
        , bench "getPresences (30 days)" $ nfIO (benchGetPresences handle)
        , bench "flush (all clean)"      $ nfIO (benchFlush handle)
        ]

    , bgroup "stat"
        [ bench "toCFD 1 month"  $ nfIO (benchStat handle testDate)
        ]
    ]
