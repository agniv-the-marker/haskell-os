{- HLINT ignore "Use lambda-case" -}
-- | Lisp.hs - custom lisp interpreter, since haskell is nice for this
--             based somewhat on cs242 homeworks + online + llm advice

module Lisp
  ( -- * REPL
    runLispRepl
    -- * File execution
  , runLispFile, lispParseMulti
    -- * Types
  , LispVal(..)
  , Env
    -- * Parsing
  , lispParse
    -- * Evaluation
  , eval, defaultEnv, showVal
  ) where

import Prelude hiding (putStr, putStrLn, getLine)
import Data.Char (isDigit, isAlpha, isAlphaNum, isSpace)
import Control.Applicative (Alternative(..))
import Control.Concurrent.MVar
import Parse
import qualified UART
import qualified GPIO
import qualified Timer

data LispVal
  = Atom String                                            -- symbol
  | Number Int                                             -- integer
  | Bool Bool                                              -- #t / #f
  | Str String                                             -- "string"
  | List [LispVal]                                         -- (a b c)
  | Func String ([LispVal] -> IO (Either String LispVal))  -- built-in
  | Closure [String] LispVal Env                           -- lambda
  | Nil                                                    -- empty / void

type Env = MVar [(String, LispVal)]

-- | LispVal2string
showVal :: LispVal -> String
showVal (Atom s)      = s
showVal (Number n)    = show n
showVal (Bool True)   = "#t"
showVal (Bool False)  = "#f"
showVal (Str s)       = "\"" ++ s ++ "\""
showVal (List xs)     = "(" ++ showList' xs ++ ")"
showVal (Func name _) = "<builtin:" ++ name ++ ">"
showVal (Closure ps _ _) = "<lambda:" ++ showList' (map Atom ps) ++ ">"
showVal Nil           = "nil"

showList' :: [LispVal] -> String
showList' []     = ""
showList' [x]    = showVal x
showList' (x:xs) = showVal x ++ " " ++ showList' xs

lispParse :: String -> Either String LispVal
lispParse input = case runParser (spaces *> parseExpr <* spaces) input of
  Just (val, "") -> Right val
  Just (_, rest) -> Left ("Unexpected trailing input: " ++ take 20 rest)
  Nothing        -> Left "Parse error"

-- | Parse multiple top-level S-expressions from a string
lispParseMulti :: String -> Either String [LispVal]
lispParseMulti input = case runParser (spaces *> many (parseExpr <* spaces) <* eof) input of
  Just (vals, _) -> Right vals
  Nothing        -> Left "Parse error"

parseExpr :: Parser LispVal
parseExpr = parseNumber <|> parseBool <|> parseString <|> parseQuote <|> parseList <|> parseAtom

-- | Parse an integer literal
parseNumber :: Parser LispVal
parseNumber = do
    n <- integer
    -- Make sure the number isn't followed by symbol chars
    next <- optional (satisfy isSymbolChar)
    case next of
      Just _  -> empty  -- not a number, backtrack
      Nothing -> return (Number n)

-- | Parse #t or #f
parseBool :: Parser LispVal
parseBool = do
    _ <- char '#'
    c <- satisfy (\c -> c == 't' || c == 'f')
    return (Bool (c == 't'))

-- | Parse a string literal "..."
parseString :: Parser LispVal
parseString = do
    _ <- char '"'
    cs <- many (satisfy (/= '"'))
    _ <- char '"'
    return (Str cs)

-- | Parse 'x as (quote x)
parseQuote :: Parser LispVal
parseQuote = do
    _ <- char '\''
    x <- parseExpr
    return (List [Atom "quote", x])

-- | Parse (expr expr ...)
parseList :: Parser LispVal
parseList = do
    _ <- char '('
    _ <- spaces
    xs <- sepBy parseExpr spaces1
    _ <- spaces
    _ <- char ')'
    return (List xs)

-- | Parse a symbol/atom
parseAtom :: Parser LispVal
parseAtom = do
    first <- satisfy isSymbolStart
    rest  <- many (satisfy isSymbolChar)
    return (Atom (first : rest))

-- | Characters that can start a symbol
isSymbolStart :: Char -> Bool
isSymbolStart c = isAlpha c || c `elem` "+-*/<>=!?_"

-- | Characters that can appear in a symbol (after the first)
isSymbolChar :: Char -> Bool
isSymbolChar c = isAlphaNum c || c `elem` "+-*/<>=!?_->"

