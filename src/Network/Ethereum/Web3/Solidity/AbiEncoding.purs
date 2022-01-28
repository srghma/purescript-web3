module Network.Ethereum.Web3.Solidity.AbiEncoding where

import Prelude

import Data.Array (length) as A
import Data.ByteString (ByteString)
import Data.ByteString (toUTF8, fromUTF8, toString, fromString, length, Encoding(Hex)) as BS
import Data.Either (Either)
import Data.Foldable (foldMap)
import Data.Functor.Tagged (Tagged, tagged, untagged)
import Data.Maybe (maybe, fromJust)
import Data.String.CodeUnits (fromCharArray)
import Data.Unfoldable (replicateA)
import Network.Ethereum.Core.BigNumber (toTwosComplement, unsafeToInt)
import Network.Ethereum.Core.HexString (HexString, Signed(..), getPadLength, mkHexString, padLeft, padLeftSigned, padRight, toBigNumberFromSignedHexString, toBigNumber, toSignedHexString, unHex)
import Network.Ethereum.Types (Address, BigNumber, embed, mkAddress, unAddress)
import Network.Ethereum.Web3.Solidity.Bytes (BytesN, unBytesN, update, proxyBytesN)
import Network.Ethereum.Web3.Solidity.Int (IntN, unIntN, intNFromBigNumber)
import Network.Ethereum.Web3.Solidity.Size (class ByteSize, class IntSize, class KnownSize, DLProxy(..), sizeVal)
import Network.Ethereum.Web3.Solidity.UInt (UIntN, unUIntN, uIntNFromBigNumber)
import Network.Ethereum.Web3.Solidity.Vector (Vector)
import Partial.Unsafe (unsafePartial)
import Text.Parsing.Parser (ParseError, Parser, ParserT, fail, runParser)
import Text.Parsing.Parser.String (anyChar)
import Unsafe.Coerce (unsafeCoerce)

-- | Class representing values that have an encoding and decoding instance to/from a solidity type.
class ABIEncode a where
  toDataBuilder :: a -> HexString

class ABIDecode a where
  fromDataParser :: Parser HexString a

instance abiEncodeAlgebra :: ABIEncode BigNumber where
  toDataBuilder = int256HexBuilder

instance abiDecodeAlgebra :: ABIDecode BigNumber where
  fromDataParser = int256HexParser

-- | Parse encoded value, droping the leading `0x`
fromData :: forall a. ABIDecode a => HexString -> Either ParseError a
fromData = flip runParser fromDataParser

instance abiEncodeBool :: ABIEncode Boolean where
  toDataBuilder = uInt256HexBuilder <<< fromBool

instance abiDecodeBool :: ABIDecode Boolean where
  fromDataParser = toBool <$> uInt256HexParser

instance abiEncodeInt :: ABIEncode Int where
  toDataBuilder = int256HexBuilder <<< embed

instance abiDecodeInt :: ABIDecode Int where
  fromDataParser = unsafeToInt <$> int256HexParser

instance abiEncodeAddress :: ABIEncode Address where
  toDataBuilder addr = padLeft <<< unAddress $ addr

instance abiDecodeAddress :: ABIDecode Address where
  fromDataParser = do
    _ <- take 24
    maddr <- mkAddress <$> take 40
    maybe (fail "Address is 20 bytes, receieved more") pure maddr

instance abiEncodeBytesD :: ABIEncode ByteString where
  toDataBuilder bytes = uInt256HexBuilder (embed $ BS.length bytes) <> bytesBuilder bytes

instance abiDecodeBytesD :: ABIDecode ByteString where
  fromDataParser = do
    len <- unsafeToInt <$> fromDataParser
    bytesDecode <<< unHex <$> take (len * 2)

instance abiEncodeString :: ABIEncode String where
  toDataBuilder = toDataBuilder <<< BS.toUTF8

instance abiDecodeString :: ABIDecode String where
  fromDataParser = BS.fromUTF8 <$> fromDataParser

instance abiEncodeBytesN :: ByteSize n => ABIEncode (BytesN n) where
  toDataBuilder bs = bytesBuilder <<< unBytesN $ bs

instance abiDecodeBytesN :: ByteSize n => ABIDecode (BytesN n) where
  fromDataParser = do
    let
      len = sizeVal (DLProxy :: DLProxy n)

      zeroBytes = getPadLength (len * 2)
    raw <- take $ len * 2
    _ <- take $ zeroBytes
    pure <<< update proxyBytesN <<< bytesDecode <<< unHex $ raw

