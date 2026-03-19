{- HLINT ignore "Use lambda-case" -}
-- | Parse.hs - Parser combinator library for Lisp.hs/Shell.hs
--              most of these ideas were covered in 242!
--
-- note haskell wants you to use \case but mhs doesn't support it

module Parse
  ( -- * Parser type
    Parser(..)
    -- * Running parsers
  , parse
    -- * Primitives
  , satisfy, char, string, digit, space, spaces, eof
    -- * Combinators
  , many1, choice, sepBy, between, optional, spaces1, word, rest
    -- * Numbers
  , natural, integer
  ) where

import Data.Char (isDigit, isSpace, digitToInt)
import Data.Foldable (asum)
import Data.Functor (($>))
import Control.Monad (void)
import Control.Applicative (Alternative(..))

-- | A parser consumes a String and produces Maybe (result, remaining).
newtype Parser a = Parser { runParser :: String -> Maybe (a, String) }

-- Functor: transform the result of a successful parse
instance Functor Parser where
  fmap f (Parser p) = Parser $ \s -> case p s of
    Nothing      -> Nothing
    Just (a, s') -> Just (f a, s')

-- Applicative: sequence two parsers, combining results
instance Applicative Parser where
  pure a = Parser $ \s -> Just (a, s)
  (Parser pf) <*> (Parser pa) = Parser $ \s -> case pf s of
    Nothing      -> Nothing
    Just (f, s') -> case pa s' of
      Nothing       -> Nothing
      Just (a, s'') -> Just (f a, s'')

-- Monad: sequence parsers where the second depends on the first's result
instance Monad Parser where
  return = pure
  (Parser pa) >>= f = Parser $ \s -> case pa s of
    Nothing      -> Nothing
    Just (a, s') -> runParser (f a) s'

-- Alternative: try one parser, fall back to another on failure
instance Alternative Parser where
  empty = Parser $ const Nothing
  (Parser p1) <|> (Parser p2) = Parser $ \s ->
    case p1 s of
      Just r  -> Just r
      Nothing -> p2 s

-- | Run a parser and require all input to be consumed
parse :: Parser a -> String -> Maybe a
parse p s = case runParser p s of
  Just (a, "") -> Just a
  _            -> Nothing

-- | Parse a character satisfying a predicate
satisfy :: (Char -> Bool) -> Parser Char
satisfy pred = Parser $ \s -> case s of
  (c:cs) | pred c -> Just (c, cs)
  _               -> Nothing

-- | Parse a specific character
char :: Char -> Parser Char
char c = satisfy (== c)

-- | Parse a specific string
string :: String -> Parser String
string []     = pure []
string (c:cs) = (char c *> string cs) $> (c:cs)

-- | Parse a digit character
digit :: Parser Char
digit = satisfy isDigit

-- | Parse a whitespace character
space :: Parser Char
space = satisfy isSpace

-- | Skip zero or more spaces
spaces :: Parser ()
spaces = void (many space)

-- | Succeed only at end of input
eof :: Parser ()
eof = Parser $ \s -> case s of
  [] -> Just ((), [])
  _  -> Nothing

-- | Parse one or more occurrences
many1 :: Parser a -> Parser [a]
many1 p = (:) <$> p <*> many p

-- | Try each parser in order, return first success
choice :: [Parser a] -> Parser a
choice = asum -- foldr (<|>) empty, first time ive seen this function

-- | Parse zero or more separated by sep
sepBy :: Parser a -> Parser sep -> Parser [a]
sepBy p sep = sepBy1 p sep <|> pure []

-- | Parse one or more separated by sep
sepBy1 :: Parser a -> Parser sep -> Parser [a]
sepBy1 p sep = (:) <$> p <*> many (sep >> p)

-- | Parse between open and close delimiters
between :: Parser open -> Parser close -> Parser a -> Parser a
between open close p = open *> p <* close

-- | Optionally parse, returning Maybe
optional :: Parser a -> Parser (Maybe a)
optional p = (Just <$> p) <|> pure Nothing

-- | Skip one or more whitespace characters
spaces1 :: Parser ()
spaces1 = void (many1 space)

-- | Parse a non-whitespace token
word :: Parser String
word = many1 (satisfy (not . isSpace))

-- | Consume all remaining input
rest :: Parser String
rest = many (satisfy (const True))

-- | Parse a natural number
natural :: Parser Int
natural = fmap (foldl (\acc d -> acc * 10 + digitToInt d) 0) (many1 digit)

-- | Parse an integer
integer :: Parser Int
integer = do
    sign <- optional (char '-')
    n <- natural
    return $ case sign of
      Just _  -> negate n
      Nothing -> n
