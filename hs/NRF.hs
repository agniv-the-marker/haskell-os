{- HLINT ignore "Use camelCase" -}
-- | NRF.hs - lab 14, nrf-driver.c/nrf-hw-support.c

module NRF
  ( -- * Configuration types
    NrfConfig(..), DataRate(..), PowerLevel(..), NrfState(..)
    -- * Default configurations
  , defaultConfig, serverConfig, clientConfig
    -- * NRF handle
  , NrfHandle(..)
    -- * Core operations
  , nrfInit, nrfSend, nrfSendNoAck, nrfRecv
    -- * Statistics
  , NrfStats(..), nrfStats
    -- * Low-level register access (exported for tests)
  , nrfGet8, nrfPut8
  ) where

import Data.Word
import Data.Bits ((.&.), (.|.), shiftL, shiftR, complement)
import Control.Monad (when, unless, void)
import Control.Concurrent (yield)
import Control.Concurrent.MVar
import Data.IORef
import Data.Maybe (listToMaybe)
import qualified SPI
import qualified GPIO
import qualified Timer
import qualified UART
import Hal (devBarrier)

-- | Data rate setting (NRF RF_SETUP register encoding)
-- C version uses raw values 0x08 (2Mbps), 0x00 (1Mbps), 0x20 (250Kbps)
data DataRate = NRF1Mbps | NRF2Mbps | NRF250Kbps
  deriving (Eq, Show)

dataRateToWord :: DataRate -> Word8
dataRateToWord NRF1Mbps   = 0x00         -- RF_DR_HI=0, RF_DR_LO=0
dataRateToWord NRF2Mbps   = 0x08         -- RF_DR_HI=1 (bit 3)
dataRateToWord NRF250Kbps = 0x20         -- RF_DR_LO=1 (bit 5)

-- | Transmit power level (NRF RF_SETUP register encoding)
-- C version uses raw values shifted by 1 bit
data PowerLevel = DBmMinus18 | DBmMinus12 | DBmMinus6 | DBm0
  deriving (Eq, Show)

powerToWord :: PowerLevel -> Word8
powerToWord DBmMinus18 = 0x00            -- 0b00 << 1
powerToWord DBmMinus12 = 0x02            -- 0b01 << 1
powerToWord DBmMinus6  = 0x04            -- 0b10 << 1
powerToWord DBm0       = 0x06            -- 0b11 << 1

-- | NRF operational state
data NrfState = PowerDown | StandbyI | RxMode | TxMode
  deriving (Eq, Show)

-- | NRF configuration record
data NrfConfig = NrfConfig
  { nrfChannel       :: Word8      -- ^ RF channel 0-125 (default: 113)
  , nrfDataRate      :: DataRate   -- ^ Air data rate
  , nrfPower         :: PowerLevel -- ^ TX power
  , nrfPayloadSize   :: Word8      -- ^ Bytes per packet, 1-32 (default: 4)
  , nrfCePin         :: Word32     -- ^ CE GPIO pin
  , nrfSpiChip       :: Word32     -- ^ SPI chip select (0 or 1)
  , nrfRxAddr        :: Word32     -- ^ 3-byte receive address
  , nrfTxAddr        :: Word32     -- ^ 3-byte transmit address
  , nrfAcked         :: Bool       -- ^ Use hardware auto-ACK
  , nrfRetranAttempts :: Word8     -- ^ Auto-retransmit count (0-15)
  , nrfRetranDelay   :: Word16     -- ^ Retransmit delay in usec
  , nrfAddrBytes     :: Word8      -- ^ Address width: 3, 4, or 5
  } deriving (Show)

-- | Default configuration from nrf-default-values.h
defaultConfig :: NrfConfig
defaultConfig = NrfConfig
  { nrfChannel       = 113         -- Semi-safe from interference
  , nrfDataRate      = NRF2Mbps    -- Fastest
  , nrfPower         = DBm0        -- Full power (0dBm)
  , nrfPayloadSize   = 4           -- 4-byte packets
  , nrfCePin         = 6           -- Default: left NRF CE pin
  , nrfSpiChip       = 0           -- Default: left NRF SPI chip
  , nrfRxAddr        = 0xd5d5d5    -- Server address
  , nrfTxAddr        = 0xe5e5e5    -- Client address
  , nrfAcked         = True        -- Hardware ACK enabled
  , nrfRetranAttempts = 4          -- 4 retransmit attempts
  , nrfRetranDelay   = 1000        -- 1000us retransmit delay
  , nrfAddrBytes     = 3           -- 3-byte addresses
  }

-- | Server (left NRF) configuration from nrf-test.h
serverConfig :: NrfConfig
serverConfig = defaultConfig
  { nrfCePin   = 6
  , nrfSpiChip = 0
  , nrfRxAddr  = 0xd5d5d5
  , nrfTxAddr  = 0xe5e5e5
  }

-- | Client (right NRF) configuration from nrf-test.h
clientConfig :: NrfConfig
clientConfig = defaultConfig
  { nrfCePin   = 5
  , nrfSpiChip = 1
  , nrfRxAddr  = 0xe5e5e5
  , nrfTxAddr  = 0xd5d5d5
  }

-- Register addresses (all 8-bit)
nrfCONFIG, nrfEN_AA, nrfEN_RXADDR, nrfSETUP_AW :: Word8
nrfSETUP_RETR, nrfRF_CH, nrfRF_SETUP, nrfSTATUS :: Word8
nrfOBSERVE_TX, nrfRPD :: Word8
nrfRX_ADDR_P0, nrfRX_ADDR_P1 :: Word8
nrfTX_ADDR :: Word8
nrfRX_PW_P0, nrfRX_PW_P1 :: Word8
nrfFIFO_STATUS :: Word8
nrfDYNPD, nrfFEATURE :: Word8

nrfCONFIG      = 0x00
nrfEN_AA       = 0x01
nrfEN_RXADDR   = 0x02
nrfSETUP_AW    = 0x03
nrfSETUP_RETR  = 0x04
nrfRF_CH       = 0x05
nrfRF_SETUP    = 0x06
nrfSTATUS      = 0x07
nrfOBSERVE_TX  = 0x08
nrfRPD         = 0x09
nrfRX_ADDR_P0  = 0x0A
nrfRX_ADDR_P1  = 0x0B
nrfTX_ADDR     = 0x10
nrfRX_PW_P0    = 0x11
nrfRX_PW_P1    = 0x12
nrfFIFO_STATUS = 0x17
nrfDYNPD       = 0x1C
nrfFEATURE     = 0x1D

-- SPI command encodings (from nrf-hw-support.h)
nrfWR_REG, nrfR_RX_PAYLOAD, nrfW_TX_PAYLOAD :: Word8
nrfW_TX_PAYLOAD_NOACK, nrfFLUSH_TX, nrfFLUSH_RX, nrfNOP :: Word8

nrfWR_REG              = 0x20
nrfR_RX_PAYLOAD        = 0x61
nrfW_TX_PAYLOAD        = 0xA0
nrfW_TX_PAYLOAD_NOACK  = 0xB0
nrfFLUSH_TX            = 0xE1
nrfFLUSH_RX            = 0xE2
nrfNOP                 = 0xFF

-- CONFIG register bits
pwrUpBit, primRxBit :: Int
pwrUpBit  = 1
primRxBit = 0

-- STATUS register bits
rxDrBit, txDsBit, maxRtBit :: Int
rxDrBit  = 6
txDsBit  = 5
maxRtBit = 4

-- Pre-computed CONFIG values (from nrf-driver.c)
enableCrc, crcTwoByte, pwrUp, maskInt :: Word8
enableCrc   = 0x08   -- bit 3
crcTwoByte  = 0x04   -- bit 2
pwrUp       = 0x02   -- bit 1
maskInt     = 0x70   -- bits 6:4 (mask all interrupts)

