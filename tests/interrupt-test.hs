{- HLINT ignore "Use camelCase" -}

-- | interrupt-test.hs - tests for Interrupt.hs
--
-- Tests timer tick counting and UART RX interrupt buffer.
-- Requires real hardware with timer + UART.

module Main(main, hs_main) where

import Prelude hiding (putStr, putStrLn)
import Data.Word
import qualified UART
import qualified Timer
import qualified Interrupt

foreign export ccall hs_main :: IO ()

main :: IO ()
main = hs_main

hs_main :: IO ()
hs_main = do
    UART.putStrLn "Interrupt Test: Timer ticks, UART RX buffer"
    UART.putStrLn ""

    -- ===== Timer interrupt tests =====
    UART.putStrLn "--- Timer Interrupt Tests ---"

    -- Test 1: init timer interrupt (10ms = 10000us)
    Interrupt.initTimerInterrupt 10000
    t1 <- testBool "initTimerInterrupt 10000" True  -- didn't crash
    UART.putStrLn "  (waiting 50ms for ticks...)"

    -- Read baseline
    baseline <- Interrupt.timerTicks

    -- Test 2: after 50ms, ticks should increase by ~5
    Timer.delayMs 50
    ticks1 <- Interrupt.timerTicks
    let delta1 = ticks1 - baseline
    UART.putStr "  ticks after 50ms: delta="
    UART.putUint delta1
    UART.putStrLn ""
    t2 <- testBool "50ms ~5 ticks" (delta1 >= 3 && delta1 <= 8)

    -- Test 3: after another 200ms, ticks should increase by ~20
    UART.putStrLn "  (waiting 200ms for more ticks...)"
    baseline2 <- Interrupt.timerTicks
    Timer.delayMs 200
    ticks2 <- Interrupt.timerTicks
    let delta2 = ticks2 - baseline2
    UART.putStr "  ticks after 200ms: delta="
    UART.putUint delta2
    UART.putStrLn ""
    t3 <- testBool "200ms ~20 ticks" (delta2 >= 15 && delta2 <= 25)

    UART.putStrLn ""

    -- ===== UART interrupt tests =====
    UART.putStrLn "--- UART RX Interrupt Tests ---"

    -- Test 4: init UART interrupt
    Interrupt.initUartInterrupt
    t4 <- testBool "initUartInterrupt" True  -- didn't crash

    -- Test 5: no data pending at startup (before user types)
    hasData <- Interrupt.uartRxHasData
    t5 <- testBool "uartRxHasData false at startup" (not hasData)

    UART.putStrLn ""

    -- ===== Summary =====
    let results = [t1,t2,t3,t4,t5]
    let passed = length (filter id results)
    let total = length results

    UART.putStrLn "==========================="
    UART.putStr "Interrupt tests: "
    UART.putUint (fromIntegral passed)
    UART.putStr "/"
    UART.putUint (fromIntegral total)
    UART.putStrLn ""
    UART.putStrLn "==========================="

    if passed == total
      then UART.putStrLn "ALL TESTS PASSED"
      else UART.putStrLn "SOME TESTS FAILED"

-- ================================================================
-- Test helpers
-- ================================================================

testBool :: String -> Bool -> IO Bool
testBool name ok = do
    UART.putStr "  "
    UART.putStr name
    UART.putStr ": "
    if ok
      then UART.putStrLn "ok"
      else UART.putStrLn "FAIL"
    return ok
