{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Todou.Domain.Summary where

import Amazonka.Data (ToJSON (..), (.=))
import Control.DeepSeq (NFData)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Containers.ListUtils (nubOrd)
import Data.List (sort)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (catMaybes)
import Data.Text qualified as Text
import Data.Time (Year, Day, pattern YearMonthDay, gregorianMonthLength)
import Data.Time.Calendar.Month (Month, pattern YearMonth, pattern MonthDay)
import Todou.Domain.Todo (Todo (..), Entry (..), b64EncodePresenceMap)
import GHC.Generics (Generic)

------------------------------
-- Domain.Summary


-- | Cumulative Flow Resolution. This type indicates the scale of the
-- CF diagram.
data CFR
  = CFRYear Year
  | CFRMonth Month
  | CFRMonthRange Month Month
  deriving (Generic, Show, Eq, NFData)


-- | One step on the Cumulative Flow Diagram
data CF = CF
  { date       :: Day
  , completed  :: Int
  , ongoing    :: Int
  }
  deriving (Generic, Show, Eq, NFData)


instance ToJSON CF where
  toJSON (CF date completed ongoing) =
    Aeson.object
      [ "date"      .= date
      , "completed" .= completed
      , "ongoing"   .= ongoing
      ]


data CFSegment = CFSegment
  { content        :: [CF]
  , completedAfter :: Map Day Int
  }
  deriving (Generic, Show, Eq, NFData)


instance Semigroup CFSegment where
  (<>) = mergeCFSegment


-- | Merge to consecutive CFSegments.
mergeCFSegment :: CFSegment -> CFSegment -> CFSegment
mergeCFSegment (CFSegment [] _) rss = rss
mergeCFSegment (CFSegment ls lca) rss =
  let cs1 = bumpCFSegment (last ls) rss
      rs1 = let loop seg ca = case seg of -- compensate completedAfter.
                               x@CF { date }:xs -> case Map.lookup date ca of
                                                     Just n  -> let bump c = c { completed = c.completed + n }
                                                                 in bump x : fmap bump (loop xs (Map.delete date ca))
                                                     Nothing -> x:loop xs ca
                               [] -> seg
             in loop cs1.content lca
    in CFSegment { content        = ls <> rs1
                 , completedAfter = rss.completedAfter
                 }
  where
   -- Bump the CFSegment as if it continues from i.
   bumpCFSegment i (CFSegment cfs ca) =
      let bump cf = cf { completed = cf.completed + i.completed, ongoing = cf.ongoing + i.ongoing }
       in CFSegment { content        = fmap bump cfs
                    , completedAfter = ca
                    }


-- | Convert a CFR into a day range.
cfrToDayRange ::  CFR -> (Day, Day)
cfrToDayRange r =
  case r of
    CFRYear year ->
      (YearMonthDay year 1 1, YearMonthDay year 12 31)
    CFRMonth month ->
      let YearMonth year monthOfYear = month
       in ( MonthDay month 1, MonthDay month (gregorianMonthLength year monthOfYear))
    CFRMonthRange from to ->
      if from <= to
         then let (from1, _) = cfrToDayRange (CFRMonth from)
                  (_, to2) = cfrToDayRange (CFRMonth to)
               in (from1, to2)
          else  cfrToDayRange (CFRMonth from)


-- | Create a list of CF, only record the day if something happened.
-- This function uses `rangeQuery` which is O(log(n) + log(n')).
createCFSegment :: CFR -> Map Day (Maybe Todo) -> CFSegment
createCFSegment r todos =
  let
      (start, end)  = cfrToDayRange r

      todosInRange  = catMaybes $ rangeQuery (Just start) (Just end) todos

      completedCnt  = let es = concat $ fmap (.entries) todosInRange
                       in foldl'
                            (\acc (Entry { completedDate }) ->
                              case completedDate of
                                Just d  -> Map.insertWith (+) d 1 acc
                                Nothing -> acc)
                            Map.empty es

      completedDays  = Map.keys completedCnt

      -- all days that something happened
      days           = nubOrd $ sort $ completedDays ++ fmap (\t -> t.date) todosInRange

      go (cfs, cc) d = if d > end
                         then (cfs, cc)
                         else case Map.lookup d todos of
                                Just (Just (Todo {entries})) ->
                                  let total  = length entries
                                      comp   = Map.findWithDefault 0 d cc
                                      uncomp = total - comp
                                      cf'    = case cfs of
                                                 []   -> CF { date      = d
                                                            , ongoing   = uncomp
                                                            , completed = comp
                                                            }
                                                 cf:_ -> cf { date      = d
                                                            , ongoing   = cf.ongoing + uncomp
                                                            , completed = cf.completed + comp
                                                            }
                                      cc'     = Map.delete d cc
                                   in (cf':cfs, cc')
                                Just Nothing -> (cfs, cc)
                                Nothing      -> (cfs, cc)

      (xs, completedAfter) =  foldl' go ([], completedCnt) days
   in CFSegment (reverse xs) completedAfter


-- | Prepare [CF] so there is no gap between days for a month. The result `CFDMonth` is ready
-- for the frontend to render.
createCFSegmentFromMonth :: Month -> Map Day (Maybe Todo) -> CFSegment
createCFSegmentFromMonth month todos =
  let CFSegment cfd residue = createCFSegment (CFRMonth month) todos -- cfd is already sorted
      (start, end)     = cfrToDayRange (CFRMonth month)

      go (x:xs) (y@(CF { date }):ys) a
        | x < date = let a' = a { date = x } :: CF
                      in a' : go xs (y:ys) a'

        | x == date = y : go xs ys y

        | otherwise = go (x:xs) ys a -- ignore

      go (x:xs) [] a = let a' = a { date = x } :: CF
                        in a' : go xs [] a'
      go [] _ _ = []

    in CFSegment { content        = go [start..end] cfd (CF { date = start, completed = 0, ongoing = 0})
                 , completedAfter = residue
                 }


------------------------------
-- DTO


toCFD :: CFR -> CFSegment -> CFD
toCFD cfr CFSegment { content, completedAfter } =
  let (start, end) = cfrToDayRange cfr
   in CFD { content        = content
          , completedAfter = sum (Map.elems completedAfter)
          , from           = start
          , to             = end
          }


data CFD = CFD
  { content        :: [CF]
  , completedAfter :: Int
  , from           :: Day
  , to             :: Day
  }
  deriving (Generic, Show, Eq, NFData)


instance ToJSON CFD where
  toJSON (CFD content completedAfter from to) =
    Aeson.object
      [ "content"        .= content
      , "completedAfter" .= completedAfter
      , "from"           .= from
      , "to"             .= to
      ]


data Model = Model
  { date        :: Day
  , cfd1Month   :: CFD
  , cfd2Month   :: CFD
  , cfd3Month   :: CFD
  , presenceMap :: ByteString
  , firstDay    :: Maybe Day
  }


instance ToJSON Model where
  toJSON model = Aeson.object
    [ "date"        .= model.date
    , "cfd1Month"   .= model.cfd1Month
    , "cfd2Month"   .= model.cfd2Month
    , "cfd3Month"   .= model.cfd3Month
    , "presenceMap" .= b64EncodePresenceMap model.presenceMap
    , "firstDay"    .= model.firstDay
    , "tag"         .= Text.pack "summary"
    ]


------------------------------
-- Helper


rangeQuery :: (Ord k, Enum k) => Maybe k -> Maybe k -> Map k a -> [a]
rangeQuery Nothing Nothing  _ = []

rangeQuery (Just s1) (Just s2)  m = let (_, afterS1) = Map.split (pred s1) m
                                        (inRange, _) = Map.split (succ s2) afterS1
                                     in Map.elems inRange
rangeQuery (Just s1) Nothing  m = let (_, afterS1) = Map.split (pred s1) m
                                   in Map.elems afterS1
rangeQuery  Nothing (Just s2)  m = let (beforeS2, _) = Map.split (succ s2) m
                                    in Map.elems beforeS2
