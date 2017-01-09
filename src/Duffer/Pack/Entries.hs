{-# LANGUAGE RecordWildCards #-}

module Duffer.Pack.Entries where

import qualified Data.ByteString        as B
import qualified Data.IntMap.Strict     as IM

import Codec.Compression.Zlib (CompressionLevel, compressLevel, bestSpeed
                              ,compressWith, defaultCompressParams
                              ,defaultCompression)
import Data.Byteable          (Byteable(..))
import Data.ByteString.Base16 (decode)
import Data.ByteString.Lazy   (fromStrict, toStrict)
import Data.Bits              (Bits(..))
import Data.Bool              (bool)
import Data.Digest.CRC32      (crc32)
import Data.List              (foldl')
import Data.Map.Strict        (Map, insert, empty, foldrWithKey)
import Data.Word              (Word8, Word32)

import Duffer.Loose.Objects (Ref)

data PackIndexEntry = PackIndexEntry
    { pieOffset :: Int
    , pieRef    :: Ref
    , pieCRC    :: Word32
    }
    deriving (Show, Eq)

data FullObjectType = CommitType | TreeType | BlobType | TagType
    deriving (Eq, Show)

data DeltaObjectType = OfsDeltaType | RefDeltaType
    deriving (Eq, Show)

data PackObjectType = FullType FullObjectType | DeltaType DeltaObjectType
    deriving (Eq, Show)

data PackDelta = OfsDelta Int (WCL Delta) | RefDelta Ref (WCL Delta)
    deriving (Show, Eq)

data PackedObject = PackedObject FullObjectType Ref (WCL B.ByteString)
    deriving (Show, Eq)

data PackEntry = Resolved PackedObject | UnResolved PackDelta
    deriving (Show, Eq)

{- Packfile entries generated by `git` use one of two different compression
 - levels: default compression or best speed. To perfectly reconstruct a
 - packfile, we need to store the compression level of each section of
 - compressed content. For generating our own packfiles, this is not as
 - important.
 -}
data WCL a = WCL
    { wclLevel   :: CompressionLevel
    , wclContent :: a
    } deriving (Show, Eq)

data DeltaInstruction
    = CopyInstruction   Int Int
    | InsertInstruction B.ByteString
    deriving (Show, Eq)

data Delta = Delta Int Int [DeltaInstruction] deriving (Show, Eq)

data CombinedMap = CombinedMap
    { getOffsetMap :: OffsetMap
    , getRefIndex  :: RefIndex
    } deriving (Show)

data ObjectMap = ObjectMap
    { getObjectMap   :: Map Int PackedObject
    , getObjectIndex :: RefIndex
    }

type OffsetMap = IM.IntMap PackEntry
type RefMap    = Map Ref PackEntry
type RefIndex  = Map Ref Int

instance Enum PackObjectType where
    fromEnum (FullType  CommitType)   = 1
    fromEnum (FullType  TreeType)     = 2
    fromEnum (FullType  BlobType)     = 3
    fromEnum (FullType  TagType)      = 4
    fromEnum (DeltaType OfsDeltaType) = 6
    fromEnum (DeltaType RefDeltaType) = 7

    toEnum 1 = FullType  CommitType
    toEnum 2 = FullType  TreeType
    toEnum 3 = FullType  BlobType
    toEnum 4 = FullType  TagType
    toEnum 6 = DeltaType OfsDeltaType
    toEnum 7 = DeltaType RefDeltaType
    toEnum _ = error "invalid"

instance Byteable PackEntry where
    toBytes (Resolved  packedObject) = toBytes packedObject
    toBytes (UnResolved ofsD@(OfsDelta _ WCL{..})) = let
        header = encodeTypeLen (DeltaType OfsDeltaType)
            $ B.length (toBytes wclContent)
        in header `B.append` toBytes ofsD
    toBytes (UnResolved refD@(RefDelta _ WCL{..})) = let
        header = encodeTypeLen (DeltaType RefDeltaType)
            $ B.length (toBytes wclContent)
        in header `B.append` toBytes refD

instance Byteable PackedObject where
    toBytes (PackedObject t _ packed) = let
        header = encodeTypeLen (FullType t) $ B.length $ wclContent packed
        in header `B.append` toBytes packed

instance (Byteable a) => Byteable (WCL a) where
    toBytes WCL{..} = compressToLevel wclLevel $ toBytes wclContent

isResolved :: PackEntry -> Bool
isResolved (Resolved   _) = True
isResolved (UnResolved _) = False

compressToLevel :: CompressionLevel -> B.ByteString -> B.ByteString
compressToLevel level content = toStrict $
    compressWith defaultCompressParams {compressLevel = level}
        $ fromStrict content

getCompressionLevel :: Word8 -> CompressionLevel
getCompressionLevel levelByte = case levelByte of
        1   -> bestSpeed
        156 -> defaultCompression
        _   -> error "I can't make sense of this compression level"

instance Functor WCL where
    fmap f (WCL l a) = WCL l (f a)

encodeTypeLen :: PackObjectType -> Int -> B.ByteString
encodeTypeLen packObjType len = let
    (last4, rest) = packEntryLenList len
    firstByte     = fromEnum packObjType `shiftL` 4 .|. last4
    firstByte'    = bool firstByte (setMSB firstByte) (rest /= B.empty)
    in B.cons (fromIntegral firstByte') rest

packEntryLenList :: Int -> (Int, B.ByteString)
packEntryLenList n = let
    rest   = fromIntegral n `shiftR` 4 :: Int
    last4  = fromIntegral n .&. 15
    last4' = bool last4 (setMSB last4) (rest > 0)
    restL  = to7BitList rest
    restL' = bool B.empty (toLittleEndian restL) (restL /= [0])
    in (last4', restL')

instance Byteable PackDelta where
    toBytes packDelta = uncurry B.append $ case packDelta of
        RefDelta ref delta -> (fst $ decode ref, toBytes delta)
        OfsDelta off delta -> (encodeOffset off, toBytes delta)

{- Given a = r = 2^7:
 - x           = a((1 - r^n)/(1-r))
 - x - xr      = a - ar^n
 - x + ar^n    = a + xr
 - x + r^(n+1) = r + xr
 - r^(n+1)     = r + xr -x
 - r^(n+1)     = x(r-1) + r
 - n+1         = log128 x(r-1) + r
 - n           = floor ((log128 x(2^7-1) + 2^7) - 1)
 -}
encodeOffset :: Int -> B.ByteString
encodeOffset n = let
    noTermsLog  = logBase 128 (fromIntegral n * (128 - 1) + 128) :: Double
    noTerms     = floor noTermsLog - 1
    powers128   = map (128^) ([1..] :: [Integer])
    remove      = sum $ take noTerms powers128 :: Integer
    remainder   = n - fromIntegral remove :: Int
    varInt      = to7BitList remainder
    encodedInts = toLittleEndian . reverse $ leftPadZeros varInt (noTerms + 1)
    in encodedInts

leftPadZeros :: [Int] -> Int -> [Int]
leftPadZeros ints n
    | length ints < n = leftPadZeros (0:ints) n
    | otherwise       = ints

setMSB :: (Bits t, Integral t) => t -> t
setMSB = (`setBit` 7)

setMSBs :: (Bits t, Integral t) => [t] -> [Word8]
setMSBs []     = []
setMSBs (i:is) = map fromIntegral $ i : map setMSB is

instance Byteable Delta where
    toBytes (Delta source dest instructions) = B.concat
        [ toLittleEndian $ to7BitList source
        , toLittleEndian $ to7BitList dest
        , B.concat (map toBytes instructions)
        ]

toLittleEndian :: (Bits t, Integral t) => [t] -> B.ByteString
toLittleEndian = B.pack . reverse . setMSBs

instance Byteable DeltaInstruction where
    toBytes (InsertInstruction content) =
        B.singleton (fromIntegral $ B.length content) `B.append` content
    toBytes (CopyInstruction offset 0x10000) =
        toBytes $ CopyInstruction offset 0
    toBytes (CopyInstruction offset size) = let
        offsetBytes = toByteList offset
        lenBytes    = toByteList size
        offsetBits  = map (>0) offsetBytes
        lenBits     = map (>0) lenBytes
        bools       = True:padFalse lenBits 3 ++ padFalse offsetBits 4
        firstByte   = fromIntegral $ boolsToByte bools
        encodedOff  = encode offsetBytes
        encodedLen  = encode lenBytes
        in B.concat [B.singleton firstByte, encodedOff, encodedLen]
        where encode = B.pack . map fromIntegral . reverse . filter (>0)
              padFalse :: [Bool] -> Int -> [Bool]
              padFalse bits len = let
                pad = len - length bits
                in bool bits (replicate pad False ++ bits) (pad > 0)
              boolsToByte :: [Bool] -> Int
              boolsToByte = foldl' (\acc b -> shiftL acc 1 + fromEnum b) 0

packObjectType :: (Bits t, Integral t) => t -> PackObjectType
packObjectType header = toEnum . fromIntegral $ (header `shiftR` 4) .&. 7

toAssoc :: PackIndexEntry -> (Int, Ref)
toAssoc (PackIndexEntry o r _) = (o, r)

emptyCombinedMap :: CombinedMap
emptyCombinedMap = CombinedMap IM.empty empty

emptyObjectMap :: ObjectMap
emptyObjectMap = ObjectMap empty empty

insertObject :: Int -> PackedObject -> ObjectMap -> ObjectMap
insertObject offset object@(PackedObject _ r _) ObjectMap {..} = ObjectMap
    (insert offset object getObjectMap)
    (insert r      offset getObjectIndex)

fromBytes :: (Bits t, Integral t) => B.ByteString -> t
fromBytes = B.foldl' (\a b -> (a `shiftL` 8) + fromIntegral b) 0

toSomeBitList :: (Bits t, Integral t) => Int -> t -> [t]
toSomeBitList some n = reverse $ toSomeBitList' some n
    where toSomeBitList' some' n' = case divMod n' (bit some') of
            (0, i) -> [fromIntegral i]
            (x, y) ->  fromIntegral y : toSomeBitList' some' x

toByteList, to7BitList :: (Bits t, Integral t) => t -> [t]
toByteList = toSomeBitList 8
to7BitList = toSomeBitList 7

fifthOffsets :: B.ByteString -> [Int]
fifthOffsets ""   = []
fifthOffsets bstr = fromBytes (B.take 8 bstr):fifthOffsets (B.drop 8 bstr)

fixOffsets :: [Int] -> Int -> Int
fixOffsets fOffsets offset
    | offset < msb = offset
    | otherwise    = fOffsets !! (offset-msb)
    where msb = bit 31

packIndexEntries :: CombinedMap -> [PackIndexEntry]
packIndexEntries CombinedMap {..} = let
    crc32s = (crc32 . toBytes) <$> getOffsetMap
    op r o = (:) (PackIndexEntry o r (crc32s IM.! o))
    in foldrWithKey op [] getRefIndex
