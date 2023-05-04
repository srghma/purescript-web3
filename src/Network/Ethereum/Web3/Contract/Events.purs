module Network.Ethereum.Web3.Contract.Events
  ( event'
  , pollEvent'
  , reduceEventStream
  , aquireFilter
  , pollFilter
  , logsStream
  , EventHandler
  , FilterStreamState
  , ChangeReceipt
  , FilterChange(..)
  , MultiFilterMinToBlock
  , MultiFilterMinFromBlock
  , ModifyFilter
  , QueryAllLogs
  , MultiFilterStreamState(..)
  , OpenMultiFilter
  , CloseMultiFilter
  , CheckMultiFilter
  ) where

import Prelude

import Control.Coroutine (Process, Consumer, producer, consumer, pullFrom, runProcess)
import Control.Coroutine.Transducer (Transducer, awaitForever, fromProducer, toProducer, yieldT, (=>=))
import Control.Monad.Fork.Class (bracket)
import Control.Monad.Reader.Trans (ReaderT, runReaderT)
import Control.Monad.Rec.Class (class MonadRec)
import Control.Monad.Trans.Class (lift)
import Control.Parallel (class Parallel)
import Data.Array (catMaybes, sort)
import Data.Either (Either(..))
import Data.Functor.Tagged (Tagged, tagged, untagged)
import Data.Lens ((^.))
import Data.Maybe (Maybe(..))
import Data.Newtype (over)
import Data.Symbol (class IsSymbol)
import Data.Traversable (for_)
import Data.Tuple (Tuple(..), fst)
import Data.Variant (Variant, class VariantMatchCases, expand, inj, match)
import Effect.Aff (delay, Milliseconds(..))
import Effect.Aff.Class (liftAff)
import Heterogeneous.Folding (class FoldingWithIndex, class FoldlRecord, hfoldlWithIndex)
import Heterogeneous.Mapping (class MapRecordWithIndex, class Mapping, ConstMapping, hmap)
import Network.Ethereum.Core.BigNumber (BigNumber, embed)
import Network.Ethereum.Core.HexString (HexString)
import Network.Ethereum.Web3.Api (eth_blockNumber, eth_getFilterChanges, eth_getLogs, eth_newFilter, eth_uninstallFilter)
import Network.Ethereum.Web3.Solidity (class DecodeEvent, decodeEvent)
import Network.Ethereum.Web3.Types (BlockNumber(..), Change(..), EventAction(..), FilterId, Web3, Filter(..), _fromBlock, _toBlock)
import Network.Ethereum.Web3.Types.Types (ChainCursor(..))
import Prim.RowList as RowList
import Record as Record
import Type.Proxy (Proxy(..))
import Type.Row as Row

--------------------------------------------------------------------------------
-- * Types
--------------------------------------------------------------------------------
type EventHandler m event
  = event -> ReaderT Change m EventAction

type FilterStreamState (event :: Type)
  = { currentBlock :: BlockNumber
    , initialFilter :: Filter event
    , windowSize :: Int
    , trailBy :: Int
    }

-- the Change AND event that is constructed from this Change
-- TODO(srghma): rename to FilterChangeAndEvent
newtype FilterChange event
  = FilterChange
  { rawChange :: Change
  , event :: event
  }

filterChangeToIndex :: forall a. FilterChange a -> Tuple BlockNumber BigNumber
filterChangeToIndex (FilterChange { rawChange: Change change }) = Tuple change.blockNumber change.logIndex

instance eqFilterChange :: Eq (FilterChange a) where
  eq f1 f2 = filterChangeToIndex f1 `eq` filterChangeToIndex f2

instance ordFilterChange :: Ord (FilterChange a) where
  compare f1 f2 = filterChangeToIndex f1 `compare` filterChangeToIndex f2

instance functorFilterChange :: Functor FilterChange where
  map f (FilterChange event) = FilterChange event { event = f event.event }

type ChangeReceipt
  = { logIndex :: BigNumber
    , blockHash :: HexString
    , blockNumber :: BlockNumber
    , action :: EventAction
    }

