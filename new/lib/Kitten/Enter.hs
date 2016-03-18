{-# LANGUAGE OverloadedStrings #-}

module Kitten.Enter
  ( fragment
  , fragmentFromSource
  ) where

import Control.Monad ((>=>))
import Data.Foldable (foldlM)
import Data.Text (Text)
import Kitten.Declaration (Declaration)
import Kitten.Definition (Definition)
import Kitten.Dictionary (Dictionary)
import Kitten.Fragment (Fragment)
import Kitten.Infer (mangleInstance, typecheck)
import Kitten.Informer (checkpoint, report)
import Kitten.Layout (layout)
import Kitten.Metadata (Metadata)
import Kitten.Monad (K)
import Kitten.Name
import Kitten.Scope (scope)
import Kitten.Term (Term)
import Kitten.Tokenize (tokenize)
import Kitten.TypeDefinition (TypeDefinition)
import qualified Data.HashMap.Strict as HashMap
import qualified Kitten.Declaration as Declaration
import qualified Kitten.Definition as Definition
import qualified Kitten.Desugar.Data as Data
import qualified Kitten.Desugar.Infix as Infix
import qualified Kitten.Desugar.Quotations as Quotations
import qualified Kitten.Dictionary as Dictionary
import qualified Kitten.Entry as Entry
import qualified Kitten.Entry.Category as Category
import qualified Kitten.Entry.Merge as Merge
import qualified Kitten.Entry.Parent as Parent
import qualified Kitten.Fragment as Fragment
import qualified Kitten.Metadata as Metadata
import qualified Kitten.Origin as Origin
import qualified Kitten.Parse as Parse
import qualified Kitten.Pretty as Pretty
import qualified Kitten.Report as Report
import qualified Kitten.Resolve as Resolve
import qualified Kitten.Signature as Signature
import qualified Kitten.Term as Term
import qualified Kitten.TypeDefinition as TypeDefinition
import qualified Text.PrettyPrint as Pretty

fragment :: Fragment () -> Dictionary -> K Dictionary
fragment f
  -- TODO: Link constructors to parent type.
  = foldlMx declareType (Fragment.types f)
  >=> foldlMx enterDeclaration (Fragment.declarations f)
  >=> foldlMx declareWord (Fragment.definitions f)
  >=> foldlMx resolveSignature
    (map Definition.name (Fragment.definitions f)
      ++ map Declaration.name (Fragment.declarations f))
  >=> foldlMx addMetadata (Fragment.metadata f)
  >=> foldlMx defineWord (Fragment.definitions f)
  where
  foldlMx :: (Foldable f, Monad m) => (b -> a -> m b) -> f a -> b -> m b
  foldlMx = flip . foldlM

enterDeclaration :: Dictionary -> Declaration -> K Dictionary
enterDeclaration dictionary declaration = do
  let
    name = Declaration.name declaration
    signature = Declaration.signature declaration
    origin = Declaration.origin declaration
  case Dictionary.lookup name dictionary of
    Just _existing -> do
      -- TODO: Check signatures.
      return dictionary
    Nothing -> case Declaration.category declaration of
      Declaration.Intrinsic -> do
        let
          entry = Entry.Word
            Category.Word
            Merge.Deny
            origin
            Nothing
            (Just signature)
            Nothing
        return $ Dictionary.insert name entry dictionary
      Declaration.Trait -> do
        let entry = Entry.Trait origin signature
        return $ Dictionary.insert name entry dictionary

-- declare type, declare & define constructors
declareType :: Dictionary -> TypeDefinition -> K Dictionary
declareType dictionary type_ = let
  name = TypeDefinition.name type_
  in case Dictionary.lookup name dictionary of
    -- Not previously declared.
    Nothing -> do
      let
        entry = Entry.Type
          (TypeDefinition.origin type_)
          (TypeDefinition.parameters type_)
      return $ Dictionary.insert name entry dictionary
    -- Previously declared with the same parameters.
    Just (Entry.Type _ parameters)
      | parameters == TypeDefinition.parameters type_
      -> return dictionary
    -- Already declared or defined differently.
    Just{} -> error $ Pretty.render $ Pretty.hsep
      [ "type"
      , Pretty.quote name
      , "already declared or defined differently"
      ]

declareWord
  :: Dictionary -> Definition () -> K Dictionary
declareWord dictionary definition = let
  name = Definition.name definition
  signature = Definition.signature definition
  in case Dictionary.lookup name dictionary of
    -- Not previously declared or defined.
    Nothing -> do
      let
        entry = Entry.Word
          (Definition.category definition)
          (Definition.merge definition)
          (Definition.origin definition)
          Nothing
          (Just signature)
          Nothing
      return $ Dictionary.insert name entry dictionary
    -- Already declared with the same signature.
    Just (Entry.Word _ _ originalOrigin _ (Just signature') _)
      | Definition.inferSignature definition || signature' == signature
      -> return dictionary
      | otherwise
      -> do
         report $ Report.WordRedeclaration (Signature.origin signature)
           name signature (Signature.origin signature') signature'
         return dictionary
    -- Already declared or defined as a trait.
    Just (Entry.Trait _origin traitSignature)
      -- TODO: Better error reporting when a non-instance matches a trait.
      | Definition.category definition == Category.Instance
      -> do
      let qualifier = qualifierName name
      resolvedSignature <- Resolve.run $ Resolve.signature
        dictionary qualifier $ Definition.signature definition
      mangledName <- mangleInstance dictionary
        (Definition.name definition)
        resolvedSignature traitSignature
      let
        entry = Entry.Word
          (Definition.category definition)
          (Definition.merge definition)
          (Definition.origin definition)
          (Just (Parent.Trait name))
          (Just resolvedSignature)
          Nothing
      return $ Dictionary.insert mangledName entry dictionary
    -- Already declared or defined with a different signature.
    Just{} -> error $ Pretty.render $ Pretty.hsep
      [ "word"
      , Pretty.quote name
      , "already declared or defined without signature or as a non-word"
      ]

addMetadata :: Dictionary -> Metadata -> K Dictionary
addMetadata dictionary0 metadata = do
  dictionary <- foldlM addField dictionary0 $ HashMap.toList $ Metadata.fields metadata
  return dictionary
  where
  QualifiedName qualified = Metadata.name metadata
  origin = Metadata.origin metadata
  qualifier = qualifierFromName qualified

  addField :: Dictionary -> (Unqualified, Term ()) -> K Dictionary
  addField dictionary (unqualified, term) = do
    let name = Qualified qualifier unqualified
    case Dictionary.lookup name dictionary of
      Just{} -> return dictionary  -- TODO: Report duplicates or merge?
      Nothing -> return
        $ Dictionary.insert name (Entry.Metadata origin term) dictionary

resolveSignature :: Dictionary -> Qualified -> K Dictionary
resolveSignature dictionary name = do
  let qualifier = qualifierName name
  case Dictionary.lookup name dictionary of
    Just (Entry.Word category merge origin parent (Just signature) body) -> do
      signature' <- Resolve.run $ Resolve.signature dictionary qualifier signature
      let
        entry = Entry.Word category merge origin parent (Just signature') body
      return $ Dictionary.insert name entry dictionary
    Just (Entry.Trait origin signature) -> do
      signature' <- Resolve.run $ Resolve.signature dictionary qualifier signature
      let entry = Entry.Trait origin signature'
      return $ Dictionary.insert name entry dictionary
    _ -> return dictionary

-- typecheck and define user-defined words
-- desugaring of operators has to take place here
defineWord
  :: Dictionary
  -> Definition ()
  -> K Dictionary
defineWord dictionary definition = do
  let name = Definition.name definition
  resolved <- resolveAndDesugar dictionary definition
  checkpoint
  let resolvedSignature = Definition.signature resolved
  -- Note that we use the resolved signature here.
  (typecheckedBody, type_) <- typecheck dictionary
    (Just resolvedSignature)
    $ Definition.body resolved
  checkpoint
  case Dictionary.lookup name dictionary of
    -- Already declared or defined as a trait.
    Just (Entry.Trait _origin traitSignature)
      | Definition.category definition == Category.Instance
      -> do
      mangledName <- mangleInstance dictionary name
        resolvedSignature traitSignature
      -- Should this use the mangled name?
      (flattenedBody, quotations) <- Quotations.desugar
        (qualifierFromName name) typecheckedBody
      let
        entry = Entry.Word
          (Definition.category definition)
          (Definition.merge definition)
          (Definition.origin definition)
          (Just (Parent.Trait name))
          (Just resolvedSignature)
          (Just flattenedBody)
        entries = map
          (\ ((quotationName, quotationType), quotationBody)
            -> (quotationName, Entry.Word
              Category.Word
              Merge.Deny
              (Term.origin quotationBody)
              Nothing
              (Just (Signature.Type quotationType))
              (Just quotationBody)))
          quotations
      return $ foldr
        (\ (quotationName, quotationEntry)
          -> Dictionary.insert quotationName quotationEntry)
        (Dictionary.insert mangledName entry dictionary)
        entries
    -- Previously declared with same signature, but not defined.
    Just (Entry.Word category merge origin' parent signature' Nothing)
      | maybe True (resolvedSignature ==) signature' -> do
      (flattenedBody, quotations) <- Quotations.desugar
        (qualifierFromName name) typecheckedBody
      let
        entry = Entry.Word
          category merge origin' parent
          (Just $ if Definition.inferSignature definition
            then Signature.Type type_
            else resolvedSignature) (Just flattenedBody)
        entries = map
          (\ ((quotationName, quotationType), quotationBody)
            -> (quotationName, Entry.Word
              Category.Word
              Merge.Deny
              (Term.origin quotationBody)
              Nothing
              (Just (Signature.Type quotationType))
              (Just quotationBody)))
          quotations
      return $ foldr
        (\ (quotationName, quotationEntry)
          -> Dictionary.insert quotationName quotationEntry)
        (Dictionary.insert name entry dictionary)
        entries
    -- Already defined as concatenable.
    Just (Entry.Word category merge@Merge.Compose
      origin' parent mSignature@(Just signature') body)
      | Definition.inferSignature definition
        || resolvedSignature == signature' -> do
      let
        strippedBody = maybe (Term.Identity () (Origin.point "<implicit>" 1 1))
          Term.stripMetadata body
      (composed, composedType) <- typecheck dictionary
        (if Definition.inferSignature definition
          then Nothing
          else Just resolvedSignature)
        $ Term.Compose () strippedBody $ Definition.body resolved
      (flattenedBody, quotations) <- Quotations.desugar
        (qualifierFromName name) composed
      let
        entry = Entry.Word category merge origin' parent
          (if Definition.inferSignature definition
            then Just (Signature.Type composedType)
            else mSignature)
          $ Just flattenedBody
        entries = map
          (\ ((quotationName, quotationType), quotationBody)
            -> (quotationName, Entry.Word
              Category.Word
              Merge.Deny
              (Term.origin quotationBody)
              Nothing
              (Just (Signature.Type quotationType))
              (Just quotationBody)))
          quotations
      return $ foldr
        (\ (quotationName, quotationEntry)
          -> Dictionary.insert quotationName quotationEntry)
        (Dictionary.insert name entry dictionary)
        entries
    -- Already defined, not concatenable.
    Just (Entry.Word _ Merge.Deny originalOrigin _ (Just sig) _) -> do
      report $ Report.WordRedefinition (Definition.origin definition)
        name originalOrigin
      return dictionary
    -- Not previously declared as word.
    _ -> error $ Pretty.render $ Pretty.hsep
      [ "defining word"
      , Pretty.quote name
      , "not previously declared"
      ]

fragmentFromSource
  :: [GeneralName]
  -> Maybe Qualified
  -> Int
  -> FilePath
  -> Text
  -> K (Fragment ())
fragmentFromSource mainPermissions mainName line path source = do

-- Sources are lexed into a stream of tokens.

  tokenized <- tokenize line path source
  checkpoint

-- Next, the layout rule is applied to desugar indentation-based syntax, so that
-- the parser can find the ends of blocks without checking the indentation of
-- tokens.

  laidout <- layout path tokenized
  checkpoint

-- We then parse the token stream as a series of top-level program elements.

  parsed <- Parse.program line path mainPermissions mainName laidout
  checkpoint

-- Datatype definitions are desugared into regular definitions, so that name
-- resolution can find their names.

  Data.desugar parsed

resolveAndDesugar :: Dictionary -> Definition () -> K (Definition ())
resolveAndDesugar dictionary definition = do

-- Name resolution rewrites unqualified names into fully qualified names, so
-- that it's evident from a name which program element it refers to.

  -- needs dictionary for declared names
  resolved <- Resolve.run $ Resolve.definition dictionary definition
  checkpoint

-- After names have been resolved, the precedences of operators are known, so
-- infix operators can be desugared into postfix syntax.

  -- needs dictionary for operator metadata
  postfix <- Infix.desugar dictionary resolved
  checkpoint

-- In addition, now that we know which names refer to local variables,
-- quotations can be rewritten into closures that explicitly capture the
-- variables they use from the enclosing scope.

  return $ postfix { Definition.body = scope $ Definition.body postfix }
