{- HLINT ignore "Use camelCase" -}

-- | vm-test.hs - tests for VM.hs
--
-- Tests PTE encoding, region definitions, page table allocation,
-- MMU enable/disable integration. Requires real ARM hardware.

module Main(main, hs_main) where

import Prelude hiding (putStr, putStrLn)
import Data.Word
import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import qualified UART
import qualified GPIO
import qualified Timer
import qualified VM
import Alloc (Ptr, peek32)

foreign export ccall hs_main :: IO ()

main :: IO ()
main = hs_main

hs_main :: IO ()
hs_main = do
    UART.putStrLn "VM Test: Page tables, regions, MMU enable/disable"
    UART.putStrLn ""

    -- ===== Constants tests =====
    UART.putStrLn "--- Constants ---"

    t1 <- testEq "sectionSize" VM.sectionSize 0x100000
    t2 <- testEq "mbToAddr 4" (VM.mbToAddr 4) 0x400000
    t3 <- testEq "mbToAddr 0" (VM.mbToAddr 0) 0x000000
    t4 <- testEq "mbToAddr 128" (VM.mbToAddr 128) 0x08000000

    UART.putStrLn ""

    -- ===== Region definitions =====
    UART.putStrLn "--- Region Definitions ---"

    t5 <- testEq "kernelCode VA" (VM.mrVA VM.kernelCodeRegion) 0x00000000
    t6 <- testEq "kernelCode PA" (VM.mrPA VM.kernelCodeRegion) 0x00000000
    t7 <- testEq "kernelCode size" (VM.mrSize VM.kernelCodeRegion) VM.sectionSize
    t8 <- testEq "device VA" (VM.mrVA VM.deviceRegion) 0x20000000
    t9 <- testEq "device PA" (VM.mrPA VM.deviceRegion) 0x20000000
    t10 <- testEq "device size" (VM.mrSize VM.deviceRegion) (3 * VM.sectionSize)

    UART.putStrLn ""

    -- ===== Page table allocation =====
    UART.putStrLn "--- Page Table ---"

    pt <- VM.createPageTable
    t11 <- testBool "createPageTable non-null" (pt /= 0)
    t12 <- testBool "createPageTable 16KB aligned" ((pt .&. 0x3FFF) == 0)

    -- Verify table is zeroed (check first and last entries)
    first <- peek32 pt
    t13 <- testEq "PT entry 0 is zero" first 0

    last_ <- peek32 (pt + 4095 * 4)
    t14 <- testEq "PT entry 4095 is zero" last_ 0

    UART.putStrLn ""

    -- ===== mapRegion + readback =====
    UART.putStrLn "--- mapRegion ---"

    -- Map kernel code region and read back the PTE
    VM.mapRegion pt VM.kernelCodeRegion
    pte0 <- peek32 pt  -- index 0 (VA=0x00000000 >> 20 = 0)
    -- Expect: PA=0, AP=01(PrivOnly)=1<<10, domain=0, C=1,B=1(WriteBack), XN=0, type=0x2
    -- = 0x00000000 | 0x400 | 0x0 | 0x8 | 0x4 | 0x2 = 0x40E
    t15 <- testBool "kernelCode PTE type bits" ((pte0 .&. 0x3) == 0x2)
    t16 <- testBool "kernelCode PTE base addr" ((pte0 .&. 0xFFF00000) == 0x00000000)

    -- Map device region and read back (VA=0x20000000 >> 20 = 0x200)
    VM.mapRegion pt VM.deviceRegion
    pteDevice <- peek32 (pt + 0x200 * 4)
    t17 <- testBool "device PTE type bits" ((pteDevice .&. 0x3) == 0x2)
    t18 <- testBool "device PTE base addr" ((pteDevice .&. 0xFFF00000) == 0x20000000)
    -- Device is Uncached: C=0, B=0
    t19 <- testBool "device PTE uncached" ((pteDevice .&. 0xC) == 0x0)

    UART.putStrLn ""

    -- ===== Full MMU cycle =====
    UART.putStrLn "--- MMU Enable/Disable Cycle ---"

    -- Create fresh page table for the full test
    pt2 <- VM.createPageTable

    -- Identity map everything needed
    VM.mapRegion pt2 VM.kernelCodeRegion
    VM.mapRegion pt2 VM.kernelHeapRegion
    VM.mapRegion pt2 VM.deviceRegion

    -- Stack regions (same as Shell.hs doVmTest)
    let stackRegion = VM.MemRegion
          { VM.mrVA    = 0x07000000
          , VM.mrPA    = 0x07000000
          , VM.mrSize  = VM.sectionSize * 16
          , VM.mrPerm  = VM.APFullAccess
          , VM.mrDom   = 0
          , VM.mrCache = VM.WriteBack
          }
    VM.mapRegion pt2 stackRegion

    let irqStackRegion = VM.MemRegion
          { VM.mrVA    = 0x08000000
          , VM.mrPA    = 0x08000000
          , VM.mrSize  = VM.sectionSize * 16
          , VM.mrPerm  = VM.APFullAccess
          , VM.mrDom   = 0
          , VM.mrCache = VM.WriteBack
          }
    VM.mapRegion pt2 irqStackRegion

    -- Set all domains to manager
    mapM_ (`VM.setDomainAccess` VM.DomainManager) [0..15]

    -- Enable MMU
    VM.mmuEnable pt2

    -- If we get here, identity mapping works
    t20 <- testBool "MMU enabled, survived" True

    -- Verify GPIO works under MMU
    val <- GPIO.rawRead 27
    t21 <- testBool "GPIO read under MMU" True  -- didn't crash

    -- Verify timer works under MMU
    us <- Timer.getTimeUs
    t22 <- testBool "timer read under MMU" (us > 0)

    -- Disable MMU
    VM.mmuDisable
    t23 <- testBool "MMU disabled, survived" True

    UART.putStrLn ""

    -- ===== Summary =====
    let results = [t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,
                   t11,t12,t13,t14,t15,t16,t17,t18,t19,
                   t20,t21,t22,t23]
    let passed = length (filter id results)
    let total = length results

    UART.putStrLn "==========================="
    UART.putStr "VM tests: "
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

testBool :: String -> Bool -> IO Bool
testBool name ok = do
    UART.putStr "  "
    UART.putStr name
    UART.putStr ": "
    if ok
      then UART.putStrLn "ok"
      else UART.putStrLn "FAIL"
    return ok
