{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE ScopedTypeVariables #-}

#if __GLASGOW_HASKELL__ >= 701
{-# LANGUAGE Trustworthy        #-}
#endif

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Concurrent.STM.TBQueue
-- Copyright   :  (c) The University of Glasgow 2012
-- License     :  BSD-style (see the file libraries/base/LICENSE)
--
-- Maintainer  :  libraries@haskell.org
-- Stability   :  experimental
-- Portability :  non-portable (requires STM)
--
-- 'TBQueue' is a bounded version of 'TQueue'. The queue has a maximum
-- capacity set when it is created.  If the queue already contains the
-- maximum number of elements, then 'writeTBQueue' blocks until an
-- element is removed from the queue.
--
-- The implementation is based on an array to obtain /O(1)/
-- enqueue and dequeue operations.
--
-- @since 2.4
-----------------------------------------------------------------------------

module Control.Concurrent.STM.TBQueue (
    -- * TBQueue
    TBQueue,
    newTBQueue,
    newTBQueueIO,
    readTBQueue,
    tryReadTBQueue,
    flushTBQueue,
    peekTBQueue,
    tryPeekTBQueue,
    writeTBQueue,
    unGetTBQueue,
    lengthTBQueue,
    isEmptyTBQueue,
    isFullTBQueue,
  ) where

import Data.Array.Base
import Data.Maybe (isJust, isNothing)
import Data.Typeable   (Typeable)
import GHC.Conc
import Numeric.Natural (Natural)
import Prelude         hiding (read)

import Control.Concurrent.STM.TArray

-- | 'TBQueue' is an abstract type representing a bounded FIFO channel.
--
-- @since 2.4
data TBQueue a
   = TBQueue {-# UNPACK #-} !(TVar Int)             -- read index
             {-# UNPACK #-} !(TVar Int)             -- write index
             {-# UNPACK #-} !(TArray Int (Maybe a)) -- elements
             {-# UNPACK #-} !Int                    -- initial capacity
  deriving Typeable

instance Eq (TBQueue a) where
  -- each `TBQueue` has its own `TVar`s, so it's sufficient to compare the first one
  TBQueue a _ _ _ == TBQueue b _ _ _ = a == b

-- incMod x cap == (x + 1) `mod` cap
incMod :: Int -> Int -> Int
incMod x cap = let y = x + 1 in if y == cap then 0 else y

-- decMod x cap = (x - 1) `mod` cap
decMod :: Int -> Int -> Int
decMod x cap = if x == 0 then cap - 1 else x - 1

-- | Builds and returns a new instance of 'TBQueue'.
newTBQueue :: Natural   -- ^ maximum number of elements the queue can hold
           -> STM (TBQueue a)
newTBQueue size
  | size <= 0 = error "capacity has to be greater than 0"
  | size > fromIntegral (maxBound :: Int) = error "capacity is too big"
  | otherwise = do
      rindex <- newTVar 0
      windex <- newTVar 0
      elements <- newArray (0, size' - 1) Nothing
      pure (TBQueue rindex windex elements size')
 where
  size' = fromIntegral size

-- | @IO@ version of 'newTBQueue'.  This is useful for creating top-level
-- 'TBQueue's using 'System.IO.Unsafe.unsafePerformIO', because using
-- 'atomically' inside 'System.IO.Unsafe.unsafePerformIO' isn't
-- possible.
newTBQueueIO :: Natural -> IO (TBQueue a)
newTBQueueIO size
  | size <= 0 = error "capacity has to be greater than 0"
  | size > fromIntegral (maxBound :: Int) = error "capacity is too big"
  | otherwise = do
      rindex <- newTVarIO 0
      windex <- newTVarIO 0
      elements <- newArray (0, size' - 1) Nothing
      pure (TBQueue rindex windex elements size')
 where
  size' = fromIntegral size

-- | Write a value to a 'TBQueue'; blocks if the queue is full.
writeTBQueue :: TBQueue a -> a -> STM ()
writeTBQueue (TBQueue _ windex elements size) a = do
  w <- readTVar windex
  ele <- unsafeRead elements w
  case ele of
    Nothing -> unsafeWrite elements w (Just a)
    Just _ -> retry
  writeTVar windex $! incMod w size

-- | Read the next value from the 'TBQueue'.
readTBQueue :: TBQueue a -> STM a
readTBQueue (TBQueue rindex _ elements size) = do
  r <- readTVar rindex
  ele <- unsafeRead elements r
  a <- case ele of
        Nothing -> retry
        Just a -> do
          unsafeWrite elements r Nothing
          pure a
  writeTVar rindex $! incMod r size
  pure a

-- | A version of 'readTBQueue' which does not retry. Instead it
-- returns @Nothing@ if no value is available.
tryReadTBQueue :: TBQueue a -> STM (Maybe a)
tryReadTBQueue q = fmap Just (readTBQueue q) `orElse` pure Nothing

-- | Efficiently read the entire contents of a 'TBQueue' into a list. This
-- function never retries.
--
-- @since 2.4.5
flushTBQueue :: forall a. TBQueue a -> STM [a]
flushTBQueue (TBQueue _rindex windex elements size) = do
  w <- readTVar windex
  go (decMod w size) []
 where
  go :: Int -> [a] -> STM [a]
  go i acc = do
      ele <- unsafeRead elements i
      case ele of
        Nothing -> pure acc
        Just a -> do
          unsafeWrite elements i Nothing
          go (decMod i size) (a : acc)

-- | Get the next value from the @TBQueue@ without removing it,
-- retrying if the channel is empty.
peekTBQueue :: TBQueue a -> STM a
peekTBQueue (TBQueue rindex _ elements _) = do
  r <- readTVar rindex
  ele <- unsafeRead elements r
  case ele of
    Nothing -> retry
    Just a -> pure a

-- | A version of 'peekTBQueue' which does not retry. Instead it
-- returns @Nothing@ if no value is available.
tryPeekTBQueue :: TBQueue a -> STM (Maybe a)
tryPeekTBQueue q = fmap Just (peekTBQueue q) `orElse` pure Nothing

-- | Put a data item back onto a channel, where it will be the next item read.
-- Blocks if the queue is full.
unGetTBQueue :: TBQueue a -> a -> STM ()
unGetTBQueue (TBQueue rindex _ elements size) a = do
  r <- readTVar rindex
  ele <- unsafeRead elements r
  case ele of
    Nothing -> unsafeWrite elements r (Just a)
    Just _ -> retry
  writeTVar rindex $! decMod r size

-- | Return the length of a 'TBQueue'.
--
-- @since 2.5.0.0
lengthTBQueue :: TBQueue a -> STM Natural
lengthTBQueue (TBQueue rindex windex elements size) = do
  r <- readTVar rindex
  w <- readTVar windex
  if w == r then do
    -- length is 0 or size
    ele <- unsafeRead elements r
    case ele of
      Nothing -> pure 0
      Just _ -> pure $! fromIntegral size
  else do
    let len' = w - r
    pure $! fromIntegral (if len' < 0 then len' + size else len')

-- | Returns 'True' if the supplied 'TBQueue' is empty.
isEmptyTBQueue :: TBQueue a -> STM Bool
isEmptyTBQueue (TBQueue rindex windex elements _) = do
  r <- readTVar rindex
  w <- readTVar windex
  if w == r then do
    ele <- unsafeRead elements r
    pure $! isNothing ele
  else
    pure False

-- | Returns 'True' if the supplied 'TBQueue' is full.
--
-- @since 2.4.3
isFullTBQueue :: TBQueue a -> STM Bool
isFullTBQueue (TBQueue rindex windex elements _) = do
  r <- readTVar rindex
  w <- readTVar windex
  if w == r then do
    ele <- unsafeRead elements r
    pure $! isJust ele
  else
    pure False