txConfigVal :: Word8
txConfigVal = enableCrc .|. crcTwoByte .|. pwrUp .|. maskInt

rxConfigVal :: Word8
rxConfigVal = txConfigVal .|. 0x01  -- PRIM_RX bit

-- Maximum packet size
nrfPktMax :: Int
nrfPktMax = 32

-- | Statistics tracked during NRF operation
data NrfStats = NrfStats
  { statsSent     :: Word32
  , statsRecv     :: Word32
  , statsRetrans  :: Word32
  , statsLost     :: Word32
  , statsSentBytes :: Word32
  , statsRecvBytes :: Word32
  } deriving (Show)

-- | Opaque NRF handle, wrapping config and mutable state.
-- nhState uses MVar, stats uses IORef since no blocking is needed
data NrfHandle = NrfHandle
  { nhConfig    :: NrfConfig
  , nhSpi       :: SPI.SpiHandle
  , nhState     :: MVar NrfState
  , nhSentMsgs  :: IORef Word32
  , nhRecvMsgs  :: IORef Word32
  , nhRetrans   :: IORef Word32
  , nhLost      :: IORef Word32
  , nhSentBytes :: IORef Word32
  , nhRecvBytes :: IORef Word32
  }

-- | Read 8-bit register value via SPI.
-- Sends register address, receives value on next byte.
nrfGet8 :: NrfHandle -> Word8 -> IO Word8
nrfGet8 nh reg = do
    SPI.spiSetChipSelect (nrfSpiChip (nhConfig nh))
    rx <- SPI.spiTransfer (nhSpi nh) [reg, nrfNOP]
    case rx of
      [_, v] -> return v
      _      -> return 0

-- | Write 8-bit value to register via SPI.
-- Returns status byte.
nrfPut8 :: NrfHandle -> Word8 -> Word8 -> IO Word8
nrfPut8 nh reg val = do
    SPI.spiSetChipSelect (nrfSpiChip (nhConfig nh))
    rx <- SPI.spiTransfer (nhSpi nh) [nrfWR_REG .|. reg, val]
    case rx of
      [s, _] -> return s
      _      -> return 0

-- | Write register and verify it reads back correctly.
nrfPut8Chk :: NrfHandle -> Word8 -> Word8 -> IO ()
nrfPut8Chk nh reg val = do
    void $ nrfPut8 nh reg val
    v <- nrfGet8 nh reg
    when (v /= val) $ do
        UART.putStr "NRF: put8_chk failed: reg="
        UART.putHex (fromIntegral reg)
        UART.putStr " expected="
        UART.putHex (fromIntegral val)
        UART.putStr " got="
        UART.putHex (fromIntegral v)
        UART.putChar '\n'

-- | Read multiple bytes from a register/command.
nrfGetN :: NrfHandle -> Word8 -> Int -> IO [Word8]
nrfGetN nh cmd nbytes = do
    SPI.spiSetChipSelect (nrfSpiChip (nhConfig nh))
    rx <- SPI.spiTransfer (nhSpi nh) (cmd : replicate nbytes nrfNOP)
    return (drop 1 rx)  -- first byte is status

-- | Write multiple bytes to a register/command.
nrfPutN :: NrfHandle -> Word8 -> [Word8] -> IO Word8
nrfPutN nh cmd bytes = do
    SPI.spiSetChipSelect (nrfSpiChip (nhConfig nh))
    rx <- SPI.spiTransfer (nhSpi nh) (cmd : bytes)
    case rx of
      (s:_) -> return s
      _     -> return 0

-- | Flush TX FIFO
nrfFlushTx :: NrfHandle -> IO ()
nrfFlushTx nh = do
    SPI.spiSetChipSelect (nrfSpiChip (nhConfig nh))
    void (SPI.spiTransfer (nhSpi nh) [nrfFLUSH_TX])

-- | Flush RX FIFO
nrfFlushRx :: NrfHandle -> IO ()
nrfFlushRx nh = do
    SPI.spiSetChipSelect (nrfSpiChip (nhConfig nh))
    void (SPI.spiTransfer (nhSpi nh) [nrfFLUSH_RX])

-- | Set multi-byte address on a register
nrfSetAddr :: NrfHandle -> Word8 -> Word32 -> IO ()
nrfSetAddr nh reg addr = do
    let nb = fromIntegral (nrfAddrBytes (nhConfig nh))
    let bytes = take nb (word32ToBytes addr)
    void (nrfPutN nh (nrfWR_REG .|. reg) bytes)

-- | Check if a specific bit is set in a register
nrfBitIsSet :: NrfHandle -> Word8 -> Int -> IO Bool
nrfBitIsSet nh reg bit = do
    v <- nrfGet8 nh reg
    return ((v .&. (1 `shiftL` bit)) /= 0)

-- | Check for TX_DS (transmit data sent) interrupt
nrfHasTxIntr :: NrfHandle -> IO Bool
nrfHasTxIntr nh = nrfBitIsSet nh nrfSTATUS txDsBit

-- | Check for MAX_RT (max retransmissions) interrupt
nrfHasMaxRtIntr :: NrfHandle -> IO Bool
nrfHasMaxRtIntr nh = nrfBitIsSet nh nrfSTATUS maxRtBit

-- | Check for RX_DR (data ready) interrupt
nrfHasRxIntr :: NrfHandle -> IO Bool
nrfHasRxIntr nh = nrfBitIsSet nh nrfSTATUS rxDrBit

-- | Clear TX interrupt (write 1 to clear)
nrfTxIntrClr :: NrfHandle -> IO ()
nrfTxIntrClr nh = void (nrfPut8 nh nrfSTATUS (1 `shiftL` txDsBit))

-- | Clear MAX_RT interrupt
nrfRtIntrClr :: NrfHandle -> IO ()
nrfRtIntrClr nh = void (nrfPut8 nh nrfSTATUS (1 `shiftL` maxRtBit))

-- | Clear RX interrupt
nrfRxIntrClr :: NrfHandle -> IO ()
nrfRxIntrClr nh = void (nrfPut8 nh nrfSTATUS (1 `shiftL` rxDrBit))

-- | Check if RX FIFO is empty
nrfRxFifoEmpty :: NrfHandle -> IO Bool
nrfRxFifoEmpty nh = nrfBitIsSet nh nrfFIFO_STATUS 0

-- | Check if TX FIFO is empty
nrfTxFifoEmpty :: NrfHandle -> IO Bool
nrfTxFifoEmpty nh = nrfBitIsSet nh nrfFIFO_STATUS 4

-- | Check if RX has packet (FIFO not empty)
nrfRxHasPacket :: NrfHandle -> IO Bool
nrfRxHasPacket nh = do
    empty <- nrfRxFifoEmpty nh
    return (not empty)

ceLo :: NrfHandle -> IO ()
ceLo nh = do
    devBarrier
    GPIO.rawWrite (nrfCePin (nhConfig nh)) 0
    devBarrier

ceHi :: NrfHandle -> IO ()
ceHi nh = do
    devBarrier
    GPIO.rawWrite (nrfCePin (nhConfig nh)) 1
    devBarrier

-- | Enter RX mode: StandbyI -> RX
-- Invariant: always in RX except when briefly in TX to send.
nrfRxMode :: NrfHandle -> IO ()
nrfRxMode nh = do
    ceLo nh
    void $ nrfPut8 nh nrfCONFIG rxConfigVal
    ceHi nh
    Timer.delayUs 130
    void $ swapMVar (nhState nh) RxMode

