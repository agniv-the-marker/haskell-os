{- HLINT ignore "Use camelCase" -}
-- | blink.hs
--
-- Blinks an LED on pin 27 forever.

module Main(main, hs_main) where

import Prelude hiding (putStr, putStrLn)
import qualified UART
import qualified GPIO
import qualified Timer

foreign export ccall hs_main :: IO ()

main :: IO ()
main = hs_main

hs_main :: IO ()
hs_main = do
    UART.putStrLn "Blink test: pin 27"
    pin <- GPIO.outputPin 27
    blinkForever pin
  where
    blinkForever pin = do
        GPIO.pinOn pin
        Timer.delayMs 500
        GPIO.pinOff pin
        Timer.delayMs 500
        blinkForever pin
