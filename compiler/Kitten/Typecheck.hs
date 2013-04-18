{-# LANGUAGE GADTs #-}
{-# LANGUAGE RecordWildCards #-}

module Kitten.Typecheck
  ( typecheck
  ) where

import Control.Monad
import Control.Monad.Trans.Class
import Control.Monad.Trans.State

import Kitten.Builtin (Builtin)
import Kitten.Def
import Kitten.Error
import Kitten.Fragment
import Kitten.Name
import Kitten.Resolve (Resolved(..), Value(..))
import Kitten.Type
import Kitten.Util.List

import qualified Kitten.Builtin as Builtin

data Env = Env
  { envData :: [Type Scalar]
  , envLocals :: [Type Scalar]
  , envDefs :: [Def Resolved]
  }

type TypecheckM a = StateT Env (Either CompileError) a
type Typecheck = TypecheckM ()

typecheck
  :: [Def Resolved]
  -> [Value]
  -> Fragment Resolved
  -> Either CompileError ()
typecheck _prelude stack Fragment{..} = evalStateT
  (mapM_ typecheckValue stack >> typecheckTerm fragmentTerm)
  (Env [] [] fragmentDefs)

typecheckTerm :: Resolved -> Typecheck
typecheckTerm resolved = case resolved of
  Value value -> typecheckValue value
  Builtin builtin -> typecheckBuiltin builtin
  Scoped term -> do
    pushLocal =<< popData
    typecheckTerm term
  Local (Name _name) -> compileError "TODO typecheck local"
  Compose terms -> mapM_ typecheckTerm terms

typecheckValue :: Value -> Typecheck
typecheckValue value = case value of
  Word (Name index) -> do
    mDef <- gets $ (!? index) . envDefs
    case mDef of
      Nothing -> compileError $ "Internal name resolution error"
      Just (Def _ term) -> typecheckTerm term
  Int _ -> pushData IntType
  Bool _ -> pushData BoolType
  Text _ -> pushData TextType
  Vec [] -> do
    pushData $ VecType (ScalarVar (Name 0))
  Vec (v : _) -> do
    typecheckValue v
    -- FIXME Check remaining vector values.
    a <- popData
    pushData $ VecType a
  Tuple _values -> compileError "TODO typecheck tuple"
  Fun term -> do
    before <- get
    typecheckTerm term
    after <- get
    let
      stackBefore = envData before
      stackAfter = envData after
      (consumption, production)
        = stripCommonPrefix (reverse stackBefore) (reverse stackAfter)
    put before
    pushData
      $ Composition (reverse consumption)
      :> Composition (reverse production)

typecheckBuiltin :: Builtin -> Typecheck
typecheckBuiltin builtin = case builtin of
  Builtin.Add -> intsToInt

  Builtin.AndBool -> boolsToBool

  Builtin.AndInt -> intsToInt

  Builtin.Apply -> do
    -- FIXME Make total.
    (Composition consumption :> Composition production)
      <- popDataExpecting $ RowVar (Name 0) :> RowVar (Name 1)
    mapM_ popDataExpecting_ consumption
    mapM_ pushData production

  Builtin.At -> do
    popDataExpecting_ IntType
    VecType a <- popDataExpecting $ VecType (ScalarVar (Name 0))
    pushData a

  Builtin.Bottom -> do
    VecType a <- popDataExpecting $ VecType (ScalarVar (Name 0))
    pushData a

  Builtin.Cat -> do
    VecType b <- popDataExpecting $ VecType (ScalarVar (Name 0))
    VecType a <- popDataExpecting $ VecType (ScalarVar (Name 0))
    if a == b
      then pushData $ VecType a
      else compileError $ concat
        [ "Mismatched element types "
        , show a
        , " and "
        , show b
        , " in 'cat' arguments"
        ]

  Builtin.Compose -> do
    Composition c :> Composition d
      <- popDataExpecting $ RowVar (Name 0) :> RowVar (Name 1)
    Composition a :> Composition b
      <- popDataExpecting $ RowVar (Name 0) :> RowVar (Name 1)
    before <- get
    mapM_ popDataExpecting a
    mapM_ pushData b
    mapM_ popDataExpecting c
    mapM_ pushData d
    after <- get
    put before
    let
      stackBefore = envData before
      stackAfter = envData after
      (consumption, production)
        = stripCommonPrefix (reverse stackBefore) (reverse stackAfter)
    pushData
      $ Composition (reverse consumption)
      :> Composition (reverse production)

  Builtin.Div -> intsToInt

  Builtin.Down -> do
    a <- popDataExpecting $ VecType (ScalarVar (Name 0))
    pushData a

  Builtin.Drop -> popData_

  Builtin.Dup -> do
    a <- popData
    pushData a
    pushData a

  Builtin.Eq -> intsToBool

  Builtin.Empty -> do
    popDataExpecting_ $ VecType (ScalarVar (Name 0))
    pushData BoolType

  Builtin.Fun -> do
    a <- popData
    pushData $ Composition [] :> Composition [a]

  Builtin.Ge -> intsToBool

  Builtin.Gt -> intsToBool

  Builtin.If -> do
    popDataExpecting_ BoolType
    b <- popDataExpecting (RowVar (Name 0) :> RowVar (Name 1))
    -- FIXME Unsafe.
    a@(_ :> Composition production) <- popDataExpecting
      $ RowVar (Name 0) :> RowVar (Name 1)
    if a == b
      then mapM_ pushData production
      else compileError $ "Mismatched types in 'if' branches"

  Builtin.Le -> intsToBool

  Builtin.Length -> do
    popDataExpecting_ $ VecType (ScalarVar (Name 0))
    pushData IntType

  Builtin.Lt -> intsToBool

  Builtin.Mod -> intsToInt

  Builtin.Mul -> intsToInt

  Builtin.Ne -> intsToBool

  Builtin.Neg -> intToInt

  Builtin.NotBool -> boolToBool

  Builtin.NotInt -> intToInt

  Builtin.OrBool -> boolsToBool

  Builtin.OrInt -> intsToInt

  Builtin.Print -> popDataExpecting_ TextType

  Builtin.Sub -> intsToInt

  Builtin.Swap -> do
    a <- popData
    b <- popData
    pushData a
    pushData b

  Builtin.Top -> do
    VecType a <- popDataExpecting $ VecType (ScalarVar (Name 0))
    pushData a

  Builtin.Up -> do
    a <- popDataExpecting $ VecType (ScalarVar (Name 0))
    pushData a

  Builtin.Vec -> do
    a <- popData
    pushData $ VecType a

  Builtin.XorBool -> boolsToBool

  Builtin.XorInt -> intsToInt

  where

  boolToBool = do
    popDataExpecting_ BoolType
    pushData BoolType

  boolsToBool = do
    popDataExpecting_ BoolType
    popDataExpecting_ BoolType
    pushData BoolType

  intToInt = do
    popDataExpecting_ IntType
    pushData IntType

  intsToInt = do
    popDataExpecting_ IntType
    popDataExpecting_ IntType
    pushData IntType

  intsToBool = do
    popDataExpecting_ IntType
    popDataExpecting_ IntType
    pushData BoolType

compileError :: String -> TypecheckM a
compileError = lift . Left . CompileError

popData_ :: Typecheck
popData_ = void popData

popData :: TypecheckM (Type Scalar)
popData = do
  dataStack <- gets envData
  case dataStack of
    [] -> compileError "expecting type but got empty stack"
    (top : down) -> do
      modify $ \ env -> env { envData = down }
      return top

popDataExpecting_ :: Type Scalar -> Typecheck
popDataExpecting_ = void . popDataExpecting

popDataExpecting :: Type Scalar -> TypecheckM (Type Scalar)
popDataExpecting type_ = do
  dataStack <- gets envData
  case dataStack of
    [] -> compileError $ unwords
      ["expecting", show type_, "but got empty stack"]
    (top : down) -> do
      modify $ \ env -> env { envData = down }
      unless (top `instanceOf` type_) . compileError $ unwords
        ["expecting", show type_, "but got", show top]
      return top

pushData :: Type Scalar -> Typecheck
pushData type_ = modify $ \ env@Env{..}
  -> env { envData = type_ : envData }

pushLocal :: Type Scalar -> Typecheck
pushLocal type_ = modify $ \ env@Env{..}
  -> env { envLocals = type_ : envLocals }
