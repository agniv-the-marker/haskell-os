-- | FAT32.hs - FAT32 filesystem
--
-- based on lab 16, but in haskell:
--   mbr partition table parsing
--   bios param parsing
--   fat chain following/modification
--   directory entry parsing/creation
--   file read/write/create/delete/rename

module FAT32
  ( -- * Types
    FAT32FS(..)
  , DirEntry(..)
  , Partition(..)
  , BPB(..)
    -- * Mounting
  , mountFS
    -- * Directory operations
  , listRoot, listDir, findEntry
    -- * File read operations
  , readFileBytes
    -- * File write operations
  , createFile, writeFile, deleteFile, renameFile
    -- * Debug
  , printFSInfo, printDirEntry
  ) where

import Prelude hiding (readFile, writeFile)
import Data.Word
import Data.Bits
import Data.Char (chr, toUpper, ord, isDigit, isAsciiUpper)
import Control.Monad (when, unless, void, zipWithM_)
import Data.Maybe (isJust)
import Alloc
import qualified UART

foreign import ccall "pi_sd_init" c_sd_init :: IO Word32
foreign import ccall "pi_sd_read" c_sd_read :: Ptr -> Word32 -> Word32 -> IO Word32
foreign import ccall "pi_sd_write" c_sd_write :: Ptr -> Word32 -> Word32 -> IO Word32

sectorSize :: Word32
sectorSize = 512

-- | Lightweight MaybeT for IO. Flattens nested case-on-Maybe inside IO.
newtype MaybeIO a = MaybeIO { runMaybeIO :: IO (Maybe a) }

instance Functor MaybeIO where
    fmap f (MaybeIO m) = MaybeIO (fmap (fmap f) m)

instance Applicative MaybeIO where
    pure a = MaybeIO (return (Just a))
    MaybeIO mf <*> MaybeIO ma = MaybeIO $ do
        f' <- mf
        case f' of
            Nothing -> return Nothing
            Just f  -> fmap (fmap f) ma

instance Monad MaybeIO where
    return = pure
    MaybeIO m >>= f = MaybeIO $ do
        a <- m
        case a of
            Nothing -> return Nothing
            Just x  -> runMaybeIO (f x)

liftIO :: IO a -> MaybeIO a
liftIO act = MaybeIO (fmap Just act)

errWhen :: Bool -> String -> MaybeIO ()
errWhen True  msg = MaybeIO (UART.putStrLn msg >> return Nothing)
errWhen False _   = pure ()

errOnNothing :: String -> Maybe a -> MaybeIO a
errOnNothing msg Nothing  = MaybeIO (UART.putStrLn msg >> return Nothing)
errOnNothing _   (Just a) = pure a

errOnNothingIO :: String -> IO (Maybe a) -> MaybeIO a
errOnNothingIO msg act = MaybeIO $ do
    ma <- act
    case ma of
        Nothing -> UART.putStrLn msg >> return Nothing
        Just a  -> return (Just a)

-- types

-- | MBR partition entry
data Partition = Partition
  { partType     :: !Word8
  , partLbaStart :: !Word32
  , partSectors  :: !Word32
  } deriving (Show)

-- | BIOS Parameter Block
data BPB = BPB
  { bpbBytesPerSec    :: !Word32
  , bpbSecPerCluster  :: !Word32
  , bpbReservedSecs   :: !Word32
  , bpbNumFATs        :: !Word32
  , bpbTotalSecs32    :: !Word32
  , bpbFATSize32      :: !Word32
  , bpbRootCluster    :: !Word32
  } deriving (Show)

-- | FAT32 filesystem handle
data FAT32FS = FAT32FS
  { fsPartition       :: !Partition
  , fsBPB             :: !BPB
  , fsFatBeginLBA     :: !Word32   -- ^ LBA of first FAT sector
  , fsClusterBeginLBA :: !Word32   -- ^ LBA of first data cluster
  , fsSectorBuf       :: !Ptr      -- ^ Reusable sector buffer (reads)
  , fsWriteBuf        :: !Ptr      -- ^ Separate buffer for writes
  , fsNEntries        :: !Word32   -- ^ Total FAT entries
  } deriving (Show)

