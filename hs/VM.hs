-- | VM.hs - labs 13/15/17 in haskell, but most things are asm

module VM
  ( -- * Types
    PageTableEntry(..)
  , AccessPerm(..)
  , DomainAccess(..)
  , CachePolicy(..)
  , MemRegion(..)
    -- * Page table operations
  , createPageTable, mapRegion
    -- * MMU control
  , mmuEnable, mmuDisable, setDomainAccess
    -- * Predefined regions
  , kernelCodeRegion, kernelHeapRegion, deviceRegion, stackRegion, irqStackRegion, mhsHeapRegion
    -- * Boot
  , initMMU
    -- * Constants
  , mbToAddr, sectionSize
  ) where

import Data.Word
import Data.Bits
import Alloc
import qualified UART
import Hal (devBarrier)

foreign import ccall "mmu_enable"         c_mmu_enable       :: IO ()
foreign import ccall "mmu_disable"        c_mmu_disable      :: IO ()
foreign import ccall "mmu_set_ttbr0"      c_mmu_set_ttbr0    :: Word32 -> IO ()
foreign import ccall "mmu_set_domain"     c_mmu_set_domain   :: Word32 -> IO ()
foreign import ccall "mmu_inv_tlb"        c_mmu_inv_tlb      :: IO ()
foreign import ccall "mmu_get_domain"     c_mmu_get_domain   :: IO Word32

-- | Section size
sectionSize :: Word32
sectionSize = 0x100000  -- 1MB

-- | Convert MB to address
mbToAddr :: Word32 -> Word32
mbToAddr mb = mb * sectionSize

-- | Access permissions
data AccessPerm
  = APNoAccess    -- ^ 00: No access
  | APPrivOnly    -- ^ 01: Privileged only
  | APUserRO      -- ^ 10: User read-only
  | APFullAccess  -- ^ 11: Full access
  deriving (Eq, Show)

apToBits :: AccessPerm -> Word32
apToBits APNoAccess   = 0
apToBits APPrivOnly   = 1
apToBits APUserRO     = 2
apToBits APFullAccess = 3

-- | Domain access control
data DomainAccess
  = DomainNoAccess  -- ^ 00: Any access generates fault
  | DomainClient    -- ^ 01: Check AP bits
  | DomainManager   -- ^ 11: No permission checks
  deriving (Eq, Show)

domainToBits :: DomainAccess -> Word32
domainToBits DomainNoAccess = 0
domainToBits DomainClient   = 1
domainToBits DomainManager  = 3

-- | Cache policy
data CachePolicy
  = Uncached       -- ^ No caching (C=0, B=0)
  | WriteThrough   -- ^ Write-through (C=1, B=0)
  | WriteBack      -- ^ Write-back (C=1, B=1)
  deriving (Eq, Show)

cacheToBits :: CachePolicy -> (Word32, Word32)
cacheToBits Uncached     = (0, 0)
cacheToBits WriteThrough = (1, 0)
cacheToBits WriteBack    = (1, 1)

-- | Page table entry for a 1MB section
data PageTableEntry = PTE
  { ptePA       :: !Word32       -- ^ Physical address (aligned to 1MB)
  , pteAP       :: !AccessPerm
  , pteDomain   :: !Word8        -- ^ Domain number (0-15)
  , pteCache    :: !CachePolicy
  , pteExecute  :: !Bool         -- ^ XN (Execute Never) = False means executable
  } deriving (Eq, Show)

-- | A memory region definition
data MemRegion = MemRegion
  { mrVA    :: !Word32         -- ^ Virtual address start
  , mrPA    :: !Word32         -- ^ Physical address start
  , mrSize  :: !Word32         -- ^ Size in bytes (must be multiple of 1MB)
  , mrPerm  :: !AccessPerm
  , mrDom   :: !Word8
  , mrCache :: !CachePolicy
  } deriving (Show)

-- | Create a page table (4096 entries * 4 bytes = 16KB, 16KB-aligned)
createPageTable :: IO Ptr
createPageTable = do
    pt <- allocAligned (4096 * 4) (16 * 1024)
    mapM_ (\i -> poke32 (pt + i * 4) 0) [0..4095]
    return pt

-- | Encode a PTE into the hardware format (section descriptor)
encodePTE :: PageTableEntry -> Word32
encodePTE pte =
    let (cBit, bBit) = cacheToBits (pteCache pte)
        xnBit = if pteExecute pte then 0 else 1
        ap    = apToBits (pteAP pte)
    in  (ptePA pte .&. 0xFFF00000)     -- Section base address [31:20]
        .|. (ap `shiftL` 10)           -- AP bits [11:10]
        .|. (fromIntegral (pteDomain pte) `shiftL` 5)  -- Domain [8:5]
        .|. (cBit `shiftL` 3)          -- C bit [3]
        .|. (bBit `shiftL` 2)          -- B bit [2]
        .|. (xnBit `shiftL` 4)        -- XN bit [4]
        .|. 0x2                        -- Section type bits [1:0] = 10