-- evaluator

-- | Chain Either results inside IO: eliminates repetitive case-on-Either boilerplate
bindE :: IO (Either String a) -> (a -> IO (Either String b)) -> IO (Either String b)
bindE action f = do
    result <- action
    case result of
      Left err  -> return (Left err)
      Right val -> f val

eval :: Env -> LispVal -> IO (Either String LispVal)

-- Self-evaluating forms
eval _ (Number n)  = return (Right (Number n))
eval _ (Bool b)    = return (Right (Bool b))
eval _ (Str s)     = return (Right (Str s))
eval _ Nil         = return (Right Nil)

-- Variable lookup
eval env (Atom name) = do
    bindings <- readMVar env
    case lookup name bindings of
      Just val -> return (Right val)
      Nothing  -> return (Left ("Unbound variable: " ++ name))

-- Quote
eval _ (List [Atom "quote", val]) = return (Right val)

-- If
eval env (List [Atom "if", cond, conseq, alt]) =
    eval env cond `bindE` \result ->
        case result of
          Bool False -> eval env alt
          _          -> eval env conseq

-- If with no else (returns nil)
eval env (List [Atom "if", cond, conseq]) =
    eval env cond `bindE` \result ->
        case result of
          Bool False -> return (Right Nil)
          _          -> eval env conseq

-- Define variable
eval env (List [Atom "define", Atom name, expr]) =
    eval env expr `bindE` \val -> do
        modifyMVar_ env (\bindings -> return ((name, val) : bindings))
        return (Right Nil)

-- Define function: (define (f params...) body)
eval env (List (Atom "define" : List (Atom f : params) : body)) = do
    let paramNames = map extractName params
    let bodyExpr = case body of
                     [single] -> single
                     multiple -> List (Atom "begin" : multiple)
    let closure = Closure paramNames bodyExpr env
    modifyMVar_ env (\bindings -> return ((f, closure) : bindings))
    return (Right Nil)
  where
    extractName (Atom s) = s
    extractName _        = "_"

-- Lambda
eval env (List [Atom "lambda", List params, body]) = do
    let paramNames = map extractName params
    return (Right (Closure paramNames body env))
  where
    extractName (Atom s) = s
    extractName _        = "_"

-- Let: (let ((x 1) (y 2)) body)
eval env (List [Atom "let", List bindings, body]) = do
    parentBindings <- readMVar env
    evalLetBindings env bindings [] `bindE` \newBinds -> do
        localEnv <- newMVar (newBinds ++ parentBindings)
        eval localEnv body

-- Begin: (begin expr1 expr2 ... exprN) evaluate all, return last
eval env (List (Atom "begin" : exprs)) = evalSequence env exprs

-- Cond: (cond (test1 expr1) (test2 expr2) ... (else exprN))
eval env (List (Atom "cond" : clauses)) = evalCond env clauses

-- Set!: (set! name expr)
eval env (List [Atom "set!", Atom name, expr]) =
    eval env expr `bindE` \val -> do
        bindings <- takeMVar env
        if any (\(k, _) -> k == name) bindings
          then do
            putMVar env (map (\(k, v) -> if k == name then (k, val) else (k, v)) bindings)
            return (Right Nil)
          else do
            putMVar env bindings
            return (Left ("Cannot set! unbound variable: " ++ name))

-- Function application
eval env (List (func : args)) =
    eval env func `bindE` \f ->
        evalArgs env args `bindE` \argVals ->
            apply f argVals

eval _ other = return (Left ("Cannot evaluate: " ++ showVal other))


-- | Evaluate a list of arguments
evalArgs :: Env -> [LispVal] -> IO (Either String [LispVal])
evalArgs env = go []
  where
    go acc []     = return (Right (reverse acc))
    go acc (x:xs) = eval env x `bindE` \val -> go (val : acc) xs

-- | Evaluate a sequence, return the last result
evalSequence :: Env -> [LispVal] -> IO (Either String LispVal)
evalSequence _   []     = return (Right Nil)
evalSequence env [x]    = eval env x
evalSequence env (x:xs) = eval env x `bindE` \_ -> evalSequence env xs