-- | Directory entry
data DirEntry = DirEntry
  { deName      :: !String
  , deCluster   :: !Word32   -- ^ First cluster number
  , deSize      :: !Word32   -- ^ File size in bytes
  , deIsDir     :: !Bool
  , deIsHidden  :: !Bool
  } deriving (Show)

-- | Read a single sector into buffer
readSector :: Ptr -> Word32 -> IO ()
readSector buf lba = do
    result <- c_sd_read buf lba 1
    when (result == 0) $ UART.putStrLn "WARNING: SD read failed"

-- | Write a single sector from buffer to disk
writeSector :: Ptr -> Word32 -> IO ()
writeSector buf lba = do
    result <- c_sd_write buf lba 1
    when (result == 0) $ UART.putStrLn "WARNING: SD write failed"

-- | Read a 16-bit LE value from buffer at offset
readU16 :: Ptr -> Word32 -> IO Word32
readU16 buf off = do
    b0 <- peek8 buf off
    b1 <- peek8 buf (off + 1)
    return (fromIntegral b0 .|. (fromIntegral b1 `shiftL` 8))

-- | Read a 32-bit LE value from buffer at offset
readU32 :: Ptr -> Word32 -> IO Word32
readU32 buf off = do
    b0 <- peek8 buf off
    b1 <- peek8 buf (off + 1)
    b2 <- peek8 buf (off + 2)
    b3 <- peek8 buf (off + 3)
    return (fromIntegral b0
        .|. (fromIntegral b1 `shiftL` 8)
        .|. (fromIntegral b2 `shiftL` 16)
        .|. (fromIntegral b3 `shiftL` 24))

-- | Write a 16-bit LE value at offset in buffer
writeU16 :: Ptr -> Word32 -> Word32 -> IO ()
writeU16 buf off val = do
    poke8 buf off       (fromIntegral (val .&. 0xFF))
    poke8 buf (off + 1) (fromIntegral ((val `shiftR` 8) .&. 0xFF))

-- | Write a 32-bit LE value at offset in buffer
writeU32 :: Ptr -> Word32 -> Word32 -> IO ()
writeU32 buf off = poke32 (buf + off)

-- | Zero a buffer
zeroBuffer :: Ptr -> Word32 -> IO ()
zeroBuffer _   0 = return ()
zeroBuffer buf n = mapM_ (\off -> poke32 (buf + off) 0) [0, 4 .. n - 1]

-- | Copy n bytes from src to dest buffer
copyBytes :: Ptr -> Ptr -> Word32 -> IO ()
copyBytes _    _   0 = return ()
copyBytes dest src n = mapM_ (\off -> peek8 src off >>= poke8 dest off) [0 .. n - 1]

-- parse mbr 

-- | Parse first partition from MBR
parseMBR :: Ptr -> IO Partition
parseMBR buf = do
    sig <- readU16 buf 510
    if sig /= 0xAA55
      then do
        UART.putStrLn "ERROR: Invalid MBR signature"
        return (Partition 0 0 0)
      else do
        let pOff = 446
        pType <- peek8 buf (pOff + 4)
        lbaStart <- readU32 buf (pOff + 8)
        nSectors <- readU32 buf (pOff + 12)
        return (Partition pType lbaStart nSectors)

-- BPB parsing

-- | Parse BPB from boot sector, wildly inefficient
parseBPB :: Ptr -> IO BPB
parseBPB buf = do
    bytesPerSec  <- readU16 buf 11
    secPerClus   <- peek8  buf 13
    reservedSecs <- readU16 buf 14
    numFATs      <- peek8  buf 16
    totalSecs32  <- readU32 buf 32
    fatSize32    <- readU32 buf 36
    rootCluster  <- readU32 buf 44
    return BPB
      { bpbBytesPerSec   = bytesPerSec
      , bpbSecPerCluster = fromIntegral secPerClus
      , bpbReservedSecs  = reservedSecs
      , bpbNumFATs       = fromIntegral numFATs
      , bpbTotalSecs32   = totalSecs32
      , bpbFATSize32     = fatSize32
      , bpbRootCluster   = rootCluster
      }

-- mounting

