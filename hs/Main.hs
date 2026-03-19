{- HLINT ignore "Use camelCase" -}
-- | Main.hs - HaskellOS entry point
--
-- called from cstart.c and exports hs_main
-- ignore camel case for hs_main 
-- need to intialize hardware systems and launch shell

module Main(main, hs_main) where

import Prelude hiding (putStr, putStrLn, getLine)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import qualified UART
import qualified GPIO
import qualified Timer
import qualified FAT32
import qualified Interrupt
import qualified VM
import Shell (runShell)
import Process (ChildSpec(..), RestartPolicy(..), supervisor)

-- | Entry point called from C
foreign export ccall hs_main :: IO ()

-- | MicroHs requires Main.main
main :: IO ()
main = hs_main

-- | Main entry point
hs_main :: IO ()
hs_main = do
    -- Banner
    mapM_ UART.putStrLn
        [ ""
        , "  _   _           _        _ _  ___  ____  "
        , " | | | | __ _ ___| | _____| | |/ _ \\/ ___| "
        , " | |_| |/ _` / __| |/ / _ \\ | | | | \\___ \\ "
        , " |  _  | (_| \\__ \\   <  __/ | | |_| |___) |"
        , " |_| |_|\\__,_|___/_|\\_\\___|_|_|\\___/|____/ "
        , ""
        ]
    UART.putStrLn "Bare-metal Haskell OS for Raspberry Pi Zero"
    UART.putStrLn "============================================"

    -- Show timer
    t <- Timer.getTimeUs
    UART.putStr "Boot time: "
    UART.putUint t
    UART.putStrLn " us"

    -- GPIO quick blink to show we're alive
    UART.putStrLn "GPIO: Blinking pin 27 (3x)..."
    pin <- GPIO.outputPin 27
    GPIO.blinkN pin 100 3
    UART.putStrLn "GPIO: Done"

    -- enable hardware interrupts for timer/uart
    UART.putStrLn ""
    UART.putStrLn "Enabling interrupts..."
    Interrupt.initTimerInterrupt 10000  -- 10ms tick
    Interrupt.initUartInterrupt
    UART.putStrLn "Timer + UART interrupts enabled"

    -- Try to mount FAT32
    UART.putStrLn ""
    UART.putStrLn "Attempting FAT32 mount..."
    mfs <- FAT32.mountFS

    case mfs of
        Nothing -> UART.putStrLn "FAT32: Not available (no SD card or mount failed)"
        Just fs -> UART.putStrLn "FAT32: Mounted Successfully"

    -- Enable MMU permanently
    UART.putStrLn ""
    UART.putStrLn "Enabling MMU..."
    VM.initMMU

    -- Create shared state for heartbeat
    heartbeatPin <- GPIO.outputPin 27
    heartbeatVar <- newMVar True

    -- Launch supervisor, heartbeat and shell as Permanent children
    UART.putStrLn ""
    supervisor
        [ ChildSpec "heartbeat" (heartbeat heartbeatPin heartbeatVar) Permanent
        , ChildSpec "shell"     (runShell mfs heartbeatVar)           Permanent
        ]

-- | Background heartbeat blink LED via green threading, need threadDelay
-- as eval.c's scheduler can then run other threads. readMVar is nondestructive,
-- so the shell can swapMVar without contention.
heartbeat :: GPIO.OutputPin -> MVar Bool -> IO ()
heartbeat pin activeVar = go
  where
    go = do
        active <- readMVar activeVar
        if active
          then do
            GPIO.pinOn pin
            threadDelay 500000   -- 500ms on
            GPIO.pinOff pin
            threadDelay 500000   -- 500ms off
          else
            threadDelay 1000000  -- 1s idle poll
        go