-- | Evaluate let bindings
evalLetBindings :: Env -> [LispVal] -> [(String, LispVal)] -> IO (Either String [(String, LispVal)])
evalLetBindings _   []                          acc = return (Right acc)
evalLetBindings env (List [Atom name, expr] : rest) acc =
    eval env expr `bindE` \val -> evalLetBindings env rest ((name, val) : acc)
evalLetBindings _ _ _ = return (Left "Invalid let binding")

-- | Evaluate cond clauses
evalCond :: Env -> [LispVal] -> IO (Either String LispVal)
evalCond _   [] = return (Right Nil)
evalCond env (List [Atom "else", expr] : _) = eval env expr
evalCond env (List [test, expr] : rest) =
    eval env test `bindE` \result ->
        case result of
          Bool False -> evalCond env rest
          _          -> eval env expr
evalCond _ _ = return (Left "Invalid cond clause")

apply :: LispVal -> [LispVal] -> IO (Either String LispVal)
apply (Func _ f) args = f args
apply (Closure params body closureEnv) args = do
    parentBindings <- readMVar closureEnv
    localEnv <- newMVar (zip params args ++ parentBindings)
    eval localEnv body
apply other _ = return (Left ("Not a function: " ++ showVal other))

defaultEnv :: IO Env
defaultEnv = newMVar
  [ -- Arithmetic
    ("+",       Func "+"       mathAdd)
  , ("-",       Func "-"       mathSub)
  , ("*",       Func "*"       mathMul)
  , ("/",       Func "/"       mathDiv)
  , ("mod",     Func "mod"     mathMod)
    -- Comparison
  , ("=",       Func "="       cmpEq)
  , ("<",       Func "<"       (mkCmp "<" (<)))
  , (">",       Func ">"       (mkCmp ">" (>)))
  , ("<=",      Func "<="      (mkCmp "<=" (<=)))
  , (">=",      Func ">="      (mkCmp ">=" (>=)))
    -- Boolean
  , ("and",     Func "and"     boolAnd)
  , ("or",      Func "or"      boolOr)
  , ("not",     Func "not"     boolNot)
    -- List operations
  , ("car",     Func "car"     listCar)
  , ("cdr",     Func "cdr"     listCdr)
  , ("cons",    Func "cons"    listCons)
  , ("list",    Func "list"    listList)
  , ("null?",   Func "null?"   listNull)
  , ("length",  Func "length"  listLength)
    -- String operations
  , ("string-append", Func "string-append" strAppend)
  , ("string-length", Func "string-length" strLength)
  , ("number->string", Func "number->string" numToStr)
    -- Type predicates
  , ("number?",  Func "number?"  isNumber)
  , ("string?",  Func "string?"  isString)
  , ("list?",    Func "list?"    isList)
  , ("symbol?",  Func "symbol?"  isSymbol)
  , ("boolean?", Func "boolean?" isBoolean)
    -- I/O
  , ("display",  Func "display"  ioDisplay)
  , ("newline",  Func "newline"  ioNewline)
    -- Hardware FFI
  , ("gpio-write", Func "gpio-write" hwGpioWrite)
  , ("gpio-read",  Func "gpio-read"  hwGpioRead)
  , ("delay",      Func "delay"      hwDelay)
  , ("uart-print", Func "uart-print" hwUartPrint)
  ]

mathAdd :: [LispVal] -> IO (Either String LispVal)
mathAdd args = return $ case mapNumbers args of
  Just ns -> Right (Number (sum ns))
  Nothing -> Left "+: expected numbers"

mathSub :: [LispVal] -> IO (Either String LispVal)
mathSub [Number a]          = return (Right (Number (negate a)))
mathSub [Number a, Number b] = return (Right (Number (a - b)))
mathSub args = return $ case mapNumbers args of
  Just (n:ns) -> Right (Number (foldl (-) n ns))
  _           -> Left "-: expected numbers"

mathMul :: [LispVal] -> IO (Either String LispVal)
mathMul args = return $ case mapNumbers args of
  Just ns -> Right (Number (product ns))
  Nothing -> Left "*: expected numbers"

mathDiv :: [LispVal] -> IO (Either String LispVal)
mathDiv [Number _, Number 0] = return (Left "/: division by zero")
mathDiv [Number a, Number b] = return (Right (Number (a `div` b)))
mathDiv _ = return (Left "/: expected two numbers")