-- | Initialize SD card and mount FAT32 filesystem
mountFS :: IO (Maybe FAT32FS)
mountFS = do
    UART.putStrLn "Initializing SD card..."
    result <- c_sd_init
    if result == 0
      then do
        UART.putStrLn "ERROR: SD card init failed"
        return Nothing
      else do
        buf <- alloc sectorSize
        wbuf <- alloc sectorSize

        -- Read MBR (sector 0)
        readSector buf 0
        part <- parseMBR buf

        -- Read boot sector of partition
        readSector buf (partLbaStart part)
        bpb <- parseBPB buf

        -- Calculate LBAs
        let fatBegin = partLbaStart part + bpbReservedSecs bpb
        let clusterBegin = fatBegin + bpbNumFATs bpb * bpbFATSize32 bpb
        let nEntries = bpbFATSize32 bpb * (sectorSize `div` 4)

        let fs = FAT32FS
              { fsPartition       = part
              , fsBPB             = bpb
              , fsFatBeginLBA     = fatBegin
              , fsClusterBeginLBA = clusterBegin
              , fsSectorBuf       = buf
              , fsWriteBuf        = wbuf
              , fsNEntries        = nEntries
              }

        UART.putStrLn "FAT32 mounted successfully"
        return (Just fs)

-- | Convert cluster number to LBA
clusterToLBA :: FAT32FS -> Word32 -> Word32
clusterToLBA fs cluster =
    fsClusterBeginLBA fs + (cluster - 2) * bpbSecPerCluster (fsBPB fs)

-- | Read FAT entry for a cluster
readFATEntry :: FAT32FS -> Word32 -> IO Word32
readFATEntry fs cluster = do
    let fatOffset   = cluster * 4
    let fatSector   = fsFatBeginLBA fs + (fatOffset `div` sectorSize)
    let entryOffset = fatOffset `mod` sectorSize

    readSector (fsSectorBuf fs) fatSector
    entry <- readU32 (fsSectorBuf fs) entryOffset
    return (entry .&. 0x0FFFFFFF)

-- | Write a FAT entry for a cluster, updates all FAT copies
writeFATEntry :: FAT32FS -> Word32 -> Word32 -> IO ()
writeFATEntry fs cluster value = do
    let fatOffset   = cluster * 4
    let sectorIdx   = fatOffset `div` sectorSize
    let entryOffset = fatOffset `mod` sectorSize
    let wbuf = fsWriteBuf fs
    let nFATs = bpbNumFATs (fsBPB fs)
    mapM_ (\i -> do
        let fatLBA = fsFatBeginLBA fs + i * bpbFATSize32 (fsBPB fs) + sectorIdx
        readSector wbuf fatLBA
        old <- readU32 wbuf entryOffset
        let preserved = old .&. 0xF0000000
        let newVal = preserved .|. (value .&. 0x0FFFFFFF)
        writeU32 wbuf entryOffset newVal
        writeSector wbuf fatLBA
      ) [0 .. nFATs - 1]

-- | cluster number in range
isValidCluster :: Word32 -> Bool
isValidCluster c = c >= 2 && c < 0x0FFFFFF8

-- | Follow an entire FAT chain from a starting cluster
followChain :: FAT32FS -> Word32 -> IO [Word32]
followChain fs startCluster = go startCluster []
  where
    go cluster acc
      | not (isValidCluster cluster) = return (reverse acc)
      | otherwise = do
          next <- readFATEntry fs cluster
          go next (cluster : acc)

-- | Find the first free cluster starting from a given cluster number
findFreeCluster :: FAT32FS -> Word32 -> IO (Maybe Word32)
findFreeCluster fs startFrom = go (max 3 startFrom)
  where
    maxCluster = fsNEntries fs
    go c
      | c >= maxCluster = return Nothing
      | otherwise = do
          entry <- readFATEntry fs c
          if entry == 0
            then return (Just c)
            else go (c + 1)

-- | Free all clusters in a FAT chain
freeChain :: FAT32FS -> Word32 -> IO ()
freeChain fs = go
  where
    go cluster
      | not (isValidCluster cluster) = return ()
      | otherwise = do
          next <- readFATEntry fs cluster
          writeFATEntry fs cluster 0
          go next

-- directory parsing 

