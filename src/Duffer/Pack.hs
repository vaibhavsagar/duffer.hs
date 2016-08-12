module Duffer.Pack (
    indexedEntryMap,
    makeOffsetMap,
    resolveAll,
    resolveDelta
) where

import qualified Data.ByteString as B
import qualified Data.Map.Strict as Map

import Data.Attoparsec.ByteString (parseOnly)
import Data.Tuple (swap)
import GHC.Int (Int64)
import System.IO.MMap (mmapFileByteString)
import System.FilePath ((-<.>))

import Duffer.Loose.Objects (Ref, GitObject)
import Duffer.Pack.Entries
import Duffer.Pack.Parser
import Duffer.Pack.File

packFile, packIndex :: FilePath -> FilePath
packFile  path = path -<.> "pack"
packIndex path = path -<.> "idx"

region :: Map.Map Int a -> Int -> Maybe (Int64, Int)
region offsetMap offset = let
    (Just nextOffset) = Map.lookupGT offset offsetMap
    len               = fst nextOffset - offset
    in Just (fromIntegral offset, len)

makeOffsetMap :: B.ByteString -> Map.Map Int B.ByteString
makeOffsetMap content = let
    parsedIndex = either error id (parseOnly parsePackIndex content)
    in Map.fromList $ map toAssoc parsedIndex

makeRefIndex :: B.ByteString -> Map.Map Ref Int
makeRefIndex content = let
    parsedIndex = either error id (parseOnly parsePackIndex content)
    in Map.fromList $ map (swap . toAssoc) parsedIndex

packFileRegion :: FilePath -> Maybe (Int64, Int) -> IO B.ByteString
packFileRegion = mmapFileByteString

getPackFileEntry :: FilePath -> Map.Map Int B.ByteString -> Int -> IO PackEntry
getPackFileEntry packFilePath rangeMap index = do
    content <- packFileRegion packFilePath (region rangeMap index)
    return $ either error id (parseOnly parsePackRegion content)

indexedEntryMap :: FilePath -> IO OffsetMap
indexedEntryMap indexPath = do
    indexContent <- B.readFile indexPath
    let offsetMap = makeOffsetMap indexContent
    let indices   = Map.keys offsetMap
    let filePath  = packFile indexPath
    contentEnd <- B.length <$> B.readFile filePath
    let rangeMap  = Map.insert (contentEnd - 20) "" offsetMap
    entries <- mapM (getPackFileEntry filePath rangeMap) indices
    return $ Map.fromAscList $ zip indices entries

combinedEntryMap :: FilePath -> IO CombinedMap
combinedEntryMap indexPath = do
    indexedMap <- indexedEntryMap indexPath
    refIndex   <- makeRefIndex <$> B.readFile indexPath
    return $ CombinedMap indexedMap refIndex

resolveAll :: FilePath -> IO [GitObject]
resolveAll indexPath = do
    combined <- combinedEntryMap indexPath
    let reconstitute = makeObject . resolveDelta combined
    return $ map reconstitute $ Map.elems (getRefIndex combined)
    where makeObject packEntry = case packEntry of
            (PackedObject t _ content) -> parseResolved t content
            (PackedDelta _)            -> error "delta not resolved"