mathMod :: [LispVal] -> IO (Either String LispVal)
mathMod [Number _, Number 0] = return (Left "mod: division by zero")
mathMod [Number a, Number b] = return (Right (Number (a `mod` b)))
mathMod _ = return (Left "mod: expected two numbers")

mapNumbers :: [LispVal] -> Maybe [Int]
mapNumbers [] = Just []
mapNumbers (Number n : rest) = case mapNumbers rest of
  Just ns -> Just (n : ns)
  Nothing -> Nothing
mapNumbers _ = Nothing

cmpEq :: [LispVal] -> IO (Either String LispVal)
cmpEq [Number a, Number b] = return (Right (Bool (a == b)))
cmpEq [Str a, Str b]       = return (Right (Bool (a == b)))
cmpEq [Bool a, Bool b]     = return (Right (Bool (a == b)))
cmpEq _                    = return (Left "=: incompatible types")

mkCmp :: String -> (Int -> Int -> Bool) -> [LispVal] -> IO (Either String LispVal)
mkCmp _   op [Number a, Number b] = return (Right (Bool (op a b)))
mkCmp sym _  _                    = return (Left (sym ++ ": expected two numbers"))

boolAnd :: [LispVal] -> IO (Either String LispVal)
boolAnd args = return (Right (Bool (all isTruthy args)))

boolOr :: [LispVal] -> IO (Either String LispVal)
boolOr args = return (Right (Bool (any isTruthy args)))

boolNot :: [LispVal] -> IO (Either String LispVal)
boolNot [arg] = return (Right (Bool (not (isTruthy arg))))
boolNot _     = return (Left "not: expected one argument")

isTruthy :: LispVal -> Bool
isTruthy (Bool False) = False
isTruthy Nil          = False
isTruthy _            = True

listCar :: [LispVal] -> IO (Either String LispVal)
listCar [List (x:_)] = return (Right x)
listCar [List []]     = return (Left "car: empty list")
listCar _             = return (Left "car: expected a list")

listCdr :: [LispVal] -> IO (Either String LispVal)
listCdr [List (_:xs)] = return (Right (List xs))
listCdr [List []]      = return (Left "cdr: empty list")
listCdr _              = return (Left "cdr: expected a list")

listCons :: [LispVal] -> IO (Either String LispVal)
listCons [x, List xs] = return (Right (List (x : xs)))
listCons [x, Nil]     = return (Right (List [x]))
listCons _             = return (Left "cons: expected value and list")

listList :: [LispVal] -> IO (Either String LispVal)
listList args = return (Right (List args))

listNull :: [LispVal] -> IO (Either String LispVal)
listNull [List []] = return (Right (Bool True))
listNull [Nil]     = return (Right (Bool True))
listNull [_]       = return (Right (Bool False))
listNull _         = return (Left "null?: expected one argument")

listLength :: [LispVal] -> IO (Either String LispVal)
listLength [List xs] = return (Right (Number (length xs)))
listLength _         = return (Left "length: expected a list")

strAppend :: [LispVal] -> IO (Either String LispVal)
strAppend args = case mapStrings args of
  Just ss -> return (Right (Str (concat ss)))
  Nothing -> return (Left "string-append: expected strings")

strLength :: [LispVal] -> IO (Either String LispVal)
strLength [Str s] = return (Right (Number (length s)))
strLength _       = return (Left "string-length: expected a string")

numToStr :: [LispVal] -> IO (Either String LispVal)
numToStr [Number n] = return (Right (Str (show n)))
numToStr _          = return (Left "number->string: expected a number")

mapStrings :: [LispVal] -> Maybe [String]
mapStrings [] = Just []
mapStrings (Str s : rest) = case mapStrings rest of
  Just ss -> Just (s : ss)
  Nothing -> Nothing
mapStrings _ = Nothing

isNumber :: [LispVal] -> IO (Either String LispVal)
isNumber [Number _] = return (Right (Bool True))
isNumber [_]        = return (Right (Bool False))
isNumber _          = return (Left "number?: expected one argument")

isString :: [LispVal] -> IO (Either String LispVal)
isString [Str _] = return (Right (Bool True))
isString [_]     = return (Right (Bool False))
isString _       = return (Left "string?: expected one argument")

isList :: [LispVal] -> IO (Either String LispVal)
isList [List _] = return (Right (Bool True))
isList [_]      = return (Right (Bool False))
isList _        = return (Left "list?: expected one argument")