-- | Parse an 8.3 short filename from a directory entry
parseSFN :: Ptr -> Word32 -> IO String
parseSFN buf off = do
    name <- mapM readChar [0..7]
    ext  <- mapM readChar [8..10]
    let trimmedName = trimSpaces name
    let trimmedExt  = trimSpaces ext
    if null trimmedExt
      then return trimmedName
      else return (trimmedName ++ "." ++ trimmedExt)
  where
    readChar i = do b <- peek8 buf (off + i); return (chr (fromIntegral b))
    trimSpaces = reverse . dropWhile (== ' ') . reverse

-- | Parse a single directory entry (32 bytes)
parseDirEntry :: Ptr -> Word32 -> IO (Maybe DirEntry)
parseDirEntry buf off = do
    firstByte <- peek8 buf off
    case firstByte of
        0x00 -> return Nothing   -- end of directory
        0xE5 -> return Nothing   -- deleted entry
        _    -> do
            attr <- peek8 buf (off + 11)
            if attr == 0x0F
              then return Nothing  -- LFN entry
              else do
                name <- parseSFN buf off
                clusterHi <- readU16 buf (off + 20)
                clusterLo <- readU16 buf (off + 26)
                size      <- readU32 buf (off + 28)
                let cluster = (clusterHi `shiftL` 16) .|. clusterLo
                let isDir   = (fromIntegral attr :: Word32) .&. 0x10 /= 0
                let isHidden = (fromIntegral attr :: Word32) .&. 0x02 /= 0
                return (Just (DirEntry name cluster size isDir isHidden))

-- 8.3 filename formatting

-- | Format a string as an 8.3 FAT32 short filename
-- | (11 bytes, space-padded, uppercase)
formatSFN :: String -> Maybe [Word8]
formatSFN name =
    let upper = map toUpper name
        (base, rest) = break (== '.') upper
        ext = case rest of
                []    -> ""
                (_:e) -> e
    in if null base || length base > 8 || length ext > 3
         || not (all isValidSFNChar base)
         || not (all isValidSFNChar ext)
       then Nothing
       else Just (padRight 8 base ++ padRight 3 ext)
  where
    padRight n s = map charToByte (take n (s ++ repeat ' '))
    charToByte c = fromIntegral (ord c)
    isValidSFNChar c = isAsciiUpper c
                    || isDigit c
                    || c `elem` " !#$%&'()-@^_`{}~"

-- | List entries in a directory at the given cluster
listDir :: FAT32FS -> Word32 -> IO [DirEntry]
listDir fs dirCluster = do
    clusters <- followChain fs dirCluster
    entries <- mapM readClusterEntries clusters
    return (concat entries)
  where
    readClusterEntries cluster = do
        let lba = clusterToLBA fs cluster
        let secsPerClus = bpbSecPerCluster (fsBPB fs)
        sectorEntries <- mapM (readSectorEntries lba) [0..secsPerClus-1]
        return (concat sectorEntries)

    readSectorEntries baseLba secIdx = do
        readSector (fsSectorBuf fs) (baseLba + secIdx)
        parseEntries (fsSectorBuf fs) 0 []

    parseEntries buf off acc
      | off >= sectorSize = return (reverse acc)
      | otherwise = do
          mEntry <- parseDirEntry buf off
          case mEntry of
            Nothing -> parseEntries buf (off + 32) acc
            Just entry -> parseEntries buf (off + 32) (entry : acc)

-- | List root directory
listRoot :: FAT32FS -> IO [DirEntry]
listRoot fs = listDir fs (bpbRootCluster (fsBPB fs))

-- | Find an entry by name in a directory
findEntry :: FAT32FS -> Word32 -> String -> IO (Maybe DirEntry)
findEntry fs dirCluster name = do
    entries <- listDir fs dirCluster
    return (findByName entries)
  where
    findByName [] = Nothing
    findByName (e:es)
      | map toUpper (deName e) == map toUpper name = Just e
      | otherwise = findByName es

-- | Search a list, returning the first Just result (early return)
firstJustM :: [a] -> (a -> IO (Maybe b)) -> IO (Maybe b)
firstJustM []     _ = return Nothing
firstJustM (x:xs) f = do
    result <- f x
    case result of
      Just r  -> return (Just r)
      Nothing -> firstJustM xs f

