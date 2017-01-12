{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}

-- | Workers responsible for Leaders and Richmen computation.

module Pos.Lrc.Worker
       ( lrcOnNewSlotWorker
       , lrcSingleShot
       ) where

import qualified Data.HashMap.Strict      as HM
import qualified Data.List.NonEmpty       as NE
import           Formatting               (build, sformat, (%))
import           Mockable                 (fork)
import           Node                     (SendActions)
import           Serokell.Util.Exceptions ()
import           System.Wlog              (logInfo)
import           Universum

import           Pos.Binary.Communication ()
import           Pos.Block.Logic          (applyBlocks, rollbackBlocks, withBlkSemaphore_)
import           Pos.Communication.BiP    (BiP)
import           Pos.Constants            (k)
import qualified Pos.DB                   as DB
import qualified Pos.DB.GState            as GS
import           Pos.DB.Lrc               (getLeaders, putEpoch, putLeaders)
import           Pos.Lrc.Consumer         (LrcConsumer (..))
import           Pos.Lrc.Consumers        (allLrcConsumers)
import           Pos.Lrc.Eligibility      (findAllRichmenMaybe)
import           Pos.Lrc.Error            (LrcError (..))
import           Pos.Lrc.FollowTheSatoshi (followTheSatoshiM)
import           Pos.Slotting             (onNewSlot')
import           Pos.Ssc.Class            (SscWorkersClass)
import           Pos.Ssc.Extra            (sscCalculateSeed)
import           Pos.Types                (EpochIndex, EpochOrSlot (..), EpochOrSlot (..),
                                           HeaderHash, HeaderHash, SlotId (..),
                                           crucialSlot, getEpochOrSlot, getEpochOrSlot)
import           Pos.WorkMode             (WorkMode)
import           Control.Concurrent.STM.TVar (TVar, readTVar, writeTVar)
import           Control.Monad.Catch         (bracketOnError)

import           Pos.Context                 (LrcSyncData, getNodeContext, ncLrcSync)

lrcOnNewSlotWorker
    :: (SscWorkersClass ssc, WorkMode ssc m)
    => SendActions BiP m -> m ()
lrcOnNewSlotWorker _ = onNewSlot' True $ lrcOnNewSlotImpl

lrcOnNewSlotImpl
    :: (SscWorkersClass ssc, WorkMode ssc m)
    => SlotId -> m ()
lrcOnNewSlotImpl SlotId {..} = when (siSlot < k) $ lrcSingleShot siEpoch

-- | Run leaders and richmen computation for given epoch. If stable
-- block for this epoch is not known, LrcError will be thrown.
lrcSingleShot
    :: (SscWorkersClass ssc, WorkMode ssc m)
    => EpochIndex -> m ()
lrcSingleShot epoch = lrcSingleShotImpl epoch allLrcConsumers

lrcSingleShotImpl
    :: WorkMode ssc m
    => EpochIndex -> [LrcConsumer m] -> m ()
lrcSingleShotImpl epoch consumers = do
    lock <- ncLrcSync <$> getNodeContext
    tryAcuireExclusiveLock epoch lock onAcquiredLock
  where
    onAcquiredLock = do
        expectedRichmenComp <- filterM (flip lcIfNeedCompute epoch) consumers
        needComputeLeaders <- isNothing <$> getLeaders epoch
        let needComputeRichmen = not . null $ expectedRichmenComp
        when needComputeLeaders $ logInfo "Need to compute leaders"
        when needComputeRichmen $ logInfo "Need to compute richmen"
        when (needComputeLeaders || needComputeRichmen) $ do
            logInfo "LRC is starting"
            withBlkSemaphore_ $ lrcDo epoch expectedRichmenComp
            logInfo "LRC has finished"
        putEpoch epoch
        logInfo "LRC has updated LRC DB"

tryAcuireExclusiveLock
    :: (MonadMask m, MonadIO m)
    => EpochIndex -> TVar LrcSyncData -> m () -> m ()
tryAcuireExclusiveLock epoch lock action =
    bracketOnError acquireLock (flip whenJust releaseLock) doAction
  where
    acquireLock = atomically $ do
        res <- readTVar lock
        case res of
            (False, _) -> retry
            (True, lockEpoch)
                | lockEpoch >= epoch -> pure Nothing
                | lockEpoch == epoch - 1 ->
                    Just lockEpoch <$ writeTVar lock (False, lockEpoch)
                | otherwise -> throwM UnknownBlocksForLrc
    releaseLock = atomically . writeTVar lock . (True,)
    doAction Nothing = pass
    doAction _       = action >> releaseLock epoch

lrcDo
    :: WorkMode ssc m
    => EpochIndex -> [LrcConsumer m] -> HeaderHash ssc -> m (HeaderHash ssc)
lrcDo epoch consumers tip = tip <$ do
    blockUndoList <- DB.loadBlocksFromTipWhile whileMoreOrEq5k
    when (null blockUndoList) $ throwM UnknownBlocksForLrc
    let blockUndos = NE.fromList blockUndoList
    rollbackBlocks blockUndos
    richmenComputationDo epoch consumers
    leadersComputationDo epoch
    applyBlocks (NE.reverse blockUndos)
  where
    whileMoreOrEq5k b _ = getEpochOrSlot b > crucial
    crucial = EpochOrSlot $ Right $ crucialSlot epoch

leadersComputationDo :: WorkMode ssc m => EpochIndex -> m ()
leadersComputationDo epochId =
    unlessM (isJust <$> getLeaders epochId) $ do
        mbSeed <- sscCalculateSeed epochId
        totalStake <- GS.getTotalFtsStake
        leaders <-
            case mbSeed of
                Left e ->
                    panic $ sformat ("SSC couldn't compute seed: " %build) e
                Right seed ->
                    GS.iterateByTx (followTheSatoshiM seed totalStake) snd
        putLeaders epochId leaders

richmenComputationDo :: forall ssc m . WorkMode ssc m
    => EpochIndex -> [LrcConsumer m] -> m ()
richmenComputationDo epochIdx consumers = unless (null consumers) $ do
    -- [CSL-93] Use eligibility threshold here
    total <- GS.getTotalFtsStake
    let minThreshold = safeThreshold total (not . lcConsiderDelegated)
    let minThresholdD = safeThreshold total lcConsiderDelegated
    (richmen, richmenD) <- GS.iterateByStake
                               (findAllRichmenMaybe @ssc minThreshold minThresholdD)
                               identity
    let callCallback cons = void $ fork $
            if lcConsiderDelegated cons
            then lcComputedCallback cons epochIdx total
                   (HM.filter (>= lcThreshold cons total) richmenD)
            else lcComputedCallback cons epochIdx total
                   (HM.filter (>= lcThreshold cons total) richmen)
    mapM_ callCallback consumers
  where
    safeThreshold total f =
        safeMinimum
        $ map (flip lcThreshold total)
        $ filter f consumers
    safeMinimum a = if null a then Nothing else Just $ minimum a