--------------------------------------------------------------------------------
-- | Takes a record of `Filter`s and a key-corresponding record of `EventHandler`s
-- | to match. It also has options for trailing the chain head by a certain
-- | number of blocks (where applicable), as well as a window size for requesting
-- | larger intervals of blocks (where applicable). When the underlying coroutine
-- | terminates, it will return either the state at the time of termination, or a
-- | `ChangeReceipt` for the event that caused the termination.
event' ::
  forall filtersRow handlersRow filtersRowList handlersRowList variantRowHandled variantRowInput.
  FoldlRecord MultiFilterMinFromBlock ChainCursor filtersRowList filtersRow ChainCursor =>
  FoldlRecord MultiFilterMinToBlock ChainCursor filtersRowList filtersRow ChainCursor =>
  RowList.RowToList handlersRow handlersRowList =>
  MapRecordWithIndex filtersRowList (ConstMapping ModifyFilter) filtersRow filtersRow =>
  RowList.RowToList filtersRow filtersRowList =>
  VariantMatchCases handlersRowList variantRowHandled (ReaderT Change Web3 EventAction) =>
  Row.Union variantRowHandled () variantRowInput =>
  FoldlRecord
    QueryAllLogs
    (Web3 (Array (FilterChange (Variant ()))))
    filtersRowList
    filtersRow
    (Web3 (Array (FilterChange (Variant variantRowInput)))) =>
  Record filtersRow ->
  Record handlersRow ->
  { windowSize :: Int, trailBy :: Int } ->
  -- here, the `MultiFilterStreamState filtersRow` (which is the last state) should not contain `windowSize` and `trailBy`
  -- TODO: don't store them in a `MultiFilterStreamState`
  Web3 (Either (MultiFilterStreamState filtersRow) ChangeReceipt)
event' filtersRecord handlersRecord { windowSize, trailBy } = do

  -- TODO: start listening for event from block number OR start from NOW
  -- GIVEN user pass two filters
  -- ```
  -- { f1: { fromBlock: ChainCursor_FromBlockNumber 10 }
  -- , f2: { fromBlock: ChainCursor_FromNow }
  -- }
  -- ```
  -- AND GIVEN that current block is e.g. 3
  -- THEN user calls a function that should emit Event at block N 4
  --
  -- EXPECTED:
  -- 1. the filters will start to listen from block N 3
  -- 2. our filters should catch event at block N 4
  -- ACTUAL:
  -- the filters will start to listen from block N 10

  currentBlock <- case hfoldlWithIndex MultiFilterMinFromBlock Latest filtersRecord of -- minimum block to start filtering from
    BN blockNumber -> pure blockNumber
    Latest -> eth_blockNumber -- NOTE: we are not using the "latest" tag
  let
    initialState =
      MultiFilterStreamState
        { currentBlock
        , filters: filtersRecord
        -- probably the `windowSize` and `trailBy` should not be in a `State`, b.c. it's not a `State`, it's configuration
        -- TODO: don't store them in a `MultiFilterStreamState`
        , windowSize
        , trailBy
        }
  runProcess $ reduceEventStream (logsStream initialState) handlersRecord

-- | Takes a record of filters and a key-corresponding record of handlers.
-- | Establishes filters for polling on the server a la the filterIds.
-- | Automatically handles cleaning up resources on the server.
pollEvent' ::
  forall filtersRow filtersRowList handlersRow handlersRowList filterIdsRow filterIdsList variantRowHandled variantRowInput.
  RowList.RowToList handlersRow handlersRowList =>
  RowList.RowToList filtersRow filtersRowList =>
  RowList.RowToList filterIdsRow filterIdsList =>
  MapRecordWithIndex filtersRowList (ConstMapping ModifyFilter) filtersRow filtersRow =>
  FoldlRecord MultiFilterMinFromBlock ChainCursor filtersRowList filtersRow ChainCursor =>
  FoldlRecord MultiFilterMinToBlock ChainCursor filtersRowList filtersRow ChainCursor =>
  VariantMatchCases handlersRowList variantRowHandled (ReaderT Change Web3 EventAction) =>
  FoldlRecord OpenMultiFilter (Web3 (Record ())) filtersRowList filtersRow (Web3 (Record filterIdsRow)) =>
  FoldlRecord CloseMultiFilter (Web3 Unit) filterIdsList filterIdsRow (Web3 Unit) =>
  FoldlRecord CheckMultiFilter
    (Web3 (Array (FilterChange (Variant ()))))
    filterIdsList
    filterIdsRow
    (Web3 (Array (FilterChange (Variant variantRowInput)))) =>
  Row.Union variantRowHandled () variantRowInput =>
  Record filtersRow ->
  Record handlersRow ->
  Web3 (Either BlockNumber ChangeReceipt)
pollEvent' filtersRecord handlersRecord =
  let
    processor filterIdsRecord stop =
      runProcess
        $ reduceEventStream (stagger $ pollFilter filterIdsRecord stop) handlersRecord
  in
    aquireFilter filtersRecord processor

--------------------------------------------------------------------------------
-- * Event Coroutines
--------------------------------------------------------------------------------
eventRunner ::
  forall handlersRow handlersRowList variantRowHandled variantRowInput m.
  RowList.RowToList handlersRow handlersRowList =>
  Monad m =>
  VariantMatchCases handlersRowList variantRowHandled (ReaderT Change m EventAction) =>
  Row.Union variantRowHandled () variantRowInput =>
  Record handlersRow ->
  Consumer (FilterChange (Variant variantRowInput)) m ChangeReceipt
eventRunner handlersR =
  consumer \change -> do
    receipt <- processChange handlersR change
    pure case receipt.action of
      ContinueEvent -> Nothing
      TerminateEvent -> Just receipt

-- | Taking an initial state, create a stream of filter records used for querying event logs.
-- | The coroutine terminates when it has read up to the `toBlock` field, yielding
-- | the current state.
filterProducer ::
  forall filtersRow filtersRowList.
  RowList.RowToList filtersRow filtersRowList =>
  FoldlRecord MultiFilterMinToBlock ChainCursor filtersRowList filtersRow ChainCursor =>
  MapRecordWithIndex filtersRowList (ConstMapping ModifyFilter) filtersRow filtersRow =>
  MultiFilterStreamState filtersRow ->
  Transducer Void (Record filtersRow) Web3 (MultiFilterStreamState filtersRow)
