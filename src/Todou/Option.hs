module Todou.Option where

import Data.Text (Text)
import Control.Applicative (asum)
import Control.Monad (unless, when)
import Data.Function ((&))
import Data.Functor ((<&>))
import Data.List (stripPrefix)
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import System.Directory (doesDirectoryExist)
import Text.Read (readMaybe)


------------------------------
-- Options


type Bucket = Text
type ConnectionString = String


data StorageOption
  = StorageFileSystem FilePath
  | StorageS3 Bucket
  | StorageNull
  deriving (Show, Eq)


data Options = Options
  { port    :: Int
  , storage :: StorageOption
  }
  deriving (Show)


defaultOptions :: Options
defaultOptions = Options { storage = StorageNull, port = 0 }


-- | Parse cli argument.
parseArgs :: [String] -> Options
parseArgs args
  = args
  & foldr
    (\s opts ->
        case stripPrefix "--storage=" s of
          Just arg -> do
            let storage = fromMaybe (error ("unknown storage argument " <> arg)) $
                  asum
                    [ stripPrefix "dir:"    arg <&> StorageFileSystem
                    , stripPrefix "s3:"     arg <&> StorageS3 . Text.pack
                    ]
            opts { storage = storage }
          Nothing  ->
            case stripPrefix "--port=" s of
              Just port -> opts { port = fromMaybe (error "port needs to be a number") (readMaybe port) }
              Nothing   -> opts
    )
    defaultOptions


-- | Argument sanity check.
checkArgs :: Options -> IO Options
checkArgs options = do
  case options.storage of
    StorageNull -> error "need a storage backend with --storage="
    StorageFileSystem dir -> do
      dirExists <- doesDirectoryExist dir
      unless dirExists do
        error ("invalid options, storage directory " <> dir <> " is invalid")
    StorageS3 _ -> pure ()
  when (options.port < 1024 || options.port > 65535) do
    error ("invalid port number " <> show options.port)
  pure options
