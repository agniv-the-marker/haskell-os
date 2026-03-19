{- HLINT ignore "Use camelCase" -}
-- | ls.hs - FAT32 directory listing test

module Main(main, hs_main) where

import Prelude hiding (putStr, putStrLn)
import qualified UART
import qualified FAT32

foreign export ccall hs_main :: IO ()

main :: IO ()
main = hs_main

hs_main :: IO ()
hs_main = do
    UART.putStrLn "FAT32 Directory Listing Test"
    UART.putStrLn ""

    mfs <- FAT32.mountFS
    case mfs of
        Nothing -> UART.putStrLn "FAILED: Could not mount filesystem"
        Just fs -> do
            FAT32.printFSInfo fs
            UART.putStrLn ""
            UART.putStrLn "Root directory:"
            entries <- FAT32.listRoot fs
            mapM_ FAT32.printDirEntry entries
            UART.putStr "Total: "
            UART.putUint (fromIntegral (length entries))
            UART.putStrLn " entries"
            UART.putStrLn ""
            UART.putStrLn "FAT32 test PASSED"
