-- | Timer.hs - ffi wrapped to get timer functions

module Timer
  ( -- * Delay functions
    delayUs, delayMs, delaySec
    -- * Timer reading
  , getTimeUs, getTimeMs
    -- * Timing measurements
  , timeIt, timeItUs
  ) where

import Data.Word
import Hal (c_timer_get_usec, c_delay_us, c_delay_ms)

-- | Delay for a number of microseconds
delayUs :: Word32 -> IO ()
delayUs = c_delay_us

-- | Delay for a number of milliseconds
delayMs :: Word32 -> IO ()
delayMs = c_delay_ms

-- | Delay for a number of seconds
delaySec :: Word32 -> IO ()
delaySec s = c_delay_ms (s * 1000)

-- | Get current time in microseconds (wraps every ~4295 seconds)
getTimeUs :: IO Word32
getTimeUs = c_timer_get_usec

-- | Get current time in milliseconds
getTimeMs :: IO Word32
getTimeMs = fmap (`div` 1000) c_timer_get_usec

-- | Time an IO action, return result and elapsed microseconds
timeIt :: IO a -> IO (a, Word32)
timeIt action = do
    start <- c_timer_get_usec
    result <- action
    end <- c_timer_get_usec
    return (result, end - start)

-- | Time an IO action, return only elapsed microseconds
timeItUs :: IO a -> IO Word32
timeItUs action = fmap snd (timeIt action)
