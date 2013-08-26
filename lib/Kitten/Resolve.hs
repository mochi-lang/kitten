{-# LANGUAGE OverloadedStrings #-}

module Kitten.Resolve
  ( resolve
  ) where

import Control.Applicative hiding (some)
import Data.Text (Text)
import Data.Vector (Vector)

import qualified Data.Text as T
import qualified Data.Vector as V

import Kitten.Def
import Kitten.Error
import Kitten.Fragment
import Kitten.Location
import Kitten.Name
import Kitten.Resolve.Monad
import Kitten.Resolved
import Kitten.Term (Term)

import qualified Kitten.Resolved as Resolved
import qualified Kitten.Term as Term

resolve
  :: Fragment Resolved.Value Resolved
  -> Fragment Term.Value Term
  -> Either [CompileError] (Fragment Value Resolved)
resolve prelude fragment
  = evalResolution emptyEnv
  $ guardLiftM2 (\ defs terms -> fragment
    { fragmentDefs = defs
    , fragmentTerms = terms
    })
    (resolveDefs (fragmentDefs fragment))
    (resolveTerms $ V.toList (fragmentTerms fragment))
  where
  emptyEnv = Env
    (fragmentDefs prelude)
    (fragmentDefs fragment)
    []

resolveDefs :: Vector (Def Term.Value) -> Resolution (Vector (Def Value))
resolveDefs = guardMapM resolveDef
  where
  resolveDef :: Def Term.Value -> Resolution (Def Value)
  resolveDef def = do
    defTerm' <- resolveValue (defTerm def)
    return def { defTerm = defTerm' }

resolveTerm :: Term -> Resolution Resolved
resolveTerm term = V.head <$> resolveTerms [term]

resolveTerms :: [Term] -> Resolution (Vector Resolved)
resolveTerms [] = return V.empty
resolveTerms (unresolved:rest)
  = V.cons <$> go <*> resolveTerms rest
  where
  go = case unresolved of
    Term.Builtin name loc -> return $ Builtin name loc
    Term.Call name loc -> resolveName name loc
    Term.ChoiceTerm left right loc -> ChoiceTerm
      <$> resolveTerm left
      <*> resolveTerm right
      <*> pure loc
    Term.Compose terms loc -> Compose
      <$> resolveTerms (V.toList terms)
      <*> pure loc
    Term.From name loc -> return $ From name loc
    Term.Group terms loc -> Group
      <$> resolveTerms (V.toList terms)
      <*> pure loc
    Term.If true false loc -> If
      <$> resolveTerm true
      <*> resolveTerm false
      <*> pure loc
    Term.Lambda name term loc -> withLocal name $ Scoped
      <$> resolveTerm term
      <*> pure loc
    Term.OptionTerm some none loc -> OptionTerm
      <$> resolveTerm some
      <*> resolveTerm none
      <*> pure loc
    Term.PairTerm as bs loc -> PairTerm
      <$> resolveTerm as
      <*> resolveTerm bs
      <*> pure loc
    Term.Push value loc -> Push <$> resolveValue value <*> pure loc
    Term.To name loc -> return $ To name loc
    Term.VectorTerm items loc -> VectorTerm
      <$> guardMapM resolveTerm items
      <*> pure loc

resolveValue :: Term.Value -> Resolution Value
resolveValue unresolved = case unresolved of
  Term.Bool value _ -> return $ Bool value
  Term.Char value _ -> return $ Char value
  Term.Choice which value _ -> Choice which <$> resolveValue value
  Term.Float value _ -> return $ Float value
  Term.Function terms loc -> fmap Function $ Compose
    <$> resolveTerms (V.toList terms)
    <*> pure loc
  Term.Int value _ -> return $ Int value
  Term.Option mValue _ -> case mValue of
    Just value -> Option . Just <$> resolveValue value
    Nothing -> pure (Option Nothing)
  Term.Pair a b _ -> do
    a' <- resolveValue a
    b' <- resolveValue b
    return $ Pair a' b'
  Term.Unit _ -> return Unit
  Term.Vector values _ -> Vector <$> resolveVector values
  where
  resolveVector = guardMapM resolveValue

resolveName
  :: Text
  -> Location
  -> Resolution Resolved
resolveName name loc = do
  mLocalIndex <- getsEnv $ localIndex name
  case mLocalIndex of
    Just index -> return $ Push (Local $ Name index) loc
    Nothing -> do
      indices <- getsEnv $ defIndices name
      index <- case V.toList indices of
        [index] -> return index
        [] -> compileError . CompileError loc $ T.unwords
          ["undefined word:", name]
        _ -> compileError . CompileError loc $ T.unwords
          ["ambiguous word:", name]
      return $ Call (Name index) loc