filterProducer multiFilterStreamState@(MultiFilterStreamState currentState) = do
  let -- hang out until the chain makes progress
    waitForMoreBlocks :: Transducer Void (Record filtersRow) Web3 (MultiFilterStreamState filtersRow)
    waitForMoreBlocks = do
      -- TODO: the `delayMilliseconds` should be configurable, store them in a `Configuration`, as the `windowSize` and `trailBy`
      lift $ liftAff $ delay (Milliseconds 3000.0)
      filterProducer multiFilterStreamState

    -- resume the filter production
    continueTo :: BlockNumber -> Transducer Void (Record filtersRow) Web3 (MultiFilterStreamState filtersRow)
    continueTo maxEndBlock = do
      let
        endBlock :: BlockNumber
        endBlock = addWindowToBlockAndClamp maxEndBlock currentState.currentBlock currentState.windowSize

        modify :: forall (k :: Type) (event :: k) . Filter event -> Filter event
        modify (Filter rpcFilter) =
          Filter
          { address: rpcFilter.address
          , topics: rpcFilter.topics
          , fromBlock: BN currentState.currentBlock
          , toBlock: BN endBlock
          }

        (fs' :: Record filtersRow) = hmap (ModifyFilter modify) currentState.filters

      yieldT fs'
      filterProducer $ MultiFilterStreamState currentState { currentBlock = succBlockNumber endBlock }
  chainHead <- lift eth_blockNumber
  -- if the chain head is less than the current block we want to process
  -- then wait until the chain progresses
  if chainHead < currentState.currentBlock then
    waitForMoreBlocks
  -- otherwise try make progress
  else case hfoldlWithIndex MultiFilterMinToBlock Latest currentState.filters of
    -- consume as many as possible up to the chain head
    Latest ->
      continueTo $ over BlockNumber (_ - embed currentState.trailBy) chainHead
    -- if the original fitler ends at a specific block, consume as many as possible up to that block
    -- or terminate if we're already past it
    BN targetEnd ->
      let
        targetEnd' = min targetEnd $ over BlockNumber (_ - embed currentState.trailBy) chainHead
      in
        if currentState.currentBlock <= targetEnd' then
          continueTo targetEnd'
        else
          pure multiFilterStreamState
  where
  addWindowToBlockAndClamp :: BlockNumber -> BlockNumber -> Int -> BlockNumber
  addWindowToBlockAndClamp maxEndBlock currentBlock windowSize = min maxEndBlock $ over BlockNumber (_ + embed windowSize) currentBlock

  succBlockNumber :: BlockNumber -> BlockNumber
  succBlockNumber = over BlockNumber (_ + one)

-- | Taking in a stream of filter records, produce a stream of `FilterChange`s from querying
-- | the getLogs method.
makeFilterChanges ::
  forall filtersRow filtersRowList row.
  RowList.RowToList filtersRow filtersRowList =>
  FoldlRecord
    QueryAllLogs
    (Web3 (Array (FilterChange (Variant ()))))
    filtersRowList
    filtersRow
    (Web3 (Array (FilterChange (Variant row)))) =>
  Transducer (Record filtersRow) (Array (FilterChange (Variant row))) Web3 Unit
makeFilterChanges =
  awaitForever \filtersRecord -> do
    let
      queryAllLogs :: Web3 (Array (FilterChange (Variant row)))
      queryAllLogs =
        hfoldlWithIndex
        QueryAllLogs
        (pure [] :: Web3 (Array (FilterChange (Variant ()))))
        filtersRecord

    (changes :: Array (FilterChange (Variant row))) <- lift queryAllLogs

    yieldT $ sort changes

-- | A stateless (on the server) stream of filter changes starting from an initial
-- | filter record.
logsStream ::
  forall filtersRow filtersRowList row.
  RowList.RowToList filtersRow filtersRowList =>
  FoldlRecord MultiFilterMinToBlock ChainCursor filtersRowList filtersRow ChainCursor =>
  MapRecordWithIndex filtersRowList (ConstMapping ModifyFilter) filtersRow filtersRow =>
  FoldlRecord
    QueryAllLogs -- function identifier
    (Web3 (Array (FilterChange (Variant ())))) -- accumulator on a start
    filtersRowList
    filtersRow
    (Web3 (Array (FilterChange (Variant row)))) -- output
  =>
  MultiFilterStreamState filtersRow ->
  Transducer Void (FilterChange (Variant row)) Web3 (MultiFilterStreamState filtersRow)
logsStream initialState =
  let
    producer :: Transducer Void (Record filtersRow) Web3 (MultiFilterStreamState filtersRow)
    producer = filterProducer initialState

    transformer :: Transducer (Record filtersRow) (FilterChange (Variant row)) Web3 Unit
    transformer = stagger makeFilterChanges
  in fst <$> (producer =>= transformer)

-- | Aquire a record of server-side filters using the bracket operator to release the
-- | filters on the node when done.
aquireFilter ::
  forall filtersRow filtersRowList filterIdsRow filterIdsList row result.
  RowList.RowToList filterIdsRow filterIdsList =>
  RowList.RowToList filtersRow filtersRowList =>
  MapRecordWithIndex filtersRowList (ConstMapping ModifyFilter) filtersRow filtersRow =>
  FoldlRecord MultiFilterMinFromBlock ChainCursor filtersRowList filtersRow ChainCursor =>
  FoldlRecord MultiFilterMinToBlock ChainCursor filtersRowList filtersRow ChainCursor =>
  FoldlRecord OpenMultiFilter (Web3 (Record ())) filtersRowList filtersRow (Web3 (Record filterIdsRow)) =>
  FoldlRecord CloseMultiFilter (Web3 Unit) filterIdsList filterIdsRow (Web3 Unit) =>
  FoldlRecord
    CheckMultiFilter
    (Web3 (Array (FilterChange (Variant ()))))
    filterIdsList
    filterIdsRow
    (Web3 (Array (FilterChange (Variant row)))) =>
  Record filtersRow ->
  (Record filterIdsRow -> ChainCursor -> Web3 result) ->
  Web3 result
aquireFilter filtersRecord handler =
  let
    pollingFromBlock :: ChainCursor
    pollingFromBlock = hfoldlWithIndex MultiFilterMinFromBlock Latest filtersRecord

    filtersRecord' :: Record filtersRow
    filtersRecord' = hmap (ModifyFilter \(Filter rpcFilter) -> Filter $ rpcFilter { fromBlock = pollingFromBlock }) filtersRecord


    aquire :: Web3 (Record filterIdsRow)
    aquire = openMultiFilter filtersRecord'

    onRelease :: forall bracketCondition . bracketCondition -> Record filterIdsRow -> Web3 Unit
    onRelease = const $ hfoldlWithIndex CloseMultiFilter (pure unit :: Web3 Unit)

    stopPollingAt :: ChainCursor
    stopPollingAt = hfoldlWithIndex MultiFilterMinToBlock Latest filtersRecord

    withFilter :: Record filterIdsRow -> Web3 result
    withFilter filterIdsRecord = handler filterIdsRecord stopPollingAt
  in
    bracket aquire onRelease withFilter

-- | `pollFilter` takes a `FilterId` and a max `ChainCursor` and polls a filter
-- | for changes until the chainHead's `BlockNumber` exceeds the `ChainCursor`,
-- | if ever. There is a minimum delay of 1 second between polls.
pollFilter ::
  forall filterIdsList row filterIdsRow.
  RowList.RowToList filterIdsRow filterIdsList =>
  FoldlRecord
    CheckMultiFilter
    (Web3 (Array (FilterChange (Variant ()))))
    filterIdsList
    filterIdsRow
    (Web3 (Array (FilterChange (Variant row)))) =>
  Record filterIdsRow ->
  ChainCursor ->
  Transducer Void (Array (FilterChange (Variant row))) Web3 BlockNumber
pollFilter filterIdsRecord stop = do
  fromProducer
    $ producer do
        bn <- eth_blockNumber
        if BN bn > stop then do
          pure <<< Right $ bn
        else do
          liftAff $ delay (Milliseconds 1000.0)
          (changes :: Array (FilterChange (Variant row))) <-
            hfoldlWithIndex
            CheckMultiFilter
            (pure [] :: Web3 (Array (FilterChange (Variant ()))))
            filterIdsRecord
          pure <<< Left $ sort changes

--------------------------------------------------------------------------------
-- * Utils
--------------------------------------------------------------------------------
-- | Takes a producer of filter changes and a record of handlers and runs the handlers
-- | as a consumer. If one of the handlers chooses to `TerminateEvent`, we return
-- | the change receipt that caused the termination. Otherwise if the producer
-- | terminates and yields an `a`, we return that.
reduceEventStream ::
  forall m par handlersRow handlersRowList variantRowInput variantRowHandled a.
  Monad m =>
  MonadRec m =>
  Parallel par m =>
  RowList.RowToList handlersRow handlersRowList =>
  VariantMatchCases handlersRowList variantRowHandled (ReaderT Change m EventAction) =>
  Row.Union variantRowHandled () variantRowInput =>
  Transducer Void (FilterChange (Variant variantRowInput)) m a ->
  Record handlersRow ->
  Process m (Either a ChangeReceipt)
reduceEventStream producerTransducer handlersRecord =
  (Right <$> eventRunner handlersRecord) `pullFrom` (Left <$> toProducer producerTransducer)

processChange ::
  forall m row rowList variantRowHandled variantRowInput.
  Monad m =>
  RowList.RowToList row rowList =>
  VariantMatchCases rowList variantRowHandled (ReaderT Change m EventAction) =>
  Row.Union variantRowHandled () variantRowInput =>
  Record row ->
  FilterChange (Variant variantRowInput) ->
  m ChangeReceipt
processChange handlersRecord (FilterChange { rawChange: rawChange@(Change change), event }) = do
  (action :: EventAction) <- runReaderT (match handlersRecord event) rawChange
  pure
    { logIndex: change.logIndex
    , blockHash: change.blockHash
    , blockNumber: change.blockNumber
    , action
    }

-- | Used to find the minimum `toBlock` among a record of filters.
data MultiFilterMinToBlock
  = MultiFilterMinToBlock

instance FoldingWithIndex MultiFilterMinToBlock (Proxy symbol) ChainCursor (Filter event) ChainCursor where
  foldingWithIndex MultiFilterMinToBlock _ accumulator filter = min accumulator (filter ^. _toBlock)

-- | Used to find the minimum `fromBlock` among a record of filters.
data MultiFilterMinFromBlock
  = MultiFilterMinFromBlock

instance FoldingWithIndex MultiFilterMinFromBlock (Proxy symbol) ChainCursor (Filter event) ChainCursor where
  foldingWithIndex MultiFilterMinFromBlock _ accumulator filter = min accumulator (filter ^. _fromBlock)

-- data ModifyFilter :: Type
data ModifyFilter
  = ModifyFilter (forall (k :: Type) (event :: k). Filter event -> Filter event)

instance Mapping ModifyFilter (Filter event) (Filter event) where
  mapping (ModifyFilter f) filter = f filter

-- TODO(srghma): throw error if cannot decode
-- | Parse an array of `Changes` into an array of `FilterChange`s
-- | that contain this event.
mkFilterChanges ::
  forall indexedTypesTagged nonIndexedTypesTagged event symbol trash row.
  DecodeEvent indexedTypesTagged nonIndexedTypesTagged event =>
  Row.Cons symbol event trash row =>
  IsSymbol symbol =>
  Proxy symbol ->
  Proxy event ->
  Array Change ->
  -- TODO(srghma): why not
  -- ```
  -- type FilterChangeAndEvent = { rawChange :: Change, event :: event }

  -- ... -> Array (Variant (foo :: Maybe FilterChangeAndEvent))
  -- ```
  Array (FilterChange (Variant row))
mkFilterChanges proxySymbol _ changes = catMaybes $ map mkFilterChange changes
  where
  mkFilterChange :: Change -> Maybe (FilterChange (Variant row))
  mkFilterChange rawChange = do
    event :: event <- decodeEvent rawChange
    pure
      $ FilterChange
          { rawChange: rawChange
          , event: inj proxySymbol event
          }

-- | Used to query eth_getLogs for all the filters in record of filters.
data QueryAllLogs
  = QueryAllLogs

instance
  ( DecodeEvent indexedTypesTagged nonIndexedTypesTagged event
  , IsSymbol symbol
  , Row.Union rowSmall trash row
  , Row.Cons symbol event rowSmall row
  ) =>
  FoldingWithIndex
    QueryAllLogs
    (Proxy symbol)
    (Web3 (Array (FilterChange (Variant rowSmall))))
    (Filter event)
    (Web3 (Array (FilterChange (Variant row))))
    where
  foldingWithIndex QueryAllLogs (prop :: Proxy symbol) accumulator filter = do
    (logs :: Array Change) <- eth_getLogs (filter :: Filter event)

    let
      changes :: Array (FilterChange (Variant row))
      changes = mkFilterChanges prop (Proxy :: Proxy event) logs

      accumulator' :: Web3 (Array (FilterChange (Variant row)))
      accumulator' = map (map expand) <$> accumulator

      appendChangesToTheEnd = (<>) changes

    appendChangesToTheEnd <$> accumulator'

newtype MultiFilterStreamState filtersRow
  = MultiFilterStreamState
    { currentBlock :: BlockNumber
    , filters :: Record filtersRow
    , windowSize :: Int -- window size for requesting larger intervals of blocks (where applicable)
    , trailBy :: Int -- trailing the chain head by a certain number of blocks (where applicable)
    }

-- example usage:
-- openMultiFilter { filter1: Filter ..., filter2: Filter ... }
-- => { filter1: Tagged Proxy filter1Id, filter2: Tagged Proxy filter2Id }
data OpenMultiFilter
  = OpenMultiFilter

instance
  ( Row.Lacks symbol rowSmall
  , IsSymbol symbol
  , Row.Union rowSmall trash row
  , Row.Cons symbol (Tagged event FilterId) rowSmall row
  ) =>
  FoldingWithIndex
  OpenMultiFilter
  (Proxy symbol)
  (Web3 (Record rowSmall))
  (Filter event)
  (Web3 (Record row)) where
  foldingWithIndex OpenMultiFilter (prop :: Proxy symbol) accumulator filter = do
    filterId <- eth_newFilter filter
    Record.insert prop (tagged filterId :: Tagged event FilterId) <$> accumulator

openMultiFilter ::
  forall filtersRow filterIdsRow filtersRowList.
  FoldlRecord OpenMultiFilter (Web3 (Record ())) filtersRowList filtersRow (Web3 (Record filterIdsRow)) =>
  RowList.RowToList filtersRow filtersRowList =>
  Record filtersRow ->
  Web3 (Record filterIdsRow)
openMultiFilter = hfoldlWithIndex OpenMultiFilter (pure {} :: Web3 (Record ()))

data CheckMultiFilter
  = CheckMultiFilter

instance
  ( DecodeEvent indexedTypesTagged nonIndexedTypesTagged event
  , IsSymbol symbol
  , Row.Union rowSmall trash row
  , Row.Cons symbol event rowSmall row
  ) =>
  FoldingWithIndex
  CheckMultiFilter
  (Proxy symbol)
  (Web3 (Array (FilterChange (Variant rowSmall))))
  (Tagged event FilterId)
  (Web3 (Array (FilterChange (Variant row)))) where
  foldingWithIndex CheckMultiFilter (prop :: Proxy symbol) accumulator taggedFilterId = do
    (filterChanges :: Array Change) <- eth_getFilterChanges (untagged taggedFilterId)

    let
      changes :: Array (FilterChange (Variant row))
      changes = mkFilterChanges prop (Proxy :: Proxy event) filterChanges

      accumulator' :: Web3 (Array (FilterChange (Variant row)))
      accumulator' = map (map expand) <$> accumulator

      appendChangesToTheEnd = (<>) changes

    appendChangesToTheEnd <$> accumulator'

data CloseMultiFilter
  = CloseMultiFilter

instance
  ( IsSymbol symbol
  ) =>
  FoldingWithIndex
  CloseMultiFilter
  (Proxy symbol)
  (Web3 Unit)
  (Tagged event FilterId)
  (Web3 Unit) where
  foldingWithIndex CloseMultiFilter (_ :: Proxy symbol) accumulator taggedFilterId = do
    void $ eth_uninstallFilter $ untagged taggedFilterId
    accumulator

-- Should belong to coroutines lib.
-- Instead of yielding `Array o` (in bulk), yields them one by one
-- TODO(srghma): rename to `asPartsOutput`
-- https://github.com/airalab/hs-web3/blob/a63bb5f23185aa605a200cc46266d418903593b9/packages/ethereum/src/Network/Ethereum/Contract/Event/SingleFilter.hs#L100
-- https://hackage.haskell.org/package/machines-0.7.2/docs/src/Data.Machine.Process.html#asParts
stagger ::
  forall i o m a par.
  Monad m =>
  MonadRec m =>
  Parallel par m =>
  Transducer i (Array o) m a ->
  Transducer i o m a
stagger transducerThatOutputsOs =
  let
    (trickle :: Transducer (Array o) o m Unit) = awaitForever \(outputs :: Array o) -> for_ outputs yieldT
  in
    fst <$> (transducerThatOutputsOs =>= trickle)
