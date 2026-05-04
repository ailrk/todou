module Todou.Main where

import System.Environment (getArgs)
import Todou.Domain.Todo (getBufferDayRange)
import Todou.Option (Options(..), checkArgs, parseArgs)
import Todou.Server (server)
import Todou.Store (createHandle, spawnFlusher, getBuffer, loadAllTodos)


main :: IO ()
main = do
  options <- getArgs >>= checkArgs . parseArgs
  handle  <- createHandle options.storage
  _       <- spawnFlusher handle
  buffer  <- getBuffer handle
  case getBufferDayRange buffer of
    Nothing -> pure ()
    Just (from, to) -> loadAllTodos handle from to
  server options handle