-- | Enter TX mode: RX -> StandbyI -> TX
-- TX FIFO must be loaded before calling this.
nrfTxMode :: NrfHandle -> IO ()
nrfTxMode nh = do
    ceLo nh
    void $ nrfPut8 nh nrfCONFIG txConfigVal
    ceHi nh
    void $ swapMVar (nhState nh) TxMode

-- | Initialize an NRF24L01+ radio.
-- Follows the exact register sequence from nrf-driver.c nrf_init().
nrfInit :: NrfConfig -> IO NrfHandle
nrfInit cfg = do
    -- Delay for power-on (p20: 100ms for device to come online)
    Timer.delayMs 100

    -- Initialize SPI and CE pin
    spi <- SPI.spiInit (nrfSpiChip cfg) 26
    GPIO.rawSetOutput (nrfCePin cfg)
    GPIO.rawSetInput (nrfCePin cfg)
    GPIO.rawSetOutput (nrfCePin cfg)
    GPIO.rawWrite (nrfCePin cfg) 0
    Timer.delayMs 100

    -- Create handle with initial state
    stVar  <- newMVar PowerDown
    sent   <- newIORef 0
    recv   <- newIORef 0
    retran <- newIORef 0
    lost   <- newIORef 0
    sentB  <- newIORef 0
    recvB  <- newIORef 0

    let nh = NrfHandle
          { nhConfig    = cfg
          , nhSpi       = spi
          , nhState     = stVar
          , nhSentMsgs  = sent
          , nhRecvMsgs  = recv
          , nhRetrans   = retran
          , nhLost      = lost
          , nhSentBytes = sentB
          , nhRecvBytes = recvB
          }

    -- Put in PowerDown (CONFIG=0) for configuration
    nrfPut8Chk nh nrfCONFIG 0

    -- Disable all pipes
    nrfPut8Chk nh nrfEN_RXADDR 0

    if nrfAcked cfg
      then do
        -- Enable auto-ack on pipes 0 and 1
        nrfPut8Chk nh nrfEN_AA ((1 `shiftL` 0) .|. (1 `shiftL` 1))
        -- Enable pipes 0 and 1
        nrfPut8Chk nh nrfEN_RXADDR ((1 `shiftL` 0) .|. (1 `shiftL` 1))
        -- Set retransmit: delay and attempts
        let delayEnc = (fromIntegral (nrfRetranDelay cfg) `div` 250 - 1) .&. 0x0F
        let retranVal = (delayEnc `shiftL` 4) .|. (fromIntegral (nrfRetranAttempts cfg) .&. 0x0F)
        nrfPut8Chk nh nrfSETUP_RETR (fromIntegral retranVal)
      else do
        -- No auto-ack
        nrfPut8Chk nh nrfEN_AA 0
        -- Enable only pipe 1
        nrfPut8Chk nh nrfEN_RXADDR (1 `shiftL` 1)
        nrfPut8Chk nh nrfSETUP_RETR 0

    -- Set address width: addr_nbytes - 2 (3->1, 4->2, 5->3)
    nrfPut8Chk nh nrfSETUP_AW (nrfAddrBytes cfg - 2)

    -- Clear TX address
    nrfSetAddr nh nrfTX_ADDR 0

    -- Set RX address on pipe 1
    nrfSetAddr nh nrfRX_ADDR_P1 (nrfRxAddr cfg)
    nrfPut8Chk nh nrfRX_PW_P1 (nrfPayloadSize cfg)

    -- Clear pipe 0
    nrfSetAddr nh nrfRX_ADDR_P0 0
    nrfPut8Chk nh nrfRX_PW_P0 0

    -- Zero out unused pipes 2-5
    nrfPut8Chk nh (nrfRX_PW_P0 + 2) 0
    nrfPut8Chk nh (nrfRX_PW_P0 + 3) 0
    nrfPut8Chk nh (nrfRX_PW_P0 + 4) 0
    nrfPut8Chk nh (nrfRX_PW_P0 + 5) 0

    -- Set RF channel
    nrfPut8Chk nh nrfRF_CH (nrfChannel cfg)

    -- Set data rate and power
    nrfPut8Chk nh nrfRF_SETUP (dataRateToWord (nrfDataRate cfg)
                               .|. powerToWord (nrfPower cfg))

    -- Disable dynamic payload and features
    nrfPut8Chk nh nrfFEATURE 0
    nrfPut8Chk nh nrfDYNPD 0

    -- Flush FIFOs
    nrfFlushTx nh
    nrfFlushRx nh

    -- Clear all pending interrupts (write 1 to clear)
    void $ nrfPut8 nh nrfSTATUS 0x70

    -- PowerDown -> StandbyI (PWR_UP=1, wait 2ms)
    void $ nrfPut8 nh nrfCONFIG txConfigVal
    void $ swapMVar (nhState nh) StandbyI
    Timer.delayMs 2

    -- StandbyI -> RX mode (invariant: always in RX)
    nrfRxMode nh

    UART.putStrLn "NRF: Initialized"
    return nh

