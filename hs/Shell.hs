-- | Shell.hs - shell in UART! lab 16 extension

module Shell
  ( -- * Shell
    runShell, processCommand
  ) where

import Prelude hiding (putStr, putStrLn, getLine, readFile, writeFile)
import Data.Word
import Data.Char (toLower, ord)
import Parse (parse, runParser, natural, spaces, spaces1, word, rest, string, optional)
import Control.Applicative ((<|>))
import Control.Monad (when, void, zipWithM_)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import qualified UART
import qualified GPIO
import qualified Timer
import qualified FAT32
import qualified Interrupt
import qualified NRF
import qualified NetChan
import qualified Lisp
import Alloc (alloc, Ptr, poke8)
import Hal (c_reboot)

-- | Shell state: holds references to optional subsystems
data ShellState = ShellState
  { ssFs       :: Maybe FAT32.FAT32FS
  , ssHbVar    :: MVar Bool
  , ssNrf      :: MVar (Maybe NRF.NrfHandle)   -- ^ Initialized on demand
  , ssNetChan  :: MVar (Maybe NetChan.NetChan) -- ^ Opened on demand
  }

-- | Run the interactive shell (loops forever)
runShell :: Maybe FAT32.FAT32FS -> MVar Bool -> IO ()
runShell mfs hbVar = do
    nrfVar <- newMVar Nothing
    ncVar  <- newMVar Nothing
    let st = ShellState mfs hbVar nrfVar ncVar
    UART.putStrLn ""
    UART.putStrLn "===================================="
    UART.putStrLn " HaskellOS Shell"
    UART.putStrLn " Type 'help' for available commands"
    UART.putStrLn "===================================="
    loop st

-- | Main shell loop, just pase it
loop :: ShellState -> IO ()
loop st = do
    UART.putStr "haskell-os> "
    input <- UART.getLine
    let (cmd, args) = parseCommand input
    let lCmd = map toLower cmd
    if null lCmd
      then loop st
      else if lCmd == "reboot"
        then doReboot--
        else do
          dispatchCommand st lCmd args
          loop st

dispatchCommand :: ShellState -> String -> String -> IO ()
dispatchCommand st cmd args = case cmd of
    "help"      -> showHelp
    "blink"     -> doBlink args
    "echo"      -> doEcho
    "timer"     -> doTimer
    "gpio"      -> doGpio args
    "ls"        -> doLs (ssFs st)
    "cat"       -> doCat (ssFs st) args
    "info"      -> doInfo (ssFs st)
    "vm"        -> doVmTest
    "touch"     -> doTouch (ssFs st) args
    "write"     -> doWrite (ssFs st) args
    "rm"        -> doRm (ssFs st) args
    "mv"        -> doMv (ssFs st) args
    "heartbeat" -> doHeartbeat (ssHbVar st) args
    "uptime"    -> doUptime
    "nrf"       -> doNrf st args
    "lisp"      -> doLisp (ssFs st) args
    _           -> do
        UART.putStr "Unknown command: "
        UART.putStrLn cmd
        UART.putStrLn "Type 'help' for available commands"

-- | Parse a command line into (command, arguments)
parseCommand :: String -> (String, String)
parseCommand s = case runParser cmdParser s of
    Just ((cmd, args), _) -> (cmd, args)
    Nothing               -> ("", "")
  where
    cmdParser = do
        _ <- spaces
        cmd <- word
        _ <- spaces
        args <- rest
        return (cmd, args)

-- | Process a single command
processCommand :: Maybe FAT32.FAT32FS -> MVar Bool -> String -> IO ()
processCommand mfs hbVar input = do
    nrfVar <- newMVar Nothing
    ncVar  <- newMVar Nothing
    let st = ShellState mfs hbVar nrfVar ncVar
    let (cmd, args) = parseCommand input
    let lCmd = map toLower cmd
    if lCmd == "reboot"
      then doReboot
      else dispatchCommand st lCmd args

showHelp :: IO ()
showHelp = mapM_ UART.putStrLn
    [ "Available commands:"
    , "  help                     - Show this help"
    , "  blink [pin] [n]          - Blink GPIO pin (default: 27, 5 times)"
    , "  echo                     - Echo typed characters (Ctrl-D to exit)"
    , "  timer                    - Show system timer value"
    , "  gpio <pin> [0|1]         - Read/write GPIO pin"
    , "  ls                       - List files on SD card"
    , "  cat <file>               - Display file contents"
    , "  touch <file>             - Create an empty file"
    , "  write <file> <text>      - Write text to a file"
    , "  rm <file>                - Delete a file"
    , "  mv <old> <new>           - Rename a file"
    , "  info                     - Show filesystem info"
    , "  vm                       - Show MMU status"
    , "  heartbeat [on|off]       - Toggle background LED heartbeat"
    , "  uptime                   - Show uptime from timer interrupts"
    , "  nrf init [server|client] - Initialize NRF radio"
    , "  nrf send <msg>           - Send message over NRF"
    , "  nrf recv                 - Receive message from NRF"
    , "  nrf stats                - Show NRF statistics"
    , "  nrf status               - Read NRF STATUS register"
    , "  lisp                     - Lisp interpreter (type (exit) to quit)"
    , "  lisp run <file>          - Run a Lisp file from SD card"
    , "  reboot                   - Reboot the Pi"
    ]

-- | Blink an LED
doBlink :: String -> IO ()
doBlink args = do
    let (pinNum, count) = parseBlink args
    UART.putStr "Blinking pin "
    UART.putUint pinNum
    UART.putStr " "
    UART.putUint count
    UART.putStrLn " times..."
    pin <- GPIO.outputPin pinNum
    GPIO.blinkN pin 200 (fromIntegral count)
    UART.putStrLn "Done blinking"
  where
    parseBlink s = case runParser blinkParser s of
        Just ((p, n), _) -> (p, n)
        Nothing          -> (27, 5)
      where
        blinkParser = do
            _ <- spaces
            p <- fromIntegral <$> natural
            _ <- spaces
            n <- (fromIntegral <$> natural) <|> pure 5
            return (p, n)

-- | Echo mode: echo back typed characters
doEcho :: IO ()
doEcho = do
    UART.putStrLn "Echo mode (type Ctrl-D to exit):"
    echoLoop
  where
    echoLoop = do
        c <- UART.getChar
        if c == '\EOT'  -- Ctrl-D
          then UART.putStrLn "\nExited echo mode"
          else do
            UART.putChar c
            echoLoop

-- | Show timer value
doTimer :: IO ()
doTimer = do
    us <- Timer.getTimeUs
    UART.putStr "System timer: "
    UART.putUint us
    UART.putStrLn " us"
    ms <- Timer.getTimeMs
    UART.putStr "             = "
    UART.putUint ms
    UART.putStrLn " ms"

-- | GPIO read/write
doGpio :: String -> IO ()
doGpio args = case runParser gpioParser args of
    Just ((pin, mval), _) -> case mval of
        Nothing -> do
            val <- GPIO.rawRead pin
            UART.putStr "GPIO "
            UART.putUint pin
            UART.putStr " = "
            UART.putUint val
            UART.putChar '\n'
        Just val -> do
            GPIO.rawSetOutput pin
            GPIO.rawWrite pin val
            UART.putStr "GPIO "
            UART.putUint pin
            UART.putStr " <- "
            UART.putUint val
            UART.putChar '\n'
    Nothing -> UART.putStrLn "Usage: gpio <pin> [0|1]"
  where
    gpioParser = do
        _ <- spaces
        pin <- fromIntegral <$> natural
        _ <- spaces
        mval <- optional (fromIntegral <$> natural)
        return (pin, mval)

-- | List directory
doLs :: Maybe FAT32.FAT32FS -> IO ()
doLs Nothing = UART.putStrLn "No filesystem mounted"
doLs (Just fs) = do
    entries <- FAT32.listRoot fs
    UART.putStrLn "Directory listing:"
    mapM_ FAT32.printDirEntry entries
    UART.putStr (show (length entries) ++ " entries\n")

-- | Cat a file
doCat :: Maybe FAT32.FAT32FS -> String -> IO ()
doCat Nothing _ = UART.putStrLn "No filesystem mounted"
doCat _ "" = UART.putStrLn "Usage: cat <filename>"
doCat (Just fs) name = do
    mEntry <- FAT32.findEntry fs (FAT32.bpbRootCluster (FAT32.fsBPB fs)) name
    case mEntry of
        Nothing -> do
            UART.putStr "File not found: "
            UART.putStrLn name
        Just entry -> do
            bytes <- FAT32.readFileBytes fs entry
            mapM_ UART.putByte bytes
            UART.putChar '\n'

