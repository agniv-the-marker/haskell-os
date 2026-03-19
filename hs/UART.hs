-- | UART.hs - lab 7, uart driver w/ string io
-- 
-- Example:
--   putStr "Hello, Pi!\n"
--   line <- getLine
--   putStr ("You said: " ++ line ++ "\n")

module UART
  ( -- * Initialization
    uartInit
    -- * Byte-level I/O
  , putByte, getByte, hasData
    -- * String I/O
  , putChar, putStr, putStrLn, getChar, getLine
    -- * Formatted output
  , putHex, putUint, putWord32, putInt
    -- * Debugging
  , trace, traceShow, panic
  ) where

import Prelude hiding (putChar, putStr, putStrLn, getChar, getLine)
import Data.Word
import Control.Concurrent (yield)
import Hal
import qualified Interrupt

-- | Initialize UART
uartInit :: IO ()
uartInit = c_uart_init

-- | Send a single byte
putByte :: Word8 -> IO ()
putByte b = c_uart_put8 (fromIntegral b)

-- | Receive a single byte (blocks until data available)
getByte :: IO Word8
getByte = fmap fromIntegral c_uart_get8

-- | Check if data is available to read
hasData :: IO Bool
hasData = fmap (/= 0) c_uart_has_data

-- | Send a character (converts \n to \r\n)
putChar :: Char -> IO ()
putChar '\n' = do
    c_uart_put8 (fromIntegral (fromEnum '\r'))
    c_uart_put8 (fromIntegral (fromEnum '\n'))
putChar c = c_uart_put8 (fromIntegral (fromEnum c))

-- | Send a string
putStr :: String -> IO ()
putStr = mapM_ putChar

-- | Send a string with newline
putStrLn :: String -> IO ()
putStrLn s = putStr s >> putChar '\n'

-- | Read a character
--
-- Check the interrupt ring buffer first (filled by IRQ handler).
-- Fall back to polling hasData + yield for before interrupts are enabled.
-- Either way, green threads get CPU time while waiting for input.
getChar :: IO Char
getChar = go
  where
    go = do
        -- Check interrupt ring buffer first
        mb <- Interrupt.uartRxRead
        case mb of
          Just b  -> return (toEnum (fromIntegral b))
          Nothing -> do
            -- Fall back to direct polling
            avail <- hasData
            if avail
              then do
                toEnum . fromIntegral <$> getByte
              else do
                yield  -- let other green threads run
                go

-- | Read a line (until CR or LF), with local echo,
--   i couldnt get backspace to work?? idk why
getLine :: IO String
getLine = go []
  where
    go acc = do
        c <- getChar
        case c of
            '\r' -> do
                putChar '\n'
                return (reverse acc)
            '\n' -> do
                putChar '\n'
                return (reverse acc)
            '\DEL' -> case acc of
                [] -> go []
                (_:rest) -> do
                    putByte 0x08  -- move cursor back
                    putByte 0x20  -- overwrite with space
                    putByte 0x08  -- move cursor back again
                    go rest
            '\BS' -> case acc of
                [] -> go []
                (_:rest) -> do
                    putByte 0x08
                    putByte 0x20
                    putByte 0x08
                    go rest
            _ -> do
                putChar c  -- echo
                go (c : acc)

-- | Print a Word32 as hex
putHex :: Word32 -> IO ()
putHex = c_uart_put_hex

-- | Print a Word32 as unsigned decimal
putUint :: Word32 -> IO ()
putUint = c_uart_put_uint

-- | Print a Word32 with label
putWord32 :: String -> Word32 -> IO ()
putWord32 label val = do
    putStr label
    putStr ": "
    putHex val
    putChar '\n'

-- | Print a signed integer
putInt :: Int -> IO ()
putInt n
  | n < 0     = putChar '-' >> putUint (fromIntegral (negate n))
  | otherwise  = putUint (fromIntegral n)

-- | Debug trace: print a message
trace :: String -> IO ()
trace msg = putStr "[TRACE] " >> putStrLn msg

-- | Debug trace with Show
traceShow :: Show a => String -> a -> IO ()
traceShow label val = do
    putStr "[TRACE] "
    putStr label
    putStr " = "
    print val

-- | Panic: print message and halt
panic :: String -> IO ()
panic msg = do
    putStr "\r\n!!! PANIC: "
    putStrLn msg
    c_reboot
