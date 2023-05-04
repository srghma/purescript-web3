module Network.Ethereum.Web3.Contract
  ( class EventFilter
  , eventFilter
  , event
  , class CallMethod
  , call
  , class TxMethod
  , sendTx
  , deployContract
  , mkDataField
  ) where

import Prelude
import Data.Bifunctor (lmap)
import Data.Either (Either(..))
import Data.Functor.Tagged (Tagged, untagged)
import Data.Generic.Rep (class Generic, Constructor)
import Data.Lens ((.~), (%~), (?~))
import Data.Maybe (Maybe(..))
import Type.Proxy (Proxy(..))
import Data.Symbol (class IsSymbol, reflectSymbol)
import Effect.Exception (error)
import Network.Ethereum.Core.Keccak256 (toSelector)
import Network.Ethereum.Types (Address, HexString)
import Network.Ethereum.Web3.Api (eth_call, eth_sendTransaction)
import Network.Ethereum.Web3.Contract.Events (MultiFilterStreamState(..), event', FilterStreamState, ChangeReceipt, EventHandler)
import Network.Ethereum.Web3.Solidity (class DecodeEvent, class GenericABIDecode, class GenericABIEncode, class RecordFieldsIso, genericABIEncode, genericFromData, genericFromRecordFields)
import Network.Ethereum.Web3.Types (class TokenUnit, CallError(..), ChainCursor, ETHER, Filter, NoPay, TransactionOptions, Value, Web3, _data, _value, convert, throwWeb3)
import Network.Ethereum.Web3.Types.TokenUnit (MinorUnit)

class EventFilter :: forall eventK. eventK -> Constraint
class EventFilter event where
  -- | Event filter structure used by low-level subscription methods
  eventFilter :: Proxy event -> Address -> Filter event

-- | run `event'` one block at a time.
event ::
  forall indexedTypesTagged nonIndexedTypesTagged event.
  DecodeEvent indexedTypesTagged nonIndexedTypesTagged event =>
  Filter event ->
  EventHandler Web3 event ->
  Web3 (Either (FilterStreamState event) ChangeReceipt)
event filter handler = do
  eventFilterResult <-
    event'
    { singletonEventFilter: filter }
    { singletonEventFilter: handler }
    { windowSize: 0
    , trailBy: 0
    }
  pure $ lmap f eventFilterResult
  where
  -- f
  --   :: MultiFilterStreamState ( singletonEventFilter :: Filter event )
  --   -> FilterStreamState event
  f (MultiFilterStreamState { currentBlock, windowSize, trailBy, filters }) =
      { currentBlock
      , windowSize
      , trailBy
      , initialFilter: filters.singletonEventFilter
      }

--------------------------------------------------------------------------------
-- * Methods
--------------------------------------------------------------------------------
-- | Class paramaterized by values which are ABIEncodable, allowing the templating of
-- | of a transaction with this value as the payload.
class TxMethod (functionSignature :: Symbol) functionArguments where
  -- | Send a transaction for given contract `Address`, value and input data
  sendTx ::
    forall unit.
    TokenUnit (Value (unit ETHER)) =>
    IsSymbol functionSignature =>
    TransactionOptions unit ->
    Tagged (Proxy functionSignature) functionArguments ->
    Web3 HexString

-- ^ `Web3` wrapped tx hash
class CallMethod (functionSignature :: Symbol) functionArguments result where
  -- | Constant call given contract `Address` in mode and given input data
  call ::
    IsSymbol functionSignature =>
    TransactionOptions NoPay ->
    ChainCursor ->
    Tagged (Proxy functionSignature) functionArguments ->
    Web3 (Either CallError result)

-- ^ `Web3` wrapped result
instance (Generic functionArguments functionArgumentsRep, GenericABIEncode functionArgumentsRep) => TxMethod s functionArguments where
  sendTx = _sendTransaction

instance (Generic functionArguments arep, GenericABIEncode arep, Generic b brep, GenericABIDecode brep) => CallMethod s functionArguments b where
  call = _call

_sendTransaction ::
  forall functionArguments unit functionArgumentsRep functionSignature.
  IsSymbol functionSignature =>
  Generic functionArguments functionArgumentsRep =>
  GenericABIEncode functionArgumentsRep =>
  TokenUnit (Value (unit ETHER)) =>
  TransactionOptions unit ->
  Tagged (Proxy functionSignature) functionArguments ->
  Web3 HexString
_sendTransaction transactionOptions transationData = do
  let
    functionSelectorEncoded :: HexString
    functionSelectorEncoded = toSelector $ reflectSymbol $ (Proxy :: Proxy functionSignature)
  eth_sendTransaction $ setTransactionDataAndConvertValue $ functionSelectorEncoded <> (genericABIEncode $ untagged $ transationData)
  where
  setTransactionDataAndConvertValue transationData' =
    transactionOptions # _data .~ Just transationData'
      # _value
      %~ map convert

_call ::
  forall functionArguments arep b brep functionSignature.
  IsSymbol functionSignature =>
  Generic functionArguments arep =>
  GenericABIEncode arep =>
  Generic b brep =>
  GenericABIDecode brep =>
  TransactionOptions NoPay ->
  ChainCursor ->
  Tagged (Proxy functionSignature) functionArguments ->
  Web3 (Either CallError b)
_call transactionOptions cursor transationData = do
  let
    functionSignature :: String
    functionSignature = reflectSymbol (Proxy :: Proxy functionSignature)

    functionSelectorEncoded :: HexString
    functionSelectorEncoded = toSelector functionSignature

    fullDataEncoded = functionSelectorEncoded <> (genericABIEncode $ untagged $ transationData)
  res <- eth_call
    (setTransactionData fullDataEncoded)
    cursor
  case genericFromData res of
    Left err ->
      if res == mempty then
        pure $ Left
          $ NullStorageError
              { signature: functionSignature
              , _data: fullDataEncoded
              }
      else
        throwWeb3 $ error $ show err
    Right x -> pure $ Right x
  where
  setTransactionData :: HexString -> TransactionOptions NoPay
  setTransactionData transactionData = transactionOptions # _data .~ Just transactionData

deployContract ::
  forall functionArguments functionArgumentsRep t.
  Generic functionArguments functionArgumentsRep =>
  GenericABIEncode functionArgumentsRep =>
  TransactionOptions NoPay ->
  HexString ->
  Tagged t functionArguments ->
  Web3 HexString
deployContract transactionOptions deployByteCode args =
  let
    txdata :: TransactionOptions MinorUnit
    txdata =
      transactionOptions
        # _data ?~ deployByteCode <> genericABIEncode (untagged args)
        -- convert `NoPay ETHER` to `MinorUnit ETHER` (BigNumber "0" * BigNumber "1" = BigNumber "0")
        # _value %~ map convert
  in
    eth_sendTransaction txdata

mkDataField ::
  forall functionSignature tupleNWithTaggedArguments tupleNName genericTaggedRepresentation recordRow recordRowList.
  IsSymbol functionSignature =>
  Generic tupleNWithTaggedArguments (Constructor tupleNName genericTaggedRepresentation) =>
  GenericABIEncode (Constructor tupleNName genericTaggedRepresentation) =>
  RecordFieldsIso genericTaggedRepresentation recordRow recordRowList =>
  Proxy (Tagged (Proxy functionSignature) tupleNWithTaggedArguments) ->
  Record recordRow ->
  HexString
mkDataField _ record =
  let
    functionSignature :: String
    functionSignature = reflectSymbol (Proxy :: Proxy functionSignature)

    functionSelectorEncoded :: HexString
    functionSelectorEncoded = toSelector functionSignature

    tupleNWithTaggedArguments :: tupleNWithTaggedArguments
    tupleNWithTaggedArguments = genericFromRecordFields record
  in
    functionSelectorEncoded <> genericABIEncode tupleNWithTaggedArguments