-- | Lisp command dispatcher,
--   bare "lisp" opens REPL, "lisp run <file>" runs a file
doLisp :: Maybe FAT32.FAT32FS -> String -> IO ()
doLisp mfs args = case parse lispCmd args of
    Just name -> doLispRun mfs name
    Nothing   -> Lisp.runLispRepl
  where
    lispCmd = do
        _ <- spaces
        _ <- string "run"
        _ <- spaces1
        name <- word
        _ <- spaces
        return name

-- | Run a Lisp file from the SD card
doLispRun :: Maybe FAT32.FAT32FS -> String -> IO ()
doLispRun Nothing _ = UART.putStrLn "No filesystem mounted"
doLispRun (Just fs) name = do
    mEntry <- FAT32.findEntry fs (FAT32.bpbRootCluster (FAT32.fsBPB fs)) name
    case mEntry of
        Nothing -> do
            UART.putStr "File not found: "
            UART.putStrLn name
        Just entry -> do
            bytes <- FAT32.readFileBytes fs entry
            let contents = map (toEnum . fromIntegral) bytes
            UART.putStr "Running "
            UART.putStrLn name
            Lisp.runLispFile contents

-- | Show filesystem info
doInfo :: Maybe FAT32.FAT32FS -> IO ()
doInfo Nothing = UART.putStrLn "No filesystem mounted"
doInfo (Just fs) = FAT32.printFSInfo fs

-- | Create an empty file
doTouch :: Maybe FAT32.FAT32FS -> String -> IO ()
doTouch Nothing _ = UART.putStrLn "No filesystem mounted"
doTouch _ "" = UART.putStrLn "Usage: touch <filename>"
doTouch (Just fs) name = do
    let rootCluster = FAT32.bpbRootCluster (FAT32.fsBPB fs)
    result <- FAT32.createFile fs rootCluster name
    case result of
      Nothing -> return ()
      Just _  -> UART.putStrLn ("Created: " ++ name)

-- | Write text to a file
doWrite :: Maybe FAT32.FAT32FS -> String -> IO ()
doWrite Nothing _ = UART.putStrLn "No filesystem mounted"
doWrite (Just fs) args = case runParser writeParser args of
    Just ((name, content), _)
      | not (null content) -> do
        let rootCluster = FAT32.bpbRootCluster (FAT32.fsBPB fs)
        -- Ensure file exists
        mEntry <- FAT32.findEntry fs rootCluster name
        case mEntry of
          Nothing -> do
            mc <- FAT32.createFile fs rootCluster name
            case mc of
              Nothing -> return ()
              Just _  -> writeContent fs rootCluster name content
          Just _ -> writeContent fs rootCluster name content
    _ -> UART.putStrLn "Usage: write <filename> <text...>"
  where
    writeParser = do
        _ <- spaces
        name <- word
        _ <- spaces1
        content <- rest
        return (name, content)
    writeContent fs rc name content = do
        let len = fromIntegral (length content) :: Word32
        buf <- alloc (len + 4)  -- extra padding for alignment
        zipWithM_ (\i c -> poke8 buf i (fromIntegral (ord c))) [0..] content
        ok <- FAT32.writeFile fs rc name buf len
        when ok $ do UART.putStr "Wrote "
                     UART.putUint len
                     UART.putStrLn (" bytes to " ++ name)

-- | Delete a file
doRm :: Maybe FAT32.FAT32FS -> String -> IO ()
doRm Nothing _ = UART.putStrLn "No filesystem mounted"
doRm _ "" = UART.putStrLn "Usage: rm <filename>"
doRm (Just fs) name = do
    let rootCluster = FAT32.bpbRootCluster (FAT32.fsBPB fs)
    ok <- FAT32.deleteFile fs rootCluster name
    when ok $ UART.putStrLn ("Deleted: " ++ name)

