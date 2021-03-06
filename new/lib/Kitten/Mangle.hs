{-# LANGUAGE OverloadedStrings #-}

module Kitten.Mangle
  ( name
  ) where

import Data.Char (ord, isAsciiLower, isAsciiUpper, isDigit)
import Data.Monoid ((<>))
import Data.Text (Text)
import Kitten.Instantiated (Instantiated(Instantiated))
import Kitten.Name (Qualified(..), Qualifier(..), Unqualified(..))
import Kitten.Type (Constructor(..), Type(..), Var(..))
import qualified Data.Text as Text
import qualified Kitten.Vocabulary as Vocabulary

name :: Instantiated -> Text
name (Instantiated n args) = Text.concat
  -- kitten
  $ ["_K", qualified n]
  ++ if null args
    then []
    else
      -- instantiate
      "_I" : map type_ args
      -- end
      ++ ["_E"]

-- TODO: Use root.
qualified :: Qualified -> Text
qualified (Qualified (Qualifier _root parts) (Unqualified unqualified))
  = Text.concat
    -- nested
    $ "_N" : (map (lengthPrefix . normalize) $ parts ++ [unqualified])
    -- end
    ++ ["_E"]

lengthPrefix :: Text -> Text
lengthPrefix t = Text.pack (show (Text.length t)) <> t

normalize :: Text -> Text
normalize = Text.concatMap go
  where
  go :: Char -> Text
  go c = case c of
    '@'  -> "_a"  -- at
    '\\' -> "_b"  -- backslash
    '^'  -> "_c"  -- circumflex
    '.'  -> "_d"  -- dot
    '='  -> "_e"  -- equal
    '/'  -> "_f"  -- fraction
    '>'  -> "_g"  -- greater
    '#'  -> "_h"  -- hash
         -- "_i"
         -- "_j"
         -- "_k"
    '<'  -> "_l"  -- less
    '-'  -> "_m"  -- minus
    '&'  -> "_n"  -- and ('n')
         -- "_o"
    '+'  -> "_p"  -- plus
    '?'  -> "_q"  -- question
    '%'  -> "_r"  -- remainder
    '*'  -> "_s"  -- star (asterisk)
    '~'  -> "_t"  -- tilde
         -- "_u"
    '|'  -> "_v"  -- vertical bar
         -- "_w"
    '!'  -> "_x"  -- exclamation
         -- "_y"
         -- "_z"
    '_'  -> "__"  -- underscore

    _
      | isDigit c || isAsciiLower c || isAsciiUpper c
        -> Text.singleton c
      | otherwise -> Text.concat
        -- unicode
        ["_U", Text.pack $ show $ ord c, "_"]

type_ :: Type -> Text
type_ t = case t of
  a :@ b -> Text.concat
    -- apply
    ["_A", type_ a, type_ b]
  TypeConstructor _ (Constructor constructor)
    | qualifierName constructor == Vocabulary.global
    -> case unqualifiedName constructor of
      "Bool" -> "_B"  -- bool
      "Char" -> "_C"  -- char
      "Float32" -> "_F4"  -- float
      "Float64" -> "_F8"
      "Int8" -> "_I1"  -- integer
      "Int16" -> "_I2"
      "Int32" -> "_I4"
      "Int64" -> "_I8"
      "List" -> "_L"  -- list
      "UInt8" -> "_U1"  -- unsigned
      "UInt16" -> "_U2"
      "UInt32" -> "_U4"
      "UInt64" -> "_U8"
      _ -> qualified constructor
    | otherwise
    -> qualified constructor
  TypeVar _ (Var n _)
    -- variable
    -> Text.concat ["_V", Text.pack $ show n]
  TypeValue{} -> error "TODO: mangle type value"
  TypeConstant _ (Var n _)
    -- constant
    -> Text.concat ["_K", Text.pack $ show n]
  Forall _ (Var n _) t'
    -- quantified
    -> Text.concat ["_Q", Text.pack $ show n, type_ t', "_E"]
