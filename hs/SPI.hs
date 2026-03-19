-- | SPI.hs - ffi wrapped over c/spi.c for nrf lab

module SPI
  ( -- * SPI handle
    SpiHandle(..)
    -- * Initialization
  , spiInit
    -- * Transfer operations
  , spiTransfer, spiWrite, spiRead, spiSetChipSelect
  ) where

import Data.Word
import Control.Monad (void)
import Hal (c_spi_init, c_spi_transfer, c_spi_set_chip_select)
import Alloc (alloc, Ptr, poke8, peek8)

-- | An SPI handle tracks which chip select line is in use.
newtype SpiHandle = SpiHandle Word32
  deriving (Eq, Show)

-- | Initialize SPI0 with the given chip select and clock divider
spiInit :: Word32 -> Word32 -> IO SpiHandle
spiInit cs clkDiv = do
    c_spi_init cs clkDiv
    return (SpiHandle cs)

-- | Full-duplex SPI transfer. Sends tx bytes and returns received bytes.
spiTransfer :: SpiHandle -> [Word8] -> IO [Word8]
spiTransfer (SpiHandle _cs) txBytes = do
    let n = length txBytes
    let nbytes = fromIntegral n :: Word32
    -- Allocate buffers (aligned to 4 bytes, with padding)
    txBuf <- alloc (nbytes + 4)
    rxBuf <- alloc (nbytes + 4)
    -- Write TX data byte-by-byte into the buffer
    writeBytes txBuf 0 txBytes
    -- Perform transfer
    c_spi_transfer rxBuf txBuf nbytes
    -- Read RX data
    readBytes rxBuf nbytes

-- | Write-only SPI transfer. Discards received data.
spiWrite :: SpiHandle -> [Word8] -> IO ()
spiWrite h txBytes = void (spiTransfer h txBytes)

-- | Read-only SPI transfer. Sends NOP bytes (0xFF) and returns received data.
spiRead :: SpiHandle -> Int -> IO [Word8]
spiRead h n = spiTransfer h (replicate n 0xFF)

-- | Switch the active chip select line
spiSetChipSelect :: Word32 -> IO ()
spiSetChipSelect = c_spi_set_chip_select

-- | write a list of bytes into a memory buffer.
writeBytes :: Ptr -> Word32 -> [Word8] -> IO ()
writeBytes _   _   []     = return ()
writeBytes buf off (b:bs) = poke8 buf off b >> writeBytes buf (off + 1) bs

-- | read bytes from a memory buffer.
readBytes :: Ptr -> Word32 -> IO [Word8]
readBytes buf nbytes = mapM (peek8 buf) [0 .. nbytes - 1]