-- | Rename a file
doMv :: Maybe FAT32.FAT32FS -> String -> IO ()
doMv Nothing _ = UART.putStrLn "No filesystem mounted"
doMv (Just fs) args = case parse mvParser args of
    Just (old, new) -> do
        let rootCluster = FAT32.bpbRootCluster (FAT32.fsBPB fs)
        ok <- FAT32.renameFile fs rootCluster old new
        when ok $ UART.putStrLn ("Renamed: " ++ old ++ " -> " ++ new)
    Nothing -> UART.putStrLn "Usage: mv <oldname> <newname>"
  where
    mvParser = do
        _ <- spaces
        old <- word
        _ <- spaces1
        new <- word
        _ <- spaces
        return (old, new)

-- | Toggle heartbeat LED thread
doHeartbeat :: MVar Bool -> String -> IO ()
doHeartbeat var "on" = do
    void $ swapMVar var True
    UART.putStrLn "Heartbeat ON"
doHeartbeat var "off" = do
    void $ swapMVar var False
    UART.putStrLn "Heartbeat OFF"
doHeartbeat var "" = do
    st <- readMVar var
    if st
      then UART.putStrLn "Heartbeat is ON"
      else UART.putStrLn "Heartbeat is OFF"
doHeartbeat _ _ = UART.putStrLn "Usage: heartbeat [on|off]"

-- | Show uptime from hardware timer interrupt ticks
doUptime :: IO ()
doUptime = do
    ticks <- Interrupt.timerTicks
    let secs = ticks `div` 100     -- 10ms per tick
    let mins = secs `div` 60
    let remSecs = secs `mod` 60
    UART.putStr "Uptime: "
    UART.putUint (fromIntegral mins)
    UART.putStr "m "
    UART.putUint (fromIntegral remSecs)
    UART.putStrLn "s"
    UART.putStr "Timer ticks: "
    UART.putUint ticks
    UART.putChar '\n'

-- | Reboot
doReboot :: IO ()
doReboot = do
    UART.putStrLn "Rebooting..."
    UART.putStrLn ""
    c_reboot

-- | Show MMU status (MMU is permanently enabled since boot)
doVmTest :: IO ()
doVmTest = do
    UART.putStrLn "MMU is permanently enabled since boot."
    UART.putStrLn "Verifying device access..."
    val <- GPIO.rawRead 27
    UART.putStr "GPIO 27 = "
    UART.putUint val
    UART.putChar '\n'
    us <- Timer.getTimeUs
    UART.putStr "Timer: "
    UART.putUint us
    UART.putStrLn " us"
    UART.putStrLn "VM: all regions mapped, DomainClient active."

-- | NRF radio command dispatcher
doNrf :: ShellState -> String -> IO ()
doNrf st args = case runParser nrfCmd args of
    Just (cmd, remaining) -> case cmd of
        "init"   -> doNrfInit st remaining
        "send"   -> doNrfSend st remaining
        "recv"   -> doNrfRecv st
        "stats"  -> doNrfStats st
        "status" -> doNrfStatus st
        _        -> usage
    Nothing -> usage
  where
    nrfCmd = do
        _ <- spaces
        cmd <- word
        _ <- spaces
        return cmd
    usage = UART.putStrLn "Usage: nrf init [server|client] | send <msg> | recv | stats | status"

-- | Initialize NRF radio
doNrfInit :: ShellState -> String -> IO ()
doNrfInit st args = do
    let mRole = parse nrfRole args
    let cfg = case mRole of
                Just "client" -> NRF.clientConfig
                Just "server" -> NRF.serverConfig
                _             -> NRF.serverConfig  -- default to server
    UART.putStrLn "NRF: Initializing..."
    nh <- NRF.nrfInit cfg
    _ <- swapMVar (ssNrf st) (Just nh)
    -- Read STATUS register to verify
    status <- NRF.nrfGet8 nh 0x07
    UART.putStr "NRF: STATUS = "
    UART.putHex (fromIntegral status)
    UART.putChar '\n'
    UART.putStrLn "NRF: Ready"
  where
    nrfRole = do
        _ <- spaces
        role <- word
        _ <- spaces
        return role