-- | Find a directory entry by name, returning its physical location
-- | haskell equivlanet of find_dirent_with_name in c/fat32.c
findDirEntrySlot :: FAT32FS -> Word32 -> String -> IO (Maybe (Word32, Word32, DirEntry))
findDirEntrySlot fs dirCluster targetName = do
    clusters <- followChain fs dirCluster -- follow the cluster chain
    firstJustM clusters searchCluster     -- iterate over every cluster
  where
    secsPerClus = bpbSecPerCluster (fsBPB fs)
    upperTarget = map toUpper targetName
    buf = fsSectorBuf fs

    searchCluster c = do
        let baseLBA = clusterToLBA fs c
        firstJustM [0 .. secsPerClus - 1] $ \secIdx -> do
            let lba = baseLBA + secIdx
            readSector buf lba
            scanEntries lba 0

    scanEntries _ off | off >= sectorSize = return Nothing
    scanEntries lba off = do
        firstByte <- peek8 buf off
        case firstByte of
          0x00 -> return Nothing
          0xE5 -> scanEntries lba (off + 32)
          _    -> do
            attr <- peek8 buf (off + 11)
            if attr == 0x0F
              then scanEntries lba (off + 32)
              else do
                name <- parseSFN buf off
                if map toUpper name == upperTarget
                  then do
                    mEntry <- parseDirEntry buf off
                    case mEntry of
                      Just entry -> return (Just (lba, off, entry))
                      Nothing    -> scanEntries lba (off + 32)
                  else scanEntries lba (off + 32)

-- | Find a free directory entry slot (first byte 0x00 or 0xE5)
findFreeDirSlot :: FAT32FS -> Word32 -> IO (Maybe (Word32, Word32))
findFreeDirSlot fs dirCluster = do
    clusters <- followChain fs dirCluster
    firstJustM clusters searchCluster
  where
    secsPerClus = bpbSecPerCluster (fsBPB fs)
    buf = fsSectorBuf fs

    searchCluster c = do
        let baseLBA = clusterToLBA fs c
        firstJustM [0 .. secsPerClus - 1] $ \secIdx -> do
            let lba = baseLBA + secIdx
            readSector buf lba
            scanSlots lba 0

    scanSlots _ off | off >= sectorSize = return Nothing
    scanSlots lba off = do
        firstByte <- peek8 buf off
        if firstByte == 0x00 || firstByte == 0xE5
          then return (Just (lba, off))
          else scanSlots lba (off + 32)

-- | Write an 8.3 directory entry at offset in buffer
writeDirEntryRaw :: Ptr -> Word32 -> [Word8] -> Word8 -> Word32 -> Word32 -> IO ()
writeDirEntryRaw buf off sfnBytes attr cluster size = do
    -- Write 11-byte filename
    zipWithM_ (\i b -> poke8 buf (off + i) b) [0..] sfnBytes
    -- Attribute byte
    poke8 buf (off + 11) attr
    -- NT reserved + creation time fields (offsets 12-19) = 0
    writeU32 buf (off + 12) 0
    writeU32 buf (off + 16) 0
    -- Cluster high (offset 20-21)
    writeU16 buf (off + 20) ((cluster `shiftR` 16) .&. 0xFFFF)
    -- Last modified time/date (offsets 22-25) = 0
    writeU16 buf (off + 22) 0
    writeU16 buf (off + 24) 0
    -- Cluster low (offset 26-27)
    writeU16 buf (off + 26) (cluster .&. 0xFFFF)
    -- File size (offset 28-31)
    writeU32 buf (off + 28) size

-- | Read an entire file into a freshly allocated buffer
readFile :: FAT32FS -> DirEntry -> IO (Ptr, Word32)
readFile fs entry = do
    let size = deSize entry
    buf <- alloc size
    readFileInto fs entry buf
    return (buf, size)

-- | Read a file into a pre-allocated buffer
readFileInto :: FAT32FS -> DirEntry -> Ptr -> IO ()
readFileInto fs entry destBuf = do
    clusters <- followChain fs (deCluster entry)
    let bytesPerCluster = bpbSecPerCluster (fsBPB fs) * sectorSize
    readClusters clusters destBuf (deSize entry) bytesPerCluster
  where
    readClusters [] _ _ _ = return ()
    readClusters _ _ 0 _ = return ()
    readClusters (c:cs) dest remaining bpc = do
        let toRead = min remaining bpc
        readClusterData c dest toRead
        readClusters cs (dest + toRead) (remaining - toRead) bpc

    readClusterData cluster dest nBytes = do
        let lba = clusterToLBA fs cluster
        let nSecs = (nBytes + sectorSize - 1) `div` sectorSize
        _ <- c_sd_read dest lba nSecs
        return ()

