{- HLINT ignore "Use camelCase" -}
-- | echo.hs
--
-- Reads characters from UART and echoes them back.

module Main(main, hs_main) where

import Prelude hiding (putStr, putStrLn, getChar, putChar)
import Data.Word
import qualified UART

foreign export ccall hs_main :: IO ()

main :: IO ()
main = hs_main

hs_main :: IO ()
hs_main = do
    UART.putStrLn "UART Echo Test"
    UART.putStrLn "Press Ctrl-D to exit."
    UART.putStrLn ""
    echoLoop 0
  where
    echoLoop :: Word32 -> IO ()
    echoLoop count = do
        c <- UART.getChar
        case c of
            '\EOT' -> do  -- Ctrl-D
                UART.putStrLn ""
                UART.putStr "Total characters echoed: "
                UART.putUint count
                UART.putChar '\n'
                UART.putStrLn "Echo test complete."
            '\r' -> do
                UART.putChar '\n'
                echoLoop (count + 1)
            _ -> do
                UART.putChar c
                echoLoop (count + 1)