-- | Send a string message over NRF
doNrfSend :: ShellState -> String -> IO ()
doNrfSend st msg = do
    mnrf <- readMVar (ssNrf st)
    case mnrf of
      Nothing -> UART.putStrLn "NRF: Not initialized (run 'nrf init' first)"
      Just nh -> do
        let encoded = NetChan.encode (NetChan.MsgStr msg)
        let pktSize = fromIntegral (NRF.nrfPayloadSize (NRF.nhConfig nh))
        let padded = take pktSize (encoded ++ repeat 0)
        ok <- NRF.nrfSend nh padded
        if ok
          then do
            UART.putStr "NRF: Sent \""
            UART.putStr msg
            UART.putStrLn "\""
          else UART.putStrLn "NRF: Send failed (no ACK)"

-- | Receive a message from NRF (blocking with timeout)
doNrfRecv :: ShellState -> IO ()
doNrfRecv st = do
    mnrf <- readMVar (ssNrf st)
    case mnrf of
      Nothing -> UART.putStrLn "NRF: Not initialized (run 'nrf init' first)"
      Just nh -> do
        UART.putStrLn "NRF: Waiting for packet (press any key to cancel)..."
        recvLoop nh 0
  where
    recvLoop nh attempts = do
        mpkt <- NRF.nrfRecv nh
        case mpkt of
          Just pkt -> do
            UART.putStr "NRF: Received: "
            case NetChan.decode pkt of
              Just (NetChan.MsgStr s) -> UART.putStrLn s
              Just msg -> UART.putStrLn (show msg)
              Nothing -> do
                UART.putStr "[raw "
                UART.putUint (fromIntegral (length pkt))
                UART.putStrLn " bytes]"
          Nothing -> do
            -- Check if user pressed a key to cancel.
            -- Must check interrupt ring buffer
            -- since UART RX interrupts are enabled and the IRQ handler
            -- drains the FIFO into the ring buffer.
            hasKey <- Interrupt.uartRxHasData
            if hasKey
              then do
                _ <- UART.getChar
                UART.putStrLn "NRF: Cancelled"
              else if attempts >= 5000  -- ~5 seconds at 1ms intervals
                then UART.putStrLn "NRF: Timeout (no packet received)"
                else do
                  threadDelay 1000
                  recvLoop nh (attempts + 1)

-- | Show NRF statistics
doNrfStats :: ShellState -> IO ()
doNrfStats st = do
    mnrf <- readMVar (ssNrf st)
    case mnrf of
      Nothing -> UART.putStrLn "NRF: Not initialized"
      Just nh -> do
        stats <- NRF.nrfStats nh
        UART.putStrLn "NRF Statistics:"
        UART.putStr "  Sent:        "
        UART.putUint (NRF.statsSent stats)
        UART.putStr " msgs, "
        UART.putUint (NRF.statsSentBytes stats)
        UART.putStrLn " bytes"
        UART.putStr "  Received:    "
        UART.putUint (NRF.statsRecv stats)
        UART.putStr " msgs, "
        UART.putUint (NRF.statsRecvBytes stats)
        UART.putStrLn " bytes"
        UART.putStr "  Retransmits: "
        UART.putUint (NRF.statsRetrans stats)
        UART.putChar '\n'
        UART.putStr "  Lost:        "
        UART.putUint (NRF.statsLost stats)
        UART.putChar '\n'

-- | Read NRF STATUS register
doNrfStatus :: ShellState -> IO ()
doNrfStatus st = do
    mnrf <- readMVar (ssNrf st)
    case mnrf of
      Nothing -> UART.putStrLn "NRF: Not initialized"
      Just nh -> do
        status <- NRF.nrfGet8 nh 0x07
        config <- NRF.nrfGet8 nh 0x00
        fifo   <- NRF.nrfGet8 nh 0x17
        rfCh   <- NRF.nrfGet8 nh 0x05
        rfSetup <- NRF.nrfGet8 nh 0x06
        UART.putStr "NRF STATUS:      "
        UART.putHex (fromIntegral status)
        UART.putChar '\n'
        UART.putStr "NRF CONFIG:      "
        UART.putHex (fromIntegral config)
        UART.putChar '\n'
        UART.putStr "NRF FIFO_STATUS: "
        UART.putHex (fromIntegral fifo)
        UART.putChar '\n'
        UART.putStr "NRF RF_CH:       "
        UART.putUint (fromIntegral rfCh)
        UART.putChar '\n'
        UART.putStr "NRF RF_SETUP:    "
        UART.putHex (fromIntegral rfSetup)
        UART.putChar '\n'