instance abiEncodeVector :: (ABIEncode a, KnownSize n) => ABIEncode (Vector n a) where
  toDataBuilder as = foldMap toDataBuilder as

instance abiDecodeVector :: (ABIDecode a, KnownSize n) => ABIDecode (Vector n a) where
  fromDataParser =
    let
      len = sizeVal (DLProxy :: DLProxy n)
    in
      replicateA len fromDataParser

instance abiEncodeArray :: ABIEncode a => ABIEncode (Array a) where
  toDataBuilder as = uInt256HexBuilder (embed $ A.length as) <> foldMap toDataBuilder as

instance abiDecodeArray :: ABIDecode a => ABIDecode (Array a) where
  fromDataParser = do
    len <- unsafeToInt <$> uInt256HexParser
    replicateA len fromDataParser

instance abiEncodeUint :: IntSize n => ABIEncode (UIntN n) where
  toDataBuilder a = uInt256HexBuilder <<< unUIntN $ a

instance abiDecodeUint :: IntSize n => ABIDecode (UIntN n) where
  fromDataParser = do
    a <- uInt256HexParser
    maybe (fail $ msg a) pure <<< uIntNFromBigNumber (DLProxy :: DLProxy n) $ a
    where
    msg n =
      let
        size = sizeVal (DLProxy :: DLProxy n)
      in
        "Couldn't parse as uint" <> show size <> " : " <> show n

instance abiEncodeIntN :: IntSize n => ABIEncode (IntN n) where
  toDataBuilder a = int256HexBuilder <<< unIntN $ a

instance abiDecodeIntN :: IntSize n => ABIDecode (IntN n) where
  fromDataParser = do
    a <- int256HexParser
    maybe (fail $ msg a) pure <<< intNFromBigNumber (DLProxy :: DLProxy n) $ a
    where
    msg n =
      let
        size = sizeVal (DLProxy :: DLProxy n)
      in
        "Couldn't parse as int" <> show size <> " : " <> show n

instance abiEncodeTagged :: ABIEncode a => ABIEncode (Tagged s a) where
  toDataBuilder = toDataBuilder <<< untagged

instance abiDecodeTagged :: ABIDecode a => ABIDecode (Tagged s a) where
  fromDataParser = tagged <$> fromDataParser

--------------------------------------------------------------------------------
-- | Special Builders and Parsers
--------------------------------------------------------------------------------
-- | base16 encode, then utf8 encode, then pad
bytesBuilder :: ByteString -> HexString
bytesBuilder = padRight <<< unsafePartial fromJust <<< mkHexString <<< flip BS.toString BS.Hex

-- | unsafe utfDecode
bytesDecode :: String -> ByteString
bytesDecode s = unsafePartial $ fromJust $ flip BS.fromString BS.Hex s

-- | Encode something that is essentaially a signed integer.
int256HexBuilder :: BigNumber -> HexString
int256HexBuilder x =
  if x < zero then
    int256HexBuilder <<< toTwosComplement $ x
  else
    padLeftSigned <<< toSignedHexString $ x

-- | Encode something that is essentially an unsigned integer.
uInt256HexBuilder :: BigNumber -> HexString
uInt256HexBuilder x =
  let
    Signed _ x' = toSignedHexString x
  in
    padLeft x'

-- | Parse as a signed `BigNumber`
int256HexParser :: forall m. Monad m => ParserT HexString m BigNumber
int256HexParser = toBigNumberFromSignedHexString <$> take 64

-- | Parse an unsigned `BigNumber`
uInt256HexParser :: forall m. Monad m => ParserT HexString m BigNumber
uInt256HexParser = toBigNumber <$> take 64

-- | Decode a `Boolean` as a BigNumber
fromBool :: Boolean -> BigNumber
fromBool b = if b then one else zero

-- | Encode a `Boolean` as a `BigNumber`
toBool :: BigNumber -> Boolean
toBool bn = not $ bn == zero

-- | Read any number of HexDigits
take :: forall m. Monad m => Int -> ParserT HexString m HexString
take = \n -> unsafePartial fromJust <<< mkHexString <<< fromCharArray <$> replicateA n anyCharFromHexString
  where
    -- | it's safe to change "remaining input" type here
    -- | b.c. it's an input - it's already validated
    anyCharFromHexString :: ParserT HexString m Char
    anyCharFromHexString = (unsafeCoerce :: ParserT String m Char -> ParserT HexString m Char) anyChar
