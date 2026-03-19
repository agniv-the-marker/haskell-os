-- | Alloc.hs - Memory allocator interface
-- we never free the memory which is fine, reboot to reclaim

module Alloc
  ( -- * Allocation
    alloc, allocAligned, allocZeroed
    -- * Pointer operations
  , Ptr
  , poke32, peek32, poke8, peek8, nullPtr, isNullPtr, ptrAdd, ptrToWord
  ) where

import Data.Word
import Data.Bits ((.&.), (.|.), shiftL, shiftR, complement)
import Control.Monad (when)
import Hal (put32, get32, c_kmalloc, c_kmalloc_aligned)

-- | A memory pointer (represented as Word32 address)
type Ptr = Word32

-- | Null pointer
nullPtr :: Ptr
nullPtr = 0

-- | Check if a pointer is null
isNullPtr :: Ptr -> Bool
isNullPtr = (== 0)

-- | Pointer arithmetic: add byte offset
ptrAdd :: Ptr -> Word32 -> Ptr
ptrAdd p n = p + n

-- | Convert pointer to Word32
ptrToWord :: Ptr -> Word32
ptrToWord = id

-- | Allocate n bytes (8-byte aligned)
alloc :: Word32 -> IO Ptr
alloc = c_kmalloc

-- | Allocate n bytes with specific alignment
allocAligned :: Word32 -> Word32 -> IO Ptr
allocAligned = c_kmalloc_aligned

-- | Allocate and zero n bytes
allocZeroed :: Word32 -> IO Ptr
allocZeroed n = do
    p <- c_kmalloc n
    let nWords = n `div` 4
    when (nWords > 0) $ mapM_ (\i -> put32 (p + i * 4) 0) [0 .. nWords - 1]
    return p

-- | Write a 32-bit value to a memory address
poke32 :: Ptr -> Word32 -> IO ()
poke32 = put32

-- | Read a 32-bit value from a memory address
peek32 :: Ptr -> IO Word32
peek32 = get32

-- | Write a single byte at an offset in a buffer.
-- ARM only has 32-bit aligned MMIO, so we read-mask-shift-write.
poke8 :: Ptr -> Word32 -> Word8 -> IO ()
poke8 buf off val = do
    let aligned = buf + (off .&. 0xFFFFFFFC)
    let byteOff = off .&. 3
    let shiftAmt = fromIntegral (byteOff * 8)
    old <- peek32 aligned
    let mask = complement (0xFF `shiftL` shiftAmt)
    let new_ = (old .&. mask) .|. (fromIntegral val `shiftL` shiftAmt)
    poke32 aligned new_

-- | Read a single byte at an offset from a buffer
peek8 :: Ptr -> Word32 -> IO Word8
peek8 buf off = do
    w <- peek32 (buf + (off .&. 0xFFFFFFFC))
    let byteOff = off .&. 3
    return (fromIntegral ((w `shiftR` fromIntegral (byteOff * 8)) .&. 0xFF))