-- | Map a region with explicit VA -> PA mapping
mapRegion :: Ptr -> MemRegion -> IO ()
mapRegion pt region = go (mrVA region) (mrPA region) (mrSize region)
  where
    go _ _ 0 = return ()
    go va pa remaining = do
        let pte = PTE
              { ptePA      = pa
              , pteAP      = mrPerm region
              , pteDomain  = mrDom region
              , pteCache   = mrCache region
              , pteExecute = True
              }
        let index = va `shiftR` 20
        poke32 (pt + index * 4) (encodePTE pte)
        go (va + sectionSize) (pa + sectionSize) (remaining - sectionSize)

-- | Enable the MMU with the given page table
mmuEnable :: Ptr -> IO ()
mmuEnable pt = do
    UART.putStrLn "Enabling MMU..."
    c_mmu_set_ttbr0 pt
    devBarrier
    c_mmu_enable
    UART.putStrLn "MMU enabled"

-- | Disable the MMU
mmuDisable :: IO ()
mmuDisable = do
    c_mmu_disable
    devBarrier
    UART.putStrLn "MMU disabled"

-- | Set domain access control register
-- Each domain (0-15) gets 2 bits in the 32-bit register
setDomainAccess :: Word8 -> DomainAccess -> IO ()
setDomainAccess dom access = do
    let shift = fromIntegral dom * 2
    let bits  = domainToBits access `shiftL` shift
    let mask  = complement (3 `shiftL` shift)
    current <- c_mmu_get_domain
    c_mmu_set_domain ((current .&. mask) .|. bits)

-- | Kernel code region (identity mapped, cached, executable)
kernelCodeRegion :: MemRegion
kernelCodeRegion = MemRegion
  { mrVA    = 0x00000000
  , mrPA    = 0x00000000
  , mrSize  = sectionSize     -- First 1MB
  , mrPerm  = APPrivOnly
  , mrDom   = 0
  , mrCache = WriteBack
  }

-- | Kernel heap region (identity mapped, cached)
kernelHeapRegion :: MemRegion
kernelHeapRegion = MemRegion
  { mrVA    = sectionSize        -- 1MB
  , mrPA    = sectionSize
  , mrSize  = 127 * sectionSize  -- 127MB
  , mrPerm  = APFullAccess
  , mrDom   = 0
  , mrCache = WriteBack
  }

-- | Device registers
-- BCM2835 peripherals span 0x20000000-0x20FFFFFF (16MB).
-- EMMC is at 0x20300000, so we need at least 4MB.
deviceRegion :: MemRegion
deviceRegion = MemRegion
  { mrVA    = 0x20000000
  , mrPA    = 0x20000000
  , mrSize  = 16 * sectionSize  -- 16MB for all BCM peripherals
  , mrPerm  = APPrivOnly
  , mrDom   = 0
  , mrCache = Uncached
  }

-- | Stack region (supervisor stack near 128MB)
stackRegion :: MemRegion
stackRegion = MemRegion
  { mrVA    = 0x07000000
  , mrPA    = 0x07000000
  , mrSize  = sectionSize * 16    -- 16MB covering stack area
  , mrPerm  = APFullAccess
  , mrDom   = 0
  , mrCache = WriteBack
  }

-- | IRQ stack + gap region (32MB closes gap to mhsHeapRegion at 0x0A000000)
irqStackRegion :: MemRegion
irqStackRegion = MemRegion
  { mrVA    = 0x08000000
  , mrPA    = 0x08000000
  , mrSize  = sectionSize * 32    -- 32MB (0x08000000 - 0x0A000000)
  , mrPerm  = APFullAccess
  , mrDom   = 0
  , mrCache = WriteBack
  }

-- | MicroHs heap region (starts at 0x0A000000, 200MB)
mhsHeapRegion :: MemRegion
mhsHeapRegion = MemRegion
  { mrVA    = 0x0A000000
  , mrPA    = 0x0A000000
  , mrSize  = 200 * sectionSize   -- 200MB
  , mrPerm  = APFullAccess
  , mrDom   = 0
  , mrCache = WriteBack
  }

-- | Initialize MMU with all kernel regions and enable permanently.
-- Uses DomainClient for domain 0 to enforce AP bits.
initMMU :: IO ()
initMMU = do
    pt <- createPageTable
    mapRegion pt kernelCodeRegion
    mapRegion pt kernelHeapRegion
    mapRegion pt stackRegion
    mapRegion pt irqStackRegion
    mapRegion pt mhsHeapRegion
    mapRegion pt deviceRegion
    setDomainAccess 0 DomainClient
    mmuEnable pt
