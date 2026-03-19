# Haskell Guide

I thought I should add some soft explanations of Haskell as a language since it is inherently a little different than c. 

`newtype` makes a distinct type at compile time with zero runtime cost. The compiler won't let you mix them up, but the machine code is identical.

```hs
newtype Pin       = Pin { pinNumber :: Word32 }
newtype OutputPin = OutputPin Pin
newtype InputPin  = InputPin Pin
```

`pinWrite` expects an `OutputPin`, and now passing an `InputPin` is a compile error. In C, both would be `unsigned` and the compiler would happily let you swap them and your checks would only happen at runtime.

```haskell
data DataRate   = NRF1Mbps | NRF2Mbps | NRF250Kbps
data PowerLevel = DBmMinus18 | DBmMinus12 | DBmMinus6 | DBm0
data NrfState   = PowerDown | StandbyI | RxMode | TxMode
```

This makes parsing really easy, since a cfg can be expressed via an adt really simply:

```haskell
data LispVal
  = Atom String
  | Number Int
  | Bool Bool
  | Str String
  | List [LispVal]
  | Func String ([LispVal] -> IO (Either String LispVal))
  | Closure [String] LispVal Env
  | Nil
```

The IO monad is probably the first real sign of Haskell maturity? Everything that touches hardware/mutable state/actually does stuff is handled with IO, which basically says that the function is impure. 

```haskell
-- NRF.hs:457
nrfSend :: NrfHandle -> [Word8] -> IO Bool

-- NRF.hs:621 (pure, no IO)
word32ToBytes :: Word32 -> [Word8]
```

So you can express within the type system what actually matters!

On bare metal this matters a lot since there's no OS protecting you from out-of-order register writes. `do`-notation forces hardware ops into a strict sequence so the compiler can't reorder a `GPIO.rawWrite` before `GPIO.rawSetOutput`. In C any function can silently touch hardware, but in Haskell `peek8 :: Ptr -> Word32 -> IO Word8` makes the side effect visible in the type.

Like `peek8 src off >>= poke8 dest off` (FAT32.hs) has IO forcing the read before the write. Same idea as what C programmers do with `volatile`, except the compiler actually checks it.

