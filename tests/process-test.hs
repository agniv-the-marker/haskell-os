{- HLINT ignore "Use camelCase" -}

-- | process-test.hs - tests for Process.hs
--
-- Tests Chan (send/recv/tryRecv), select, spawn/waitProc.
-- No special hardware needed beyond UART output.

module Main(main, hs_main) where

import Prelude hiding (putStr, putStrLn)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import qualified UART
import qualified Timer
import Process

foreign export ccall hs_main :: IO ()

main :: IO ()
main = hs_main

hs_main :: IO ()
hs_main = do
    UART.putStrLn "Process Test: Chan, select, spawn, waitProc"
    UART.putStrLn ""

    -- ===== Chan basic tests =====
    UART.putStrLn "--- Chan Tests ---"

    -- Test 1: basic send/recv roundtrip
    t1 <- do
        ch <- newChan :: IO (Chan Int)
        send ch 42
        val <- recv ch
        testEq "send/recv roundtrip" val 42

    -- Test 2: FIFO ordering
    t2 <- do
        ch <- newChan :: IO (Chan Int)
        send ch 1
        send ch 2
        send ch 3
        v1 <- recv ch
        v2 <- recv ch
        v3 <- recv ch
        testEq "FIFO ordering" (v1, v2, v3) (1, 2, 3)

    -- Test 3: tryRecv on empty channel
    t3 <- do
        ch <- newChan :: IO (Chan Int)
        val <- tryRecv ch
        testEq "tryRecv empty" val (Nothing :: Maybe Int)

    -- Test 4: tryRecv after send
    t4 <- do
        ch <- newChan :: IO (Chan Int)
        send ch 99
        val <- tryRecv ch
        testEq "tryRecv after send" val (Just 99)

    UART.putStrLn ""

    -- ===== Select tests =====
    UART.putStrLn "--- Select Tests ---"

    -- Test 5: select on 2 channels, second has data
    t5 <- do
        ch0 <- newChan :: IO (Chan Int)
        ch1 <- newChan :: IO (Chan Int)
        send ch1 77
        (idx, val) <- select [ch0, ch1]
        testEq "select second chan" (idx, val) (1, 77)

    -- Test 6: select on 2 channels, first has data
    t6 <- do
        ch0 <- newChan :: IO (Chan Int)
        ch1 <- newChan :: IO (Chan Int)
        send ch0 88
        (idx, val) <- select [ch0, ch1]
        testEq "select first chan" (idx, val) (0, 88)

    -- Test 7: select on 2 channels, both have data
    -- With round-robin, either channel may be picked first.
    -- We only assert: (a) the returned value matches the channel index,
    -- and (b) the other channel still has its item (select drains exactly one).
    t7 <- do
        ch0 <- newChan :: IO (Chan Int)
        ch1 <- newChan :: IO (Chan Int)
        send ch0 10
        send ch1 20
        (idx, val) <- select [ch0, ch1]
        let valOk = (idx == 0 && val == 10) || (idx == 1 && val == 20)
        -- the other channel must still have its item
        m0 <- tryRecv ch0
        m1 <- tryRecv ch1
        let otherOk = case idx of
              0 -> m1 == Just 20 && isNothing m0
              _ -> m0 == Just 10 && isNothing m1
        testBool "select both: got one valid item" (valOk && otherOk)

    UART.putStrLn ""

    -- ===== Spawn/waitProc tests =====
    UART.putStrLn "--- Spawn & WaitProc Tests ---"

    -- Test 8: spawn writes to channel, main reads
    t8 <- do
        ch <- newChan :: IO (Chan Int)
        _ <- forkIO $ do
            threadDelay 10000  -- 10ms
            send ch 123
        val <- recv ch
        testEq "spawn send, main recv" val 123

    -- Test 9: spawn + waitProc returns Done
    t9 <- do
        ph <- spawn "test-done" (threadDelay 10000)
        st <- waitProc ph
        testEq "waitProc Done" (show st) "Done"

    -- Test 10: cross-thread communication
    t10 <- do
        ch <- newChan :: IO (Chan Int)
        _ <- forkIO $ do
            send ch 1
            send ch 2
            send ch 3
        v1 <- recv ch
        v2 <- recv ch
        v3 <- recv ch
        testEq "cross-thread multi send" (v1 + v2 + v3) 6

    -- Test 11: multiple senders
    t11 <- do
        ch <- newChan :: IO (Chan Int)
        _ <- forkIO $ send ch 10
        _ <- forkIO $ send ch 20
        _ <- forkIO $ send ch 30
        threadDelay 50000  -- wait for all senders
        v1 <- recv ch
        v2 <- recv ch
        v3 <- recv ch
        -- Order may vary, but sum should be 60
        testEq "multi sender sum" (v1 + v2 + v3) 60

    -- Test 12: select with delayed sender
    t12 <- do
        ch0 <- newChan :: IO (Chan Int)
        ch1 <- newChan :: IO (Chan Int)
        _ <- forkIO $ do
            threadDelay 20000
            send ch1 55
        (idx, val) <- select [ch0, ch1]
        testEq "select with delayed sender" (idx, val) (1, 55)

    UART.putStrLn ""

    -- ===== Summary =====
    let results = [t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,t11,t12]
    let passed = length (filter id results)
    let total = length results

    UART.putStrLn "==========================="
    UART.putStr "Process tests: "
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
    if ok then UART.putStrLn "ok" else UART.putStrLn "FAIL"
    return ok

testEq :: (Eq a, Show a) => String -> a -> a -> IO Bool
testEq name got expected = do
    let ok = got == expected
    UART.putStr "  "
    UART.putStr name
    UART.putStr ": "
    if ok
      then UART.putStrLn "ok"
      else do
        UART.putStr "FAIL (got "
        UART.putStr (show got)
        UART.putStr ", expected "
        UART.putStr (show expected)
        UART.putStrLn ")"
    return ok