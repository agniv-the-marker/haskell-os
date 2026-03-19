-- | NetChan.hs - lab 14, based on nrf-driver.c
--
-- custom message type/constructor/encode/decode

module NetChan
  ( -- * Message type
    Msg(..)
    -- * Serialization
  , encode, decode
    -- * Network channel
  , NetChan(..)
  , openNetChan
  , netSend, netRecv
  ) where

import Prelude hiding (putStr, putStrLn)
import Data.Word
import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import Data.Foldable (forM_)
import Control.Monad (void, when)
import Data.Char (ord, chr)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import qualified NRF
import qualified UART
import Process (Chan, newChan, send, recv)

-- | A universal message type for typed wireless communication.
-- Each constructor has a unique tag byte for serialization.
-- Maximum serialized size = 32 bytes (NRF payload limit).
data Msg
  = MsgInt Int           -- ^ Tag 0x01: signed integer (4 bytes)
  | MsgStr String        -- ^ Tag 0x02: string (length-prefixed, max 30 chars)
  | MsgWord Word32       -- ^ Tag 0x03: unsigned 32-bit word
  | MsgBytes [Word8]     -- ^ Tag 0x04: raw bytes (length-prefixed, max 30)
  | MsgPair Msg Msg      -- ^ Tag 0x05: pair of messages
  | MsgTag String Msg    -- ^ Tag 0x06: tagged message (for routing)
  | MsgNone              -- ^ Tag 0x00: empty/ping message
  deriving (Show, Eq)

-- | Encode a Msg into bytes for NRF transmission.
-- Format: tag byte followed by type-specific payload.
encode :: Msg -> [Word8]

encode MsgNone = [0x00]

encode (MsgInt n) =
    let w = fromIntegral n :: Word32
    in 0x01 : encWord32 w

encode (MsgStr s) =
    let bytes = map (fromIntegral . ord) (take 30 s)
        len = fromIntegral (length bytes) :: Word8
    in [0x02, len] ++ bytes

encode (MsgWord w) = 0x03 : encWord32 w

encode (MsgBytes bs) =
    let trimmed = take 30 bs
        len = fromIntegral (length trimmed) :: Word8
    in [0x04, len] ++ trimmed

encode (MsgPair a b) =
    let ea = encode a
        eb = encode b
        la = fromIntegral (length ea) :: Word8
    in [0x05, la] ++ ea ++ eb

encode (MsgTag tag msg) =
    let tagBytes = map (fromIntegral . ord) (take 10 tag)
        tagLen = fromIntegral (length tagBytes) :: Word8
        msgBytes = encode msg
    in [0x06, tagLen] ++ tagBytes ++ msgBytes

-- | Decode bytes back into a Msg. Returns Nothing on malformed data.
decode :: [Word8] -> Maybe Msg
decode [] = Nothing

decode (0x00 : _) = Just MsgNone

decode (0x01 : rest)
    | length rest >= 4 = Just (MsgInt (fromIntegral (decWord32 rest)))
    | otherwise = Nothing

decode (0x02 : len : rest)
    | length rest >= fromIntegral len =
        let (strBytes, _) = splitAt (fromIntegral len) rest
        in Just (MsgStr (map (chr . fromIntegral) strBytes))
    | otherwise = Nothing

decode (0x03 : rest)
    | length rest >= 4 = Just (MsgWord (decWord32 rest))
    | otherwise = Nothing

decode (0x04 : len : rest)
    | length rest >= fromIntegral len =
        let (bs, _) = splitAt (fromIntegral len) rest
        in Just (MsgBytes bs)
    | otherwise = Nothing

decode (0x05 : la : rest)
    | length rest >= fromIntegral la =
        let (aBytes, bBytes) = splitAt (fromIntegral la) rest
        in case (decode aBytes, decode bBytes) of
          (Just a, Just b) -> Just (MsgPair a b)
          _                -> Nothing
    | otherwise = Nothing

decode (0x06 : tl : rest)
    | length rest >= fromIntegral tl =
        let (tagBytes, msgBytes) = splitAt (fromIntegral tl) rest
            tag = map (chr . fromIntegral) tagBytes
        in case decode msgBytes of
          Just msg -> Just (MsgTag tag msg)
          Nothing  -> Nothing
    | otherwise = Nothing

decode _ = Nothing

-- | Encode a Word32 as 4 bytes (little-endian)
encWord32 :: Word32 -> [Word8]
encWord32 w =
    [ fromIntegral (w .&. 0xFF)
    , fromIntegral ((w `shiftR` 8) .&. 0xFF)
    , fromIntegral ((w `shiftR` 16) .&. 0xFF)
    , fromIntegral ((w `shiftR` 24) .&. 0xFF)
    ]

-- | Decode 4 bytes (little-endian) into a Word32
decWord32 :: [Word8] -> Word32
decWord32 (a:b:c:d:_) =
    fromIntegral a
    .|. (fromIntegral b `shiftL` 8)
    .|. (fromIntegral c `shiftL` 16)
    .|. (fromIntegral d `shiftL` 24)
decWord32 _ = 0


-- | A network channel for typed message passing over NRF radio.
-- Spawns background send/recv green threads.
data NetChan = NetChan
  { ncNrf     :: NRF.NrfHandle
  , ncInbox   :: Chan Msg       -- ^ Local channel fed by recv green thread
  , ncOutbox  :: Chan Msg       -- ^ Local channel drained by send green thread
  , ncActive  :: MVar Bool      -- ^ Shutdown flag
  }

-- | Create a network channel. Spawns background send/recv green threads
-- that bridge local MVar channels with the NRF radio.
openNetChan :: NRF.NrfHandle -> IO NetChan
openNetChan nrf = do
    inbox  <- newChan
    outbox <- newChan
    active <- newMVar True
    let nc = NetChan nrf inbox outbox active
    void $ forkIO (recvThread nc) -- spawn recieve threads
    void $ forkIO (sendThread nc) -- spawn send threads
    UART.putStrLn "NetChan: Opened (send/recv threads started)"
    return nc

-- | Send a typed message over the network channel
netSend :: NetChan -> Msg -> IO ()
netSend nc = send (ncOutbox nc)

-- | Receive a typed message from the network channel (blocking)
netRecv :: NetChan -> IO Msg
netRecv nc = recv (ncInbox nc)

-- | Background thread that polls NRF for incoming packets,
-- decodes them into Msg values, and puts them on the inbox channel.
recvThread :: NetChan -> IO ()
recvThread nc = go
  where
    go = do
        active <- readMVar (ncActive nc)
        when active $ do
            mpkt <- NRF.nrfRecv (ncNrf nc)
            case mpkt of
                Nothing  -> threadDelay 5000
                Just pkt -> forM_ (decode pkt) (send (ncInbox nc))
            go

-- | Background thread that reads Msg values from the outbox channel,
-- encodes them, and sends over NRF radio.
sendThread :: NetChan -> IO ()
sendThread nc = go
  where
    go = do
        active <- readMVar (ncActive nc)
        when active $ do
            msg <- recv (ncOutbox nc)
            let bytes   = encode msg
                pktSize = fromIntegral (NRF.nrfPayloadSize (NRF.nhConfig (ncNrf nc)))
            when (length bytes > pktSize) $
                UART.putStrLn "NetChan: WARNING message truncated"
            let padded  = take pktSize (bytes ++ repeat 0)
            void $ NRF.nrfSend (ncNrf nc) padded
            go