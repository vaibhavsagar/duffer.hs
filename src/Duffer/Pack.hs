{-# LANGUAGE LambdaCase #-}

module Duffer.Pack where

import qualified Data.ByteString      as B
import qualified Data.ByteString.UTF8 as BU
import qualified Data.Map.Strict      as Map
import qualified Data.IntMap.Strict   as IntMap
import qualified Data.Set             as Set

import Data.Bool        (bool)
import Data.IntMap.Strict (IntMap)
import Data.Maybe       (fromJust)
import Control.Monad    (filterM)
import GHC.Int          (Int64)
import System.IO.MMap   (mmapFileByteString)
import System.FilePath  ((</>), (-<.>), combine, takeExtension)
import System.Directory (getDirectoryContents, doesFileExist)

import Duffer.Loose.Objects (GitObject, Ref)
import Duffer.Pack.Entries  (CombinedMap(..), OffsetMap, PackEntry
                            ,getRefIndex)
import Duffer.Pack.Parser   (parsedPackIndexRefs, parsedPackRegion
                            ,parsedPackRefs)
import Duffer.Pack.File     (resolveDelta, resolveEntry, unpackObject
                            ,makeRefIndex, makeOffsetMap)
import Duffer.WithRepo      (WithRepo, ask, asks, liftIO, localObjects)

packFile, packIndex :: FilePath -> FilePath
packFile  = (-<.> "pack")
packIndex = (-<.> "idx")

region :: IntMap a -> Int -> Maybe (Int64, Int)
region offsetMap offset = let
    nextOffset = fromJust $ IntMap.lookupGT offset offsetMap
    in Just (fromIntegral offset, fst nextOffset - offset)

getPackIndices :: FilePath -> IO [FilePath]
getPackIndices path = let packFilePath = path </> "pack" in
    map (combine packFilePath) . filter ((==) ".idx" . takeExtension) <$>
    getDirectoryContents packFilePath

getPackObjectRefs :: WithRepo (Set.Set Ref)
getPackObjectRefs = do
    paths   <- asks getPackIndices
    indices <- liftIO (mapM B.readFile =<< paths)
    return $ Set.fromList $ concatMap parsedPackIndexRefs indices

hasPacked :: Ref -> FilePath -> IO Bool
hasPacked ref = fmap (elem ref . parsedPackIndexRefs) . B.readFile

hasPackObject :: Ref -> WithRepo Bool
hasPackObject = localObjects . hasPackObject'

hasPackObject' :: Ref -> WithRepo Bool
hasPackObject' ref = do
    paths <- asks getPackIndices
    or <$> liftIO (mapM (hasPacked ref) =<< paths)

readPackObject :: Ref -> WithRepo (Maybe GitObject)
readPackObject = localObjects . readPackObject'

readPackObject' :: Ref -> WithRepo (Maybe GitObject)
readPackObject' ref = liftIO . readPacked ref =<< ask

readPacked :: Ref -> FilePath -> IO (Maybe GitObject)
readPacked ref path =
    (filterM (hasPacked ref) =<< getPackIndices path) >>= \case
        []      -> return Nothing
        index:_ -> flip resolveEntry ref <$> combinedEntryMap index

getPackRegion :: FilePath -> IntMap B.ByteString -> Int -> IO B.ByteString
getPackRegion packFilePath rangeMap =
    mmapFileByteString packFilePath . region rangeMap

packFileRegion :: FilePath -> Maybe (Int64, Int) -> IO B.ByteString
packFileRegion = mmapFileByteString

indexedEntryMap :: FilePath -> IO OffsetMap
indexedEntryMap = fmap (fmap parsedPackRegion) . indexedByteStringMap

indexedByteStringMap :: FilePath -> IO (IntMap B.ByteString)
indexedByteStringMap indexPath = do
    offsetMap    <- makeOffsetMap <$> B.readFile indexPath
    let filePath =  packFile indexPath
    contentEnd   <- B.length <$> B.readFile filePath
    let indices  =  IntMap.keys offsetMap
    let rangeMap =  IntMap.insert (contentEnd - 20) "" offsetMap
    entries      <- mapM (getPackRegion filePath rangeMap) indices
    return $ IntMap.fromAscList $ zip indices entries

combinedEntryMap :: FilePath -> IO CombinedMap
combinedEntryMap indexPath = CombinedMap
    <$> indexedEntryMap               indexPath
    <*> fmap makeRefIndex (B.readFile indexPath)

resolveAll :: CombinedMap -> [GitObject]
resolveAll cMap =
    map (fromJust . resolveEntry cMap) $ Map.keys (getRefIndex cMap)

readPackRef :: FilePath -> WithRepo (Maybe Ref)
readPackRef refPath = do
    refsPath <- asks (</> "packed-refs")
    liftIO (doesFileExist refsPath) >>= bool
        (return Nothing)
        (Map.lookup (BU.fromString refPath) . parsedPackRefs <$>
            liftIO (B.readFile refsPath))
