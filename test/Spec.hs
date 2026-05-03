{-# OPTIONS_GHC -Wno-orphans #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use <$>" #-}
module Main (main) where

import Codec.Compression.Zlib qualified as Zlib
import Control.Concurrent (newMVar)
import Control.Monad (forM)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isPrint, isSeparator)
import Data.List (nubBy)
import Data.Map qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (Day, fromGregorian)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.QuickCheck
import Todou.Domain.Todo
import Todou.Store


main :: IO ()
main = hspec do
  pureTest
  integrationTest


pureTest :: Spec
pureTest = do
  describe "Parsing & Serialization" do
    it "trims whitespace from text" do
      trim "  hello  " `shouldBe` "hello"

    it "parses a valid Todo date" do
      parseDate "2023-12-25" `shouldBe` Just (fromGregorian 2023 12 25)

    it "returns Nothing for invalid dates" do
      parseDate "not-a-date" `shouldBe` Nothing

    it "ensures dumpEntry -> parseEntry is identity-ish" do
      let entry = Entry (EntryId 5) "buy milk" "BUY MILK" [] (Just (fromGregorian 2023 12 15))
      let dumped = dumpEntry entry
      parseEntry dumped `shouldBe` Just entry


  describe "JSON Serialization" do
    it "round-trips an EntryId" $ property do
      \(NonNegative i) ->
        let eId = EntryId i
        in Aeson.decode (Aeson.encode eId) `shouldBe` Just eId

    it "round-trips an Entry" do
      let entry = Entry (EntryId 1) "Buy groceries" "Egg, Bacon, green onions" [] Nothing
      Aeson.decode (Aeson.encode entry) `shouldBe` Just entry

    it "sets 'dirty' to True when decoding a Todo" do
      let jsonInput = "{\"date\": \"2023-10-01\", \"entries\": []}"
      case Aeson.decode @Todo jsonInput of
        Just todo -> todo.dirty `shouldBe` True
        Nothing   -> expectationFailure "Failed to decode Todo JSON"

  describe "Buffer Consistency" do
    it "getBufferDayRange returns correct bounds for a non-empty buffer" do
      let d1 = fromGregorian 2024 1 1
      let d2 = fromGregorian 2024 1 10
      let buf = Buffer (Map.fromList [(d1, Nothing), (d2, Nothing)]) 0
      getBufferDayRange buf `shouldBe` Just (d1, d2)

    it "getBufferDayRange returns Nothing for an empty buffer" do
      let buf = Buffer Map.empty 0
      getBufferDayRange buf `shouldBe` Nothing

    it "insertTodo updates the map correctly" $ property do
      \day todo buffer -> do
        let updated = insertTodo day todo buffer
        Map.lookup day updated.todos == Just (Just todo { dirty = True })

  describe "Entry logic" do
    it "deleteEntry: entry should no longer exist in the list" $ property do
      \eid todo ->
        let updated = deleteEntry eid todo
        in all (\e -> e.entryId /= eid) updated.entries

    it "updateEntry: modifying an entry changes its value but keeps its ID" do
      let eid = EntryId 10
      let entry = Entry eid "Original" "original" [] Nothing
      let todo = Todo [entry] (fromGregorian 2024 1 1) False
      let newDesc = "Updated Description"

      let result = updateEntry eid (\e -> e { description = newDesc }) todo
      case filter (\e -> e.entryId == eid) result.entries of
        [updated] -> updated.description `shouldBe` newDesc
        _         -> expectationFailure "Entry not found or duplicated"

  describe "Presence Map Encoding" do
    it "produces a deterministic output" $ property do
      \bs -> b64EncodePresenceMap bs == b64EncodePresenceMap bs

    it "produces valid Base64 characters" $ property do
      \bs -> do
        let result = b64EncodePresenceMap bs
        let encodedBs = Text.encodeUtf8 result
        B64.decode encodedBs `shouldSatisfy` (\case Left _ -> False; Right _ -> True)

    it "can be manually reversed to retrieve original data" $ property do
      \bs -> do
        let encodedText = b64EncodePresenceMap bs
        -- Reverse the pipeline manually:
        -- Text -> B64 Decode -> Zlib Decompress -> Original
        let step1 = Text.encodeUtf8 encodedText
        case B64.decode step1 of
          Right step2 -> do
            let step3 = Zlib.decompress (LBS.fromStrict step2)
            LBS.toStrict step3 `shouldBe` bs
          Left err ->
            expectationFailure ("Base64 decoding failed " ++ err)

    it "handles empty input correctly" do
      -- Even empty input has a Zlib header
      let result = b64EncodePresenceMap ""
      Text.null result `shouldBe` False

  describe "Date & Presence Logic" do
    it "calculates correct buffer range from Map keys" $ property do
      \buffer ->
        if Map.null buffer.todos
          then getBufferDayRange buffer `shouldBe` Nothing
          else
            let keys = Map.keys buffer.todos
                expected = Just (minimum keys, maximum keys)
            in getBufferDayRange buffer `shouldBe` expected

    it "b64EncodePresenceMap round-trips correctly" $ property do
      \bs -> do
        let encoded = b64EncodePresenceMap bs
        -- Reversing the process: Text -> B64 -> Zlib -> ByteString
        let decodedB64 = B64.decode (Text.encodeUtf8 encoded)
        case decodedB64 of
          Left err -> expectationFailure $ "Base64 decode failed: " ++ err
          Right compressed -> do
            let decompressed = Zlib.decompress (ByteString.fromStrict compressed)
            ByteString.toStrict decompressed `shouldBe` bs