isSymbol :: [LispVal] -> IO (Either String LispVal)
isSymbol [Atom _] = return (Right (Bool True))
isSymbol [_]      = return (Right (Bool False))
isSymbol _        = return (Left "symbol?: expected one argument")

isBoolean :: [LispVal] -> IO (Either String LispVal)
isBoolean [Bool _] = return (Right (Bool True))
isBoolean [_]      = return (Right (Bool False))
isBoolean _        = return (Left "boolean?: expected one argument")

-- i/o primitives

ioDisplay :: [LispVal] -> IO (Either String LispVal)
ioDisplay [val] = do
    case val of
      Str s -> UART.putStr s      -- strings print without quotes
      _     -> UART.putStr (showVal val)
    return (Right Nil)
ioDisplay _ = return (Left "display: expected one argument")

ioNewline :: [LispVal] -> IO (Either String LispVal)
ioNewline [] = do
    UART.putStrLn ""
    return (Right Nil)
ioNewline _ = return (Left "newline: expected no arguments")

-- ffi primitives

-- | (gpio-write pin) set GPIO pin as output and write 0 or 1
hwGpioWrite :: [LispVal] -> IO (Either String LispVal)
hwGpioWrite [Number pin, Number val] = do
    GPIO.rawSetOutput (fromIntegral pin)
    GPIO.rawWrite (fromIntegral pin) (fromIntegral val)
    return (Right Nil)
hwGpioWrite _ = return (Left "gpio-write: expected (gpio-write pin value)")

-- | (gpio-read pin) set GPIO pin as input and read its value
hwGpioRead :: [LispVal] -> IO (Either String LispVal)
hwGpioRead [Number pin] = do
    GPIO.rawSetInput (fromIntegral pin)
    val <- GPIO.rawRead (fromIntegral pin)
    return (Right (Number (fromIntegral val)))
hwGpioRead _ = return (Left "gpio-read: expected (gpio-read pin)")

-- | (delay ms) delay for given milliseconds
hwDelay :: [LispVal] -> IO (Either String LispVal)
hwDelay [Number ms] = do
    Timer.delayMs (fromIntegral ms)
    return (Right Nil)
hwDelay _ = return (Left "delay: expected (delay milliseconds)")

-- | (uart-print str) print string to UART
hwUartPrint :: [LispVal] -> IO (Either String LispVal)
hwUartPrint [Str s] = do
    UART.putStr s
    return (Right Nil)
hwUartPrint [val] = do
    UART.putStr (showVal val)
    return (Right Nil)
hwUartPrint _ = return (Left "uart-print: expected one argument")

-- | Run a Lisp file: parse all expressions, evaluate in sequence
runLispFile :: String -> IO ()
runLispFile contents = do
    env <- defaultEnv
    case lispParseMulti contents of
      Left err -> do
          UART.putStr "Parse error: "
          UART.putStrLn err
      Right exprs -> evalFileExprs env exprs

-- | Evaluate a list of expressions in sequence, printing non-nil results
evalFileExprs :: Env -> [LispVal] -> IO ()
evalFileExprs _ [] = return ()
evalFileExprs env (expr:rest) = do
    result <- eval env expr
    case result of
      Left err -> do
          UART.putStr "Error: "
          UART.putStrLn err
      Right Nil -> evalFileExprs env rest
      Right val -> do
          UART.putStrLn (showVal val)
          evalFileExprs env rest

-- custom repl

runLispRepl :: IO ()
runLispRepl = do
    UART.putStrLn ""
    UART.putStrLn "  HaskellOS Lisp"
    UART.putStrLn "  Type (exit) to return to shell"
    UART.putStrLn ""
    env <- defaultEnv
    replLoop env

replLoop :: Env -> IO ()
replLoop env = do
    UART.putStr "lisp> "
    input <- UART.getLine
    let trimmed = dropWhile isSpace input
    if null trimmed
      then replLoop env
      else if trimmed == "(exit)"
        then UART.putStrLn "Goodbye!"
        else do
          case lispParse trimmed of
            Left err -> do
              UART.putStr "Error: "
              UART.putStrLn err
            Right expr -> do
              result <- eval env expr
              case result of
                Left err -> do
                  UART.putStr "Error: "
                  UART.putStrLn err
                Right Nil -> return ()  -- don't print nil for definitions
                Right val -> UART.putStrLn (showVal val)
          replLoop env