`Maybe` replaces null pointers and sentinel return values. `Either` replaces error codes. When the standard library's `MaybeT` isn't available (MicroHs doesn't ship it), you can build your own, and `FAT32.hs` has a lightweight `MaybeIO` monad that flattens nested case-on-Maybe inside IO, eliminating staircase patterns.

```haskell
-- NRF.hs:592-595
nrfRecv :: NrfHandle -> IO (Maybe [Word8])
nrfRecv nh = do
    pkts <- drainRxPackets nh
    return (listToMaybe pkts)
```

```haskell
-- Lisp.hs:59-63
lispParse :: String -> Either String LispVal
lispParse input = case runParser (spaces *> parseExpr <* spaces) input of
  Just (val, "") -> Right val
  Just (_, rest) -> Left ("Unexpected trailing input: " ++ take 20 rest)
  Nothing        -> Left "Parse error"
```

`Parse.hs` builds parser combinators by implementing four typeclass instances for `Parser`:

```haskell
-- Parse.hs:42
newtype Parser a = Parser { runParser :: String -> Maybe (a, String) }

-- Parse.hs:44-72
instance Functor Parser where ...     -- transform parse results
instance Applicative Parser where ... -- sequence independent parsers
instance Monad Parser where ...       -- sequence dependent parsers
instance Alternative Parser where ... -- try/fallback with <|>
```

All the combinators (`many1`, `sepBy`, `between`, `optional`, etc.) come from those four instances. The Lisp parser and shell argument parsing are just compositions of them.

Haskell has no mutable variables by default. When you need one, `IORef` lets you do mutable references w/n the IO monad:

```haskell
-- NRF.hs:190-200
data NrfHandle = NrfHandle
  { ...
  , nhSentMsgs  :: IORef Word32
  , nhRecvMsgs  :: IORef Word32
  , nhRetrans   :: IORef Word32
  , nhLost      :: IORef Word32
  , nhSentBytes :: IORef Word32
  , nhRecvBytes :: IORef Word32
  }
```

`forkIO` spawns green threads managed by the runtime, not OS threads. `MVar` provides typed, blocking synchronization, and you can implment a simple actor model (https://www.brianstorti.com/the-actor-model/).

```haskell
-- Main.hs: supervisor launches heartbeat + shell as Permanent children
supervisor
    [ ChildSpec "heartbeat" (heartbeat heartbeatPin heartbeatVar) Permanent
    , ChildSpec "shell"     (runShell mfs heartbeatVar)           Permanent
    ]
```

```haskell
-- Process.hs:35-40
data Chan a = Chan
  { chanRead  :: MVar (MVar (ChItem a))
  , chanWrite :: MVar (MVar (ChItem a))
  }
data ChItem a = ChItem a (MVar (ChItem a))
```

```haskell
-- Process.hs:108-114
spawn :: String -> IO () -> IO ProcHandle
spawn name action = do
    stVar <- newMVar Running
    void $ forkIO $
        runSafe stVar action
    return (ProcHandle name stVar)
```

The `Chan a` type is now parameterized, as `Chan LispVal` and `Chan [Word8]` are different types, so you can't accidentally send the wrong message type. 

Functions capture their environment (closures). The Lisp interpreter uses this for lexical scoping.

```haskell
-- Lisp.hs:193-195
eval env (List [Atom "lambda", List params, body]) = do
    let paramNames = map extractName params
    return (Right (Closure paramNames body env))

-- Lisp.hs:292-295
apply (Closure params body closureEnv) args = do
    parentBindings <- readMVar closureEnv
    localEnv <- newMVar (zip params args ++ parentBindings)
    eval localEnv body
```

Everyone's favorite Haskell feature is lazy evaluation, so we oftentimes work with infinite data structures because why not:

```haskell
-- NRF.hs:462
let payload = take nbytes (msg ++ repeat 0)
```

`repeat 0` is an infinite list of zeros but `take nbytes` means only what's needed gets computed.

Most important to the project was the FFI interface which lets you type c functions that are calling assembly.

```haskell
-- VM.hs:32-34
foreign import ccall "mmu_enable"    c_mmu_enable    :: IO ()
foreign import ccall "mmu_set_ttbr0" c_mmu_set_ttbr0 :: Word32 -> IO ()

-- Main.hs:21
foreign export ccall hs_main :: IO ()
```

Named fields are like C struct fields but they also give you accessor functions for free:

```haskell
-- NRF.hs:59-72
data NrfConfig = NrfConfig
  { nrfChannel       :: Word8
  , nrfDataRate      :: DataRate
  , nrfPower         :: PowerLevel
  , nrfPayloadSize   :: Word8
  , nrfCePin         :: Word32
  , nrfSpiChip       :: Word32
  , nrfRxAddr        :: Word32
  , nrfTxAddr        :: Word32
  , nrfAcked         :: Bool
  , nrfRetranAttempts :: Word8
  , nrfRetranDelay   :: Word16
  , nrfAddrBytes     :: Word8
  }
```

Note each field name is also a function: `nrfChannel :: NrfConfig -> Word8`.

A lot of the code uses `do` notation, which allows you to write monadic code more imperatively while still being "purely functional" (in reality its a bunch of `>>=` operations).

```haskell
-- Parse.hs:139-145
integer :: Parser Int
integer = do
    sign <- optional (char '-')
    n <- natural
    return $ case sign of
      Just _  -> negate n
      Nothing -> n
```

This leads to very ugly imperative looking code a lot of the time but I digress.

## Operator / Shorthand Cheat Sheet

Here's a cheatsheet for the operators used in Haskell:

| Operator | What it does | Example from project |
|----------|-------------|---------------------|
| `$` | Function application (avoids parens) | `when ok $ UART.putStrLn ...` (Shell.hs) |
| `.` | Function composition | `reverse . dropWhile (== ' ') . reverse` (FAT32.hs) |
| `<$>` | Infix `fmap`, transform inside a functor | `fromIntegral <$> natural` (Shell.hs) |
| `<*>` | Applicative apply, combine two wrapped values | `(:) <$> p <*> many p` (Parse.hs) |
| `*>` / `<*` | Sequence, discard one side | `open *> p <* close` (Parse.hs) |
| `<\|>` | Alternative, try first, fallback to second | `(fromIntegral <$> natural) <\|> pure 5` (Shell.hs) |
| `>>` | Monadic sequence, discard left result | `putStr s >> putChar '\n'` (UART.hs) |
| `>>=` | Monadic bind, pass result to next action | `peek8 src off >>= poke8 dest off` (FAT32.hs) |
| `void` | Discard result, return `()` | `void $ forkIO $ runSafe stVar action` (Process.hs) |
| `when` | Conditional IO, run action if True | `when ok $ UART.putStrLn ...` (Shell.hs) |
| `unless` | Conditional IO, run action if False | `unless done $ do yield; waitTx` (NRF.hs) |
| `replicateM_` | Repeat an action N times | `replicateM_ n (blink pin ms)` (GPIO.hs) |
| `zipWithM_` | Monadic zipWith, discard results | `zipWithM_ (\i b -> poke8 buf (off+i) b) [0..] bytes` (FAT32.hs) |
| `listToMaybe` | Safe head, `[] → Nothing`, `(x:_) → Just x` | `return (listToMaybe pkts)` (NRF.hs) |
| `modifyMVar_` | Modify MVar contents in-place | `modifyMVar_ env (\bs -> return ((name,val):bs))` (Lisp.hs) |
| `` `bindE` `` | Chain `IO (Either String a)`, custom combinator | ``eval env x `bindE` \val -> ...`` (Lisp.hs) |
