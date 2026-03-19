-- | GPIO.hs - based on lab 2. handles c via ffi. 
--
-- introduces output/input pin types
--
-- Example:
--   pin <- outputPin 27      -- Configure pin 27 as output
--   pinWrite pin High         -- Turn on
--   delayMs 500
--   pinWrite pin Low          -- Turn off
module GPIO
  ( -- * Pin types
    Pin(..)
  , OutputPin
  , InputPin
  , PinMode(..)
  , PinLevel(..)
  , GpioFunc(..)
    -- * Pin configuration
  , outputPin, inputPin, setFunction
    -- * Output operations
  , pinWrite, pinOn, pinOff, pinToggle
    -- * Input operations
  , pinRead, pinIsHigh, pinIsLow
    -- * Raw pin access
  , rawWrite, rawRead, rawSetOutput, rawSetInput
    -- * LED helpers
  , blink, blinkN
  ) where

import Data.Word
import Control.Monad (replicateM_)
import Hal
import Timer (delayMs)

-- | A GPIO pin number (0-53 on BCM2835)
newtype Pin = Pin { pinNumber :: Word32 }
  deriving (Eq, Show)

-- | A pin configured for output
newtype OutputPin = OutputPin Pin
  deriving (Eq, Show)

-- | A pin configured for input
newtype InputPin = InputPin Pin
  deriving (Eq, Show)

-- | Pin modes
data PinMode = Input | Output
  deriving (Eq, Show)

-- | Pin levels
data PinLevel = Low | High
  deriving (Eq, Show)

-- | GPIO alternate functions
data GpioFunc
  = FuncInput   -- ^ 000
  | FuncOutput  -- ^ 001
  | FuncAlt0    -- ^ 100
  | FuncAlt1    -- ^ 101
  | FuncAlt2    -- ^ 110
  | FuncAlt3    -- ^ 111
  | FuncAlt4    -- ^ 011
  | FuncAlt5    -- ^ 010
  deriving (Eq, Show)

gpioFuncToWord :: GpioFunc -> Word32
gpioFuncToWord FuncInput  = 0
gpioFuncToWord FuncOutput = 1
gpioFuncToWord FuncAlt0   = 4
gpioFuncToWord FuncAlt1   = 5
gpioFuncToWord FuncAlt2   = 6
gpioFuncToWord FuncAlt3   = 7
gpioFuncToWord FuncAlt4   = 3
gpioFuncToWord FuncAlt5   = 2

-- | Maximum valid pin number
maxPin :: Word32
maxPin = 53

-- | Validate a pin number
validPin :: Word32 -> Bool
validPin n = n <= maxPin

-- | Set the alternate function for a pin
setFunction :: Pin -> GpioFunc -> IO ()
setFunction (Pin n) func
  | not (validPin n) = return ()
  | otherwise = c_gpio_set_function n (gpioFuncToWord func)

-- | Configure a pin as output, return typed OutputPin
outputPin :: Word32 -> IO OutputPin
outputPin n = do
    c_gpio_set_output n
    return (OutputPin (Pin n))

-- | Configure a pin as input, return typed InputPin
inputPin :: Word32 -> IO InputPin
inputPin n = do
    c_gpio_set_input n
    return (InputPin (Pin n))

-- | Write a level to an output pin
pinWrite :: OutputPin -> PinLevel -> IO ()
pinWrite (OutputPin (Pin n)) Low  = c_gpio_set_off n
pinWrite (OutputPin (Pin n)) High = c_gpio_set_on n

-- | Turn an output pin on
pinOn :: OutputPin -> IO ()
pinOn p = pinWrite p High

-- | Turn an output pin off
pinOff :: OutputPin -> IO ()
pinOff p = pinWrite p Low

-- | Toggle an output pin (reads current state and inverts)
pinToggle :: OutputPin -> IO ()
pinToggle op@(OutputPin (Pin n)) = do
    v <- c_gpio_read n
    if v /= 0
      then pinOff op
      else pinOn op

-- | Read an input pin
pinRead :: InputPin -> IO PinLevel
pinRead (InputPin (Pin n)) = do
    v <- c_gpio_read n
    return (if v /= 0 then High else Low)

-- | Check if input pin is high
pinIsHigh :: InputPin -> IO Bool
pinIsHigh p = do
    v <- pinRead p
    return (v == High)

-- | Check if input pin is low
pinIsLow :: InputPin -> IO Bool
pinIsLow p = do
    v <- pinRead p
    return (v == Low)

-- | Raw write (bypasses type safety)
rawWrite :: Word32 -> Word32 -> IO ()
rawWrite = c_gpio_write

-- | Raw read (bypasses type safety)
rawRead :: Word32 -> IO Word32
rawRead = c_gpio_read

-- | Raw set output mode
rawSetOutput :: Word32 -> IO ()
rawSetOutput = c_gpio_set_output

-- | Raw set input mode
rawSetInput :: Word32 -> IO ()
rawSetInput = c_gpio_set_input

-- | Blink a pin with given delay in milliseconds
blink :: OutputPin -> Word32 -> IO ()
blink pin ms = do
    pinOn pin
    delayMs ms
    pinOff pin
    delayMs ms

-- | Blink a pin N times
blinkN :: OutputPin -> Word32 -> Int -> IO ()
blinkN pin ms n = replicateM_ n (blink pin ms)
