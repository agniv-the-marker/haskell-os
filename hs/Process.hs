-- | Process.hs - concurrent processes via forkIO
--
-- mvar needed to store state, threaddelay asw

module Process
  ( -- * Typed channels (local, backed by MVar)
    Chan(..)
  , newChan, send, recv, tryRecv
    -- * Select: wait on first available from multiple channels
  , select
    -- * Process spawning with supervision
  , ProcHandle(..)
  , ProcState(..)
  , spawn, waitProc
    -- * Supervisor
  , RestartPolicy(..)
  , ChildSpec(..)
  , supervisor
  ) where

import Prelude hiding (putStr, putStrLn)
import Data.Word
import Control.Monad (void)
import Control.Concurrent (forkIO, threadDelay, yield)
import Control.Concurrent.MVar
import qualified UART


-- | A typed channel for message passing between green threads.
-- Unbounded linked-list channel
-- Uses a pair of MVars: one guards the read end, one guards the
-- write end, connected by a chain of single-item MVar holes.
-- The sender never blocks (unbounded); the receiver blocks if empty.
data Chan a = Chan
  { chanRead  :: MVar (MVar (ChItem a))
  , chanWrite :: MVar (MVar (ChItem a))
  }

data ChItem a = ChItem a (MVar (ChItem a))

-- | Create a new empty channel.
newChan :: IO (Chan a)
newChan = do
    hole <- newEmptyMVar
    readEnd  <- newMVar hole
    writeEnd <- newMVar hole
    return (Chan readEnd writeEnd)

-- | Send a value on the channel (unbounded, never blocks on fullness).
-- Appends to the linked-list tail via the write-end MVar.
send :: Chan a -> a -> IO ()
send (Chan _ wVar) val = do
    newHole <- newEmptyMVar
    oldHole <- takeMVar wVar
    putMVar oldHole (ChItem val newHole)
    putMVar wVar newHole

-- | Receive a value from the channel. Blocks until data is available.
recv :: Chan a -> IO a
recv (Chan rVar _) = do
    readEnd <- takeMVar rVar
    (ChItem val newReadEnd) <- takeMVar readEnd
    putMVar rVar newReadEnd
    return val

-- | Non-blocking receive. Returns Nothing if no data is available.
tryRecv :: Chan a -> IO (Maybe a)
tryRecv (Chan rVar _) = do
    readEnd <- takeMVar rVar
    mItem <- tryTakeMVar readEnd
    case mItem of
      Nothing -> do
        putMVar rVar readEnd
        return Nothing
      Just (ChItem val newReadEnd) -> do
        putMVar rVar newReadEnd
        return (Just val)

-- | Wait on multiple channels, return the first one that has data.
-- Returns (channel index, value). uses round robin
select :: [Chan a] -> IO (Int, a)
select chans = do
    startVar <- newMVar 0
    go startVar
  where
    n = length chans
    go startVar = do
        start <- readMVar startVar
        result <- tryFrom start 0
        case result of
            Just r  -> do
                void $ swapMVar startVar ((start + 1) `mod` n)
                return r
            Nothing -> do
                yield
                threadDelay 1000  -- 1ms backoff so other threads run
                go startVar
    tryFrom _ tried | tried >= n = return Nothing
    tryFrom idx tried = do
        let i = idx `mod` n
        mval <- tryRecv (chans !! i)
        case mval of
            Just val -> return (Just (i, val))
            Nothing  -> tryFrom (idx + 1) (tried + 1)

-- | Process state.
-- Without try/catch in MicroHs, we can only detect clean exits (Done).
-- A crash in the reducer kills the thread silently (state stays Running).
data ProcState = Running | Done
  deriving (Show)

-- | A handle to a spawned process
data ProcHandle = ProcHandle
  { procName  :: String
  , procState :: MVar ProcState
  }

-- | Spawn a named green thread. Returns a handle that can be used
-- to monitor the process state.
spawn :: String -> IO () -> IO ProcHandle
spawn name action = do
    stVar <- newMVar Running
    void $ forkIO $ do
        action
        void $ swapMVar stVar Done
    return (ProcHandle name stVar)

-- | Wait for a process to complete (blocking).
-- Uses threadDelay + yield to poll without burning CPU.
waitProc :: ProcHandle -> IO ProcState
waitProc ph = go
  where
    go = do
        st <- readMVar (procState ph)
        case st of
          Running -> do
            threadDelay 10000  -- 10ms poll interval
            go
          _ -> return st

-- | Restart policy for supervised children.
data RestartPolicy
  = Permanent   -- ^ Always restart on exit
  | Temporary   -- ^ Never restart
  deriving (Eq, Show)

-- | Specification for a supervised child process
data ChildSpec = ChildSpec
  { csName    :: String         -- ^ Process name (for logging)
  , csAction  :: IO ()          -- ^ The IO action to run
  , csPolicy  :: RestartPolicy  -- ^ When to restart
  }

-- | Run a supervisor that monitors and restarts child processes.
-- Runs forever, checking children every 100ms.
supervisor :: [ChildSpec] -> IO ()
supervisor specs = do
    UART.putStrLn "Supervisor: Starting children..."
    handles <- mapM spawnChild specs
    monitorLoop (zip specs handles)

  where
    spawnChild spec = do
        UART.putStr "  Starting: "
        UART.putStrLn (csName spec)
        spawn (csName spec) (csAction spec)

    monitorLoop children = do
        threadDelay 100000  -- 100ms check interval
        children' <- mapM checkChild children
        monitorLoop children'

    checkChild (spec, handle) = do
        st <- readMVar (procState handle)
        case st of
          Running -> return (spec, handle)
          Done -> case csPolicy spec of
              Permanent -> restart spec
              Temporary -> return (spec, handle)

    restart spec = do
        UART.putStr "Supervisor: Restarting "
        UART.putStrLn (csName spec)
        h <- spawnChild spec
        return (spec, h)