-- | Read file as list of bytes (convenience, but slow for large files)
readFileBytes :: FAT32FS -> DirEntry -> IO [Word8]
readFileBytes fs entry = do
    (buf, size) <- readFile fs entry
    if size == 0
      then return []
      else mapM (peek8 buf) [0 .. size - 1]

-- | Write data to a single cluster (zero-pads partial last sector)
writeClusterData :: FAT32FS -> Word32 -> Ptr -> Word32 -> IO ()
writeClusterData fs cluster dataPtr nBytes = do
    let lba = clusterToLBA fs cluster
    let fullSecs = nBytes `div` sectorSize
    let remainder = nBytes `mod` sectorSize
    -- Write full sectors directly
    when (fullSecs > 0) $ void (c_sd_write dataPtr lba fullSecs)
    -- Handle partial last sector with zero-padding
    when (remainder /= 0) $ do
        let wbuf = fsWriteBuf fs
        zeroBuffer wbuf sectorSize
        copyBytes wbuf (dataPtr + fullSecs * sectorSize) remainder
        writeSector wbuf (lba + fullSecs)

-- | Write data across a cluster chain, allocating/freeing as needed
writeDataChain :: FAT32FS -> Word32 -> Ptr -> Word32 -> Word32 -> IO ()
writeDataChain fs startCluster dataPtr dataSize bytesPerCluster =
    go startCluster dataPtr dataSize 0
  where
    go cluster dPtr remaining prevCluster
      | remaining == 0 = cleanupTail cluster prevCluster
      | otherwise = do
          let toWrite = min remaining bytesPerCluster
          writeClusterData fs cluster dPtr toWrite
          let left = remaining - toWrite
          nextEntry <- readFATEntry fs cluster
          if left == 0
            then finalizeCluster cluster nextEntry
            else advanceChain cluster nextEntry (dPtr + toWrite) left

    -- All data written, free leftover chain, mark previous cluster as EOC
    cleanupTail cluster prevCluster = do
        when (isValidCluster cluster) (freeChain fs cluster)
        when (prevCluster /= 0) (writeFATEntry fs prevCluster 0x0FFFFFFF)

    -- Last chunk written to this cluster, mark it EOC and free remainder
    finalizeCluster cluster nextEntry = do
        writeFATEntry fs cluster 0x0FFFFFFF
        when (isValidCluster nextEntry) (freeChain fs nextEntry)

    -- More data remains, follow existing chain or allocate new cluster
    advanceChain cluster nextEntry dPtr remaining
      | isValidCluster nextEntry = go nextEntry dPtr remaining cluster
      | otherwise = do
          mc <- findFreeCluster fs 3
          case mc of
            Nothing -> UART.putStrLn "ERROR: Disk full during write"
            Just newC -> do
              writeFATEntry fs cluster newC
              writeFATEntry fs newC 0x0FFFFFFF
              go newC dPtr remaining cluster

-- | Create a new empty file in the directory
createFile :: FAT32FS -> Word32 -> String -> IO (Maybe DirEntry)
createFile fs dirCluster name = runMaybeIO $ do
    sfnBytes <- errOnNothing "ERROR: Invalid 8.3 filename" (formatSFN name)
    existing <- liftIO (findEntry fs dirCluster name)
    errWhen (isJust existing) "ERROR: File already exists"
    (slotLBA, slotOffset) <- errOnNothingIO "ERROR: No free directory entry"
                                 (findFreeDirSlot fs dirCluster)
    liftIO $ do
        readSector (fsWriteBuf fs) slotLBA
        writeDirEntryRaw (fsWriteBuf fs) slotOffset sfnBytes 0x20 0 0
        writeSector (fsWriteBuf fs) slotLBA
    return (DirEntry (map toUpper name) 0 0 False False)

