{-# LANGUAGE LambdaCase #-}

module Duffer.Pack.Streaming (separatePackFile) where

import Data.ByteString                  (ByteString, append, concat, length)
import Codec.Compression.Zlib           (CompressionLevel)
import Control.Arrow                    (first)
import Control.Monad.Trans.State.Strict (StateT, evalStateT, runStateT, gets)
import Data.ByteString.Base16           (decode)
import Data.IntMap.Strict               (IntMap, empty, insert)
import Data.Maybe                       (fromJust)
import Pipes                            (Producer, next)
import Pipes.Attoparsec                 (parse, parseL)
import Pipes.ByteString                 (fromHandle, drawByte, peekByte)
import Pipes.Zlib                       (decompress', defaultWindowBits)
import Prelude hiding                   (length, concat)
import System.IO                        (openFile, IOMode(ReadMode))

import Duffer.Loose.Parser (parseBinRef)
import Duffer.Pack.Parser  (parseOffset, parsePackFileHeader, parseTypeLen
                           ,parsedPackRegion)
import Duffer.Pack.Entries (PackObjectType(..), DeltaObjectType(..)
                           ,PackEntry(..), compressToLevel, encodeOffset
                           ,getCompressionLevel, encodeTypeLen)

type Prod a   = Producer ByteString IO a
type EntryMap = IntMap PackEntry

separatePackFile :: FilePath -> IO EntryMap
separatePackFile path = do
    ((start, count), entries) <- runStateT parsePackFileStart =<<
        fromHandle <$> openFile path ReadMode
    fst <$> loop entries start count empty
    where parsePackFileStart =
            fromRight . fromJust <$> parseL parsePackFileHeader

loop :: Prod a -> Int -> Int -> EntryMap -> IO (EntryMap, Prod a)
loop producer _      0         indexedMap = return (indexedMap, producer)
loop producer offset remaining indexedMap = do
    (headerRef, decompressedP, level) <- evalStateT getNextEntry producer
    (output, producer')               <- uncurry advanceToCompletion =<<
        either ((,) "" . return) id <$> next decompressedP
    let content     = headerRef `append` compressToLevel level (concat output)
        indexedMap' = insert offset (parsedPackRegion content) indexedMap
        offset'     = offset + length content
        remaining'  = remaining - 1
    indexedMap' `seq` loop producer' offset' remaining' indexedMap'

getNextEntry :: StateT (Prod a) IO
    (ByteString, Prod (Either (Prod a) a), CompressionLevel)
getNextEntry = do
    tLen    <- parse' id parseTypeLen
    baseRef <- case fst tLen of
        DeltaType OfsDeltaType -> parse'  encodeOffset  parseOffset
        DeltaType RefDeltaType -> parse' (fst . decode) parseBinRef
        _              -> return ""
    decompressed <- gets (decompress' defaultWindowBits)
    _            <- drawByte -- The compression level is in the second byte.
    level        <- getCompressionLevel . fromJust <$> peekByte
    let headerRef = append (uncurry encodeTypeLen tLen) baseRef
    return (headerRef, decompressed, level)
    where parse' convert = fmap (convert . fromRight . fromJust) . parse

advanceToCompletion :: ByteString -> Prod (Either a b) -> IO ([ByteString], a)
advanceToCompletion decompressed producer = next producer >>= \case
    Right (d, p')  -> first ((:) decompressed) <$> advanceToCompletion d p'
    Left (Left p)  -> return ([decompressed], p)
    Left (Right _) -> error "No idea how to handle Left (Right _)"

fromRight :: Either a b -> b
fromRight = either (const $ error "Found Left, Right expected") id