-- | Send a packet with hardware ACK.
-- Adapted from nrf-driver.c nrf_tx_send_ack.
-- Returns True if the packet was successfully ACKed.
nrfSend :: NrfHandle -> [Word8] -> IO Bool
nrfSend nh msg = do
    let cfg = nhConfig nh
    let nbytes = fromIntegral (nrfPayloadSize cfg) :: Int
    -- Pad or truncate message to payload size
    let payload = take nbytes (msg ++ repeat 0)

    -- Drain any pending RX packets first
    void $ drainRxPackets nh

    -- Set TX and RX_P0 addresses for auto-ack
    nrfSetAddr nh nrfRX_ADDR_P0 (nrfTxAddr cfg)
    nrfSetAddr nh nrfTX_ADDR (nrfTxAddr cfg)

    -- Load payload into TX FIFO
    void $ nrfPutN nh nrfW_TX_PAYLOAD payload

    -- Enter TX mode
    nrfTxMode nh

    -- Wait for TX_DS or MAX_RT
    waitForTxComplete nh 0 payload

  where
    waitForTxComplete nh_ attempt payload_ = do
        txDone <- nrfHasTxIntr nh_
        maxRt  <- nrfHasMaxRtIntr nh_
        if txDone
          then do
            -- Success: read retransmit count, clear interrupt, back to RX
            obs <- nrfGet8 nh_ nrfOBSERVE_TX
            let retrans = fromIntegral (obs .&. 0x0F)
            atomicModifyIORef' (nhRetrans nh_) (\r -> (r + retrans, ()))
            nrfTxIntrClr nh_
            atomicModifyIORef' (nhSentMsgs nh_) (\s -> (s + 1, ()))
            let nbytes_ = fromIntegral (nrfPayloadSize (nhConfig nh_))
            atomicModifyIORef' (nhSentBytes nh_) (\s -> (s + nbytes_, ()))
            nrfRxMode nh_
            return True
          else if maxRt
            then do
              -- Max retransmissions: clear, flush, back to RX
              obs <- nrfGet8 nh_ nrfOBSERVE_TX
              let retrans = fromIntegral (obs .&. 0x0F)
              atomicModifyIORef' (nhRetrans nh_) (\r -> (r + retrans, ()))
              nrfRtIntrClr nh_
              nrfFlushTx nh_
              nrfRxMode nh_
              if attempt >= (7 :: Int)
                then do
                  atomicModifyIORef' (nhLost nh_) (\l -> (l + 1, ()))
                  return False
                else do
                  -- Exponential backoff retry
                  t <- Timer.getTimeUs
                  let backoff = 500 * (1 `shiftL` attempt) + (t `mod` 500)
                  Timer.delayUs backoff
                  -- Retry: reload FIFO and try again
                  void $ nrfPutN nh_ nrfW_TX_PAYLOAD payload_
                  nrfTxMode nh_
                  waitForTxComplete nh_ (attempt + 1) payload_
            else do
              yield
              waitForTxComplete nh_ attempt payload_