-- | Write data to an existing file
writeFile :: FAT32FS -> Word32 -> String -> Ptr -> Word32 -> IO Bool
writeFile fs dirCluster name dataPtr dataSize = do
    mSlot <- findDirEntrySlot fs dirCluster name
    case mSlot of
      Nothing -> do
        UART.putStrLn "ERROR: File not found"
        return False
      Just (slotLBA, slotOffset, entry) -> do
        let oldCluster = deCluster entry
        let bytesPerCluster = bpbSecPerCluster (fsBPB fs) * sectorSize

        newStartCluster <- if dataSize == 0
          then do
            when (isValidCluster oldCluster) $ freeChain fs oldCluster
            return 0
          else do
            startCluster <- if isValidCluster oldCluster
              then return oldCluster
              else do
                mc <- findFreeCluster fs 3
                case mc of
                  Nothing -> do
                    UART.putStrLn "ERROR: Disk full"
                    return 0
                  Just c -> do
                    writeFATEntry fs c 0x0FFFFFFF
                    return c
            if startCluster == 0
              then return 0
              else do
                writeDataChain fs startCluster dataPtr dataSize bytesPerCluster
                return startCluster

        -- Update directory entry
        let wbuf = fsWriteBuf fs
        readSector wbuf slotLBA
        writeU16 wbuf (slotOffset + 20) ((newStartCluster `shiftR` 16) .&. 0xFFFF)
        writeU16 wbuf (slotOffset + 26) (newStartCluster .&. 0xFFFF)
        writeU32 wbuf (slotOffset + 28) dataSize
        writeSector wbuf slotLBA
        return True

-- | Delete a file by name
deleteFile :: FAT32FS -> Word32 -> String -> IO Bool
deleteFile fs dirCluster name = do
    mSlot <- findDirEntrySlot fs dirCluster name
    case mSlot of
      Nothing -> do
        UART.putStrLn "ERROR: File not found"
        return False
      Just (slotLBA, slotOffset, entry) -> do
        -- Free the cluster chain
        when (isValidCluster (deCluster entry)) (freeChain fs (deCluster entry))
        -- Mark dirent as deleted
        let wbuf = fsWriteBuf fs
        readSector wbuf slotLBA
        poke8 wbuf slotOffset 0xE5
        writeSector wbuf slotLBA
        return True

-- | Rename a file
renameFile :: FAT32FS -> Word32 -> String -> String -> IO Bool
renameFile fs dirCluster oldName newName =
    do  result <- runMaybeIO $ do
            sfnBytes <- errOnNothing "ERROR: Invalid 8.3 filename" (formatSFN newName)
            existing <- liftIO (findEntry fs dirCluster newName)
            errWhen (isJust existing) "ERROR: Target filename already exists"
            (slotLBA, slotOffset, _) <- errOnNothingIO "ERROR: File not found"
                                            (findDirEntrySlot fs dirCluster oldName)
            liftIO $ do
                readSector (fsWriteBuf fs) slotLBA
                zipWithM_ (\i b -> poke8 (fsWriteBuf fs) (slotOffset + i) b) [0..] sfnBytes
                writeSector (fsWriteBuf fs) slotLBA
        return (isJust result)

-- | Print filesystem info
printFSInfo :: FAT32FS -> IO ()
printFSInfo fs = do
    UART.putStr "Bytes/sector:     "
    UART.putUint (bpbBytesPerSec (fsBPB fs))
    UART.putChar '\n'
    UART.putStr "Sectors/cluster:  "
    UART.putUint (bpbSecPerCluster (fsBPB fs))
    UART.putChar '\n'
    UART.putStr "Root cluster:     "
    UART.putUint (bpbRootCluster (fsBPB fs))
    UART.putChar '\n'
    UART.putStr "FAT begin LBA:   "
    UART.putUint (fsFatBeginLBA fs)
    UART.putChar '\n'
    UART.putStr "Data begin LBA:  "
    UART.putUint (fsClusterBeginLBA fs)
    UART.putChar '\n'

-- | Print a directory entry
printDirEntry :: DirEntry -> IO ()
printDirEntry entry = do
    if deIsDir entry
      then UART.putStr "[DIR]  "
      else UART.putStr "[FILE] "
    UART.putStr (deName entry)
    unless (deIsDir entry) $ do
        UART.putStr "  ("
        UART.putUint (deSize entry)
        UART.putStr " bytes)"
    UART.putChar '\n'
