{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}

module Todou.Domain.Todo where

import Codec.Compression.Zlib qualified as Zlib
import Control.DeepSeq (NFData)
import Data.Aeson (ToJSON (..), FromJSON (..), KeyValue ((.=)), (.:))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as B64
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (Day, formatTime, defaultTimeLocale)
import GHC.Generics (Generic)


------------------------------
-- Domain.Todo


-- A Todou is a list of Todos. A Todo is a list of entries.
-- Each Todo represents the todo list of one day.


-- | EntryId unique on each todou file per day. To universally
-- identify an entry you need date and the entryId.
newtype EntryId = EntryId Int deriving (Generic, Show, Eq, Ord, NFData)


instance ToJSON EntryId where
  toJSON (EntryId entryId) = toJSON entryId


instance FromJSON EntryId where
  parseJSON = fmap EntryId . parseJSON @Int


data Entry = Entry
  { entryId       :: {-# UNPACK #-} !EntryId
  , description   :: Text
  , detail        :: Text
  , tags          :: [Text]
  , completedDate :: Maybe Day
  }
  deriving (Generic, Eq, Show, NFData)


instance ToJSON Entry where
  toJSON e =
    Aeson.object
      [ "id"            .= e.entryId
      , "description"   .= e.description
      , "detail"        .= e.detail
      , "tags"          .= e.tags
      , "completedDate" .= e.completedDate
      ]


instance FromJSON Entry where
  parseJSON = Aeson.withObject "Entry" \o -> do
    Entry
      <$> (o .: "id")
      <*> (o .: "description")
      <*> (o .: "detail")
      <*> (o .: "tags")
      <*> (o .: "completedDate")


-- | Todo entries for a single day
data Todo = Todo
  { entries :: [Entry]
  , date    :: Day
  , dirty   :: Bool -- indicate if the Todo is modified.
  }
  deriving (Generic, Show, Eq, NFData)


instance ToJSON Todo where
  toJSON (Todo { entries, date }) =
    Aeson.object
      [ "date"    .= formatTime defaultTimeLocale  "%Y-%m-%d" date
      , "entries" .= entries
      ]


instance FromJSON Todo where
  parseJSON = Aeson.withObject "Todo" \o -> do
    Todo
      <$> o .: "entries"
      <*> o .: "date"
      <*> pure True -- if the client sends us a Todo it must be dirty


-- | In memory buffer of the persisted todo data.
data Buffer = Buffer
  { todos       :: Map Day (Maybe Todo)
  , dirtyCounts :: Int
  }
  deriving Show


pattern TodoNotExists :: Maybe (Maybe Todo)
pattern TodoNotExists = Nothing


pattern TodoNotLoaded :: Maybe (Maybe Todo)
pattern TodoNotLoaded = Just Nothing


pattern TodoLoaded :: Todo -> Maybe (Maybe Todo)
pattern TodoLoaded a = Just (Just a)
{-# COMPLETE TodoNotExists, TodoNotLoaded, TodoLoaded #-}


deleteEntry :: EntryId -> Todo -> Todo
deleteEntry entryId todo = todo { entries = filter (\e -> e.entryId /= entryId) todo.entries, dirty = True } :: Todo


updateEntry :: EntryId -> (Entry -> Entry) -> Todo -> Todo
updateEntry entryId f todo =
  todo { entries = fmap (\entry -> if entry.entryId == entryId then f entry else entry) todo.entries
       , dirty   = True
       }


updateTodo :: Day -> (Todo -> Todo) -> Buffer -> Buffer
updateTodo date f buffer =
 buffer
    { dirtyCounts = buffer.dirtyCounts + 1
    , todos = Map.update (\todo -> Just (mkDirty . f <$> todo)) date buffer.todos
    }
  where
    mkDirty todo = todo { dirty = True}


insertTodo :: Day -> Todo -> Buffer -> Buffer
insertTodo date todo buffer@Buffer{ todos, dirtyCounts } =
  buffer
    { dirtyCounts = dirtyCounts + 1
    , todos = Map.insert date (Just todo { dirty = True }) todos
    }


getBufferDayRange :: Buffer -> Maybe (Day, Day)
getBufferDayRange Buffer { todos } =
  case Map.keys todos of
    [] -> Nothing
    ks -> pure (head ks, last ks)


-- | Frontend initial model
data Model = Model
  { entries       :: [Entry]
  , nextId        :: EntryId
  , date          :: Day
  , presenceMap   :: ByteString
  , firstDay      :: Maybe Day
  }


instance ToJSON Model where
  toJSON model = Aeson.object
    [ "entries"     .= model.entries
    , "nextId"      .= model.nextId
    , "date"        .= model.date
    , "presenceMap" .= b64EncodePresenceMap model.presenceMap
    , "firstDay"    .= model.firstDay
    , "tag"         .= Text.pack "todo"
    ]


b64EncodePresenceMap :: ByteString -> Text
b64EncodePresenceMap bs = s3
  where
    s1 = Zlib.compress (ByteString.fromStrict bs)
    s2 = B64.encode (ByteString.toStrict s1)
    s3 = Text.decodeUtf8 s2


todoToModel :: Todo -> Model
todoToModel todo =
  Model
    { entries      = todo.entries
    , nextId       = EntryId (lastId + 1)
    , date         = todo.date
    , presenceMap  = ""
    , firstDay     = Nothing
    }
  where
    EntryId lastId
      | null todo.entries = EntryId 0
      | otherwise         = maximum (fmap (.entryId) todo.entries)