-- | Send a packet without hardware ACK.
-- Adapted from nrf-driver.c nrf_tx_send_noack
nrfSendNoAck :: NrfHandle -> [Word8] -> IO Bool
nrfSendNoAck nh msg = do
    let cfg = nhConfig nh
    let nbytes = fromIntegral (nrfPayloadSize cfg) :: Int
    let payload = take nbytes (msg ++ repeat 0)

    -- Drain pending RX
    void $ drainRxPackets nh

    -- Set TX address
    nrfSetAddr nh nrfTX_ADDR (nrfTxAddr cfg)

    -- Load payload into TX FIFO
    void $ nrfPutN nh nrfW_TX_PAYLOAD payload

    -- Enter TX mode
    nrfTxMode nh

    -- Wait for TX_DS interrupt
    waitTx
    nrfTxIntrClr nh
    atomicModifyIORef' (nhSentMsgs nh) (\s -> (s + 1, ()))
    let nbytes_ = fromIntegral (nrfPayloadSize cfg)
    atomicModifyIORef' (nhSentBytes nh) (\s -> (s + nbytes_, ()))
    nrfRxMode nh
    return True
  where
    waitTx = do
        done <- nrfHasTxIntr nh
        unless done $ do
            yield
            waitTx

-- | Drain RX FIFO into a list of packets.
-- Adapted from nrf-driver.c nrf_get_pkts.
-- Returns list of received packets (each is a [Word8]).
drainRxPackets :: NrfHandle -> IO [[Word8]]
drainRxPackets nh = do
    hasData <- nrfRxHasPacket nh
    if not hasData
      then return []
      else drainLoop
  where
    nbytes = fromIntegral (nrfPayloadSize (nhConfig nh)) :: Int

    drainLoop = do
        -- Read packet from RX FIFO
        pkt <- nrfGetN nh nrfR_RX_PAYLOAD nbytes

        -- Update stats
        atomicModifyIORef' (nhRecvMsgs nh) (\r -> (r + 1, ()))
        let nb = fromIntegral nbytes :: Word32
        atomicModifyIORef' (nhRecvBytes nh) (\r -> (r + nb, ()))

        -- Clear RX interrupt
        nrfRxIntrClr nh

        -- Check if more packets
        empty <- nrfRxFifoEmpty nh
        if empty
          then return [pkt]
          else do
            rest <- drainLoop
            return (pkt : rest)

-- | Non-blocking receive. Returns Nothing if no packet available.
-- Use Maybe instead of C sentinel values.
nrfRecv :: NrfHandle -> IO (Maybe [Word8])
nrfRecv nh = do
    pkts <- drainRxPackets nh
    return (listToMaybe pkts)

-- | Read current NRF statistics.
nrfStats :: NrfHandle -> IO NrfStats
nrfStats nh = do
    s <- readIORef (nhSentMsgs nh)
    r <- readIORef (nhRecvMsgs nh)
    rt <- readIORef (nhRetrans nh)
    l <- readIORef (nhLost nh)
    sb <- readIORef (nhSentBytes nh)
    rb <- readIORef (nhRecvBytes nh)
    return NrfStats
      { statsSent      = s
      , statsRecv      = r
      , statsRetrans   = rt
      , statsLost      = l
      , statsSentBytes = sb
      , statsRecvBytes = rb
      }

-- | Convert Word32 to list of bytes (little-endian)
word32ToBytes :: Word32 -> [Word8]
word32ToBytes w =
    [ fromIntegral (w .&. 0xFF)
    , fromIntegral ((w `shiftR` 8) .&. 0xFF)
    , fromIntegral ((w `shiftR` 16) .&. 0xFF)
    , fromIntegral ((w `shiftR` 24) .&. 0xFF)
    ]