integrationTest :: Spec
integrationTest = do
  describe "FileSystem Integration" do
    it "persists and reloads a todo from a real directory" $ property \todo -> do
      withSystemTempDirectory "todou-test" \tmpDir -> do
        let day = todo.date
        let buf = Buffer (Map.singleton day (Just todo { dirty = True })) 1
        ref <- newMVar buf
        let handle = FileSystemHandle tmpDir ref

        flush handle

        modifyBuffer handle \b -> pure b { todos = Map.singleton day Nothing }

        mResult <- loadTodo handle day

        mResult `shouldBe` Just todo { dirty = False }

    it "loadTodo handles non-existent files by returning Nothing" do
      withSystemTempDirectory "todou-empty" \tmpDir -> do
        ref <- newMVar (Buffer Map.empty 0)
        let handle = FileSystemHandle tmpDir ref
        let day = fromGregorian 2026 2 14

        result <- loadTodo handle day
        result `shouldBe` Nothing

    it "flush resets dirty flags and dirtyCounts correctly" $ property \todo -> do
      withSystemTempDirectory "todou-flush" \tmpDir -> do
        let day = todo.date
        ref <- newMVar (Buffer (Map.singleton day (Just todo { dirty = True })) 1)
        let handle = FileSystemHandle tmpDir ref

        flush handle

        finalBuf <- getBuffer handle
        finalBuf.dirtyCounts `shouldBe` 0
        case Map.lookup day finalBuf.todos of
          Just (Just t) -> t.dirty `shouldBe` False
          _ -> expectationFailure "Todo missing from buffer after flush"


instance Arbitrary EntryId where
  arbitrary = EntryId . getNonNegative <$> arbitrary


instance Arbitrary Entry where
  arbitrary = do
    eid <- arbitrary
    -- Generate a string of printable Unicode characters
    -- but filter out separators/control chars that trim/strip would remove
    let genValidString = listOf $ arbitraryUnicodeChar `suchThat` \c ->
                           isPrint c && not (isSeparator c)

    descRaw    <- genValidString
    detailRaw  <- genValidString
    tagsRaw    <- listOf genValidString

    let desc   = Text.strip (Text.pack descRaw)
        detail = Text.strip (Text.pack detailRaw)
        tags   = filter (/= mempty) $ fmap (Text.strip . Text.pack) tagsRaw

    comp <- arbitrary
    pure $ Entry eid desc detail tags comp


instance Arbitrary Todo where
  arbitrary = do
    d    <- fromGregorian <$> choose (2020, 2100) <*> choose (1, 12) <*> choose (1, 28)
    ents <- arbitrary @[Entry]
    -- Ensure every EntryId in this Todo is unique
    let uniqueEnts = nubBy (\a b -> a.entryId == b.entryId) ents
    pure $ Todo uniqueEnts d True


instance Arbitrary Day where
  arbitrary = do
    y <- choose (2000, 2040)
    m <- choose (1, 12)
    d <- choose (1, 28) -- 28 is safe for all months
    pure $ fromGregorian y m d


instance Arbitrary Buffer where
  arbitrary = do
    days <- arbitrary @[Day]
    kvPairs <- forM days $ \d -> do
      maybeTodo <- arbitrary @(Maybe Todo)
      let syncedTodo = fmap (\t -> t { date = d } :: Todo) maybeTodo
      pure (d, syncedTodo)
    let todoMap = Map.fromList kvPairs
    let count = length [ t | Just t <- Map.elems todoMap, t.dirty ]
    pure $ Buffer todoMap count


instance Arbitrary ByteString where
  arbitrary = ByteString.pack <$> arbitrary
