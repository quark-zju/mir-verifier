{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE PartialTypeSignatures #-}

-- See: https://ghc.haskell.org/trac/ghc/ticket/11581
{-# LANGUAGE UndecidableInstances #-}

{-# OPTIONS_GHC -Wincomplete-patterns -Wall #-}
{-# OPTIONS_GHC -fno-warn-incomplete-patterns -fno-warn-unused-imports #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Mir.Intrinsics
  {-
( -- * Internal implementation types
  MirReferenceSymbol
, MirReferenceType
, pattern MirReferenceRepr
, MirReference(..)
, MirReferencePath(..)
, muxRefPath
, muxRef
, TaggedUnion
, MirSlice
, pattern MirSliceRepr
  -- * Translation-specific types
, VarMap
, VarInfo (..)
, varInfoRepr
, LabelMap
, AdtMap
, TraitMap (..)
, TraitImpls (..)
, vtableTyRepr
, methodIndex
, vtables
, traitImpls
, FnState (..)
, MirExp (..)
, MirHandle (..)
, HandleMap
, varMap
, labelMap
, adtMap
, handleMap
, traitMap
, MirValue(..)
, valueToExpr
  , getTraitImplementation  
  -- * MIR Syntax extension
, MIR
, MirStmt(..)
, mirExtImpl
) -} where

import           GHC.TypeLits
import           Control.Lens hiding (Empty, (:>), Index, view)
import           Control.Monad
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Maybe
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import           Data.Map.Strict(Map)
import qualified Data.Map.Strict as Map
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.String

import qualified Text.Regex as Regex
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import           Data.Parameterized.Classes
import           Data.Parameterized.Context
import           Data.Parameterized.TraversableFC
import qualified Data.Parameterized.TH.GADT as U

import           Lang.Crucible.Backend
import           Lang.Crucible.CFG.Expr
--import           Lang.Crucible.CFG.Extension
import           Lang.Crucible.CFG.Generator hiding (dropRef)
import           Lang.Crucible.FunctionHandle
import           Lang.Crucible.Types
import           Lang.Crucible.Simulator.ExecutionTree hiding (FnState)
import           Lang.Crucible.Simulator.Evaluation
import           Lang.Crucible.Simulator.GlobalState
import           Lang.Crucible.Simulator.Intrinsics
import           Lang.Crucible.Simulator.RegValue
import           Lang.Crucible.Simulator.RegMap
import           Lang.Crucible.Simulator.SimError

import           What4.Interface
import           What4.Utils.MonadST

import           Mir.Mir

--import           Debug.Trace

type MirReferenceSymbol = "MirReference"
type MirReferenceType tp = IntrinsicType MirReferenceSymbol (EmptyCtx ::> tp)

pattern MirReferenceRepr :: () => tp' ~ MirReferenceType tp => TypeRepr tp -> TypeRepr tp'
pattern MirReferenceRepr tp <-
     IntrinsicRepr (testEquality (knownSymbol @MirReferenceSymbol) -> Just Refl) (Empty :> tp)
 where MirReferenceRepr tp = IntrinsicRepr (knownSymbol @MirReferenceSymbol) (Empty :> tp)

type family MirReferenceFam (sym :: *) (ctx :: Ctx CrucibleType) :: * where
  MirReferenceFam sym (EmptyCtx ::> tp) = MirReference sym tp
  MirReferenceFam sym ctx = TypeError ('Text "MirRefeence expects a single argument, but was given" ':<>:
                                       'ShowType ctx)
instance IsExprBuilder sym => IntrinsicClass sym MirReferenceSymbol where
  type Intrinsic sym MirReferenceSymbol ctx = MirReferenceFam sym ctx

  muxIntrinsic sym _tys _nm (Empty :> _tp) = muxRef sym
  muxIntrinsic _sym _tys nm ctx = typeError nm ctx

data MirReferencePath sym :: CrucibleType -> CrucibleType -> * where
  Empty_RefPath :: MirReferencePath sym tp tp
  Field_RefPath ::
    !(CtxRepr ctx) ->
    !(MirReferencePath sym tp_base TaggedUnion) ->
    !(Index ctx tp) ->
    MirReferencePath sym tp_base tp
  Index_RefPath ::
    !(TypeRepr tp) ->
    !(MirReferencePath sym tp_base (VectorType tp)) ->
    !(RegValue sym NatType) ->
    MirReferencePath sym tp_base tp

data MirReference sym (tp :: CrucibleType) where
  MirReference ::
    !(RefCell tpr) ->
    !(MirReferencePath sym tpr tp) ->
    MirReference sym tp

muxRefPath ::
  IsExprBuilder sym =>
  sym ->
  Pred sym ->
  MirReferencePath sym tp_base tp ->
  MirReferencePath sym tp_base tp ->
  MaybeT IO (MirReferencePath sym tp_base tp)
muxRefPath sym c path1 path2 = case (path1,path2) of
  (Empty_RefPath, Empty_RefPath) -> return Empty_RefPath
  (Field_RefPath ctx1 p1 f1, Field_RefPath ctx2 p2 f2)
    | Just Refl <- testEquality ctx1 ctx2
    , Just Refl <- testEquality f1 f2 ->
         do p' <- muxRefPath sym c p1 p2
            return (Field_RefPath ctx1 p' f1)
  (Index_RefPath tp p1 i1, Index_RefPath _ p2 i2) ->
         do p' <- muxRefPath sym c p1 p2
            i' <- lift $ natIte sym c i1 i2
            return (Index_RefPath tp p' i')
  _ -> mzero

muxRef :: forall sym tp.
  IsExprBuilder sym =>
  sym ->
  Pred sym ->
  MirReference sym tp ->
  MirReference sym tp ->
  IO (MirReference sym tp)
muxRef sym c (MirReference r1 p1) (MirReference r2 p2) =
   runMaybeT action >>= \case
     Nothing -> fail "Incompatible MIR reference merge"
     Just x  -> return x

  where
  action :: MaybeT IO (MirReference sym tp)
  action =
    do Refl <- MaybeT (return $ testEquality (refType r1) (refType r2))
       Refl <- MaybeT (return $ testEquality r1 r2)
       p' <- muxRefPath sym c p1 p2
       return (MirReference r1 p')

-- | Sigil type indicating the MIR syntax extension
data MIR
type instance ExprExtension MIR = EmptyExprExtension
type instance StmtExtension MIR = MirStmt

type TaggedUnion = StructType (EmptyCtx ::> NatType ::> AnyType)

data MirStmt :: (CrucibleType -> *) -> CrucibleType -> * where
  MirNewRef ::
     !(TypeRepr tp) ->
     MirStmt f (MirReferenceType tp)
  MirReadRef ::
     !(TypeRepr tp) ->
     !(f (MirReferenceType tp)) ->
     MirStmt f tp
  MirWriteRef ::
     !(f (MirReferenceType tp)) ->
     !(f tp) ->
     MirStmt f UnitType
  MirDropRef ::
     !(f (MirReferenceType tp)) ->
     MirStmt f UnitType
  MirSubfieldRef ::
     !(CtxRepr ctx) ->
     !(f (MirReferenceType TaggedUnion)) ->
     !(Index ctx tp) ->
     MirStmt f (MirReferenceType tp)
  MirSubindexRef ::
     !(TypeRepr tp) ->
     !(f (MirReferenceType (VectorType tp))) ->
     !(f NatType) ->
     MirStmt f (MirReferenceType tp)

$(return [])


traverseMirStmt ::
  Applicative m =>
  (forall t. e t -> m (f t)) ->
  (forall t. MirStmt e t -> m (MirStmt f t))
traverseMirStmt = $(U.structuralTraversal [t|MirStmt|] [])

instance TestEqualityFC MirStmt where
  testEqualityFC testSubterm =
    $(U.structuralTypeEquality [t|MirStmt|]
       [ (U.DataArg 0 `U.TypeApp` U.AnyType, [|testSubterm|])
       , (U.ConType [t|TypeRepr|] `U.TypeApp` U.AnyType, [|testEquality|])
       , (U.ConType [t|CtxRepr|] `U.TypeApp` U.AnyType, [|testEquality|])
       , (U.ConType [t|Index|] `U.TypeApp` U.AnyType `U.TypeApp` U.AnyType, [|testEquality|])
       ])
instance TestEquality f => TestEquality (MirStmt f) where
  testEquality = testEqualityFC testEquality

instance OrdFC MirStmt where
  compareFC compareSubterm =
    $(U.structuralTypeOrd [t|MirStmt|]
       [ (U.DataArg 0 `U.TypeApp` U.AnyType, [|compareSubterm|])
       , (U.ConType [t|TypeRepr|] `U.TypeApp` U.AnyType, [|compareF|])
       , (U.ConType [t|CtxRepr|] `U.TypeApp` U.AnyType, [|compareF|])
       , (U.ConType [t|Index|] `U.TypeApp` U.AnyType `U.TypeApp` U.AnyType, [|compareF|])
       ])
instance OrdF f => OrdF (MirStmt f) where
  compareF = compareFC compareF

instance TypeApp MirStmt where
  appType = \case
    MirNewRef tp    -> MirReferenceRepr tp
    MirReadRef tp _ -> tp
    MirWriteRef _ _ -> UnitRepr
    MirDropRef _    -> UnitRepr
    MirSubfieldRef ctx _ idx -> MirReferenceRepr (ctx ! idx)
    MirSubindexRef tp _ _ -> MirReferenceRepr tp

instance PrettyApp MirStmt where
  ppApp pp = \case 
    MirNewRef tp -> "newMirRef" <+> pretty tp
    MirReadRef _ x  -> "readMirRef" <+> pp x
    MirWriteRef x y -> "writeMirRef" <+> pp x <+> "<-" <+> pp y
    MirDropRef x    -> "dropMirRef" <+> pp x
    MirSubfieldRef _ x idx -> "subfieldRef" <+> pp x <+> text (show idx)
    MirSubindexRef _ x idx -> "subindexRef" <+> pp x <+> pp idx

instance FunctorFC MirStmt where
  fmapFC = fmapFCDefault
instance FoldableFC MirStmt where
  foldMapFC = foldMapFCDefault
instance TraversableFC MirStmt where
  traverseFC = traverseMirStmt

instance IsSyntaxExtension MIR

execMirStmt :: IsSymInterface sym => EvalStmtFunc p sym MIR
execMirStmt stmt s =
  let ctx = s^.stateContext
      sym = ctx^.ctxSymInterface
      halloc = simHandleAllocator ctx
      iTypes = ctxIntrinsicTypes ctx
  in case stmt of
       MirNewRef tp ->
         do r <- liftST (freshRefCell halloc tp)
            let r' = MirReference r Empty_RefPath
            return (r', s)

       MirDropRef (regValue -> MirReference r path) ->
         case path of
           Empty_RefPath ->
             do let s' = s & stateTree . actFrame . gpGlobals %~ dropRef r
                return ((), s')
           _ -> addFailedAssertion sym (GenericSimError "Cannot drop an interior reference")

       MirReadRef _tp (regValue -> MirReference r path) ->
         do let msg = ReadBeforeWriteSimError
                       "Attempted to read uninitialized reference cell"
            v <- readPartExpr sym (lookupRef r (s ^. stateTree . actFrame . gpGlobals)) msg
            v' <- readRefPath sym iTypes v path
            return (v', s)

       MirWriteRef (regValue -> MirReference r Empty_RefPath) (regValue -> x) ->
         do let s' = s & stateTree . actFrame . gpGlobals %~ insertRef sym r x
            return ((), s')
       MirWriteRef (regValue -> MirReference r path) (regValue -> x) ->
         do let msg = ReadBeforeWriteSimError
                       "Attempted to read uninitialized reference cell"
            v <- readPartExpr sym (lookupRef r (s ^. stateTree . actFrame . gpGlobals)) msg
            v' <- writeRefPath sym iTypes v path x
            let s' = s & stateTree . actFrame . gpGlobals %~ insertRef sym r v'
            return ((), s')
       MirSubfieldRef ctx0 (regValue -> MirReference r path) idx ->
         do let r' = MirReference r (Field_RefPath ctx0 path idx)
            return (r', s)
       MirSubindexRef tp (regValue -> MirReference r path) (regValue -> idx) ->
         do let r' = MirReference r (Index_RefPath tp path idx)
            return (r', s)

writeRefPath :: IsSymInterface sym =>
  sym ->
  IntrinsicTypes sym ->
  RegValue sym tp ->
  MirReferencePath sym tp tp' ->
  RegValue sym tp' ->
  IO (RegValue sym tp)
writeRefPath sym iTypes v path x =
  adjustRefPath sym iTypes v path (\_ -> return x)


adjustRefPath :: IsSymInterface sym =>
  sym ->
  IntrinsicTypes sym ->
  RegValue sym tp ->
  MirReferencePath sym tp tp' ->
  (RegValue sym tp' -> IO (RegValue sym tp')) ->
  IO (RegValue sym tp)
adjustRefPath sym iTypes v path0 adj = case path0 of
  Empty_RefPath -> adj v
  Field_RefPath ctx path fld ->
      adjustRefPath sym iTypes v path (field @1 (\(RV (AnyValue vtp x)) ->
         case testEquality vtp (StructRepr ctx) of
           Nothing -> fail ("Variant type mismatch! Expected: " ++ show (StructRepr ctx) ++
                            "\nbut got: " ++ show vtp)
           Just Refl -> RV . AnyValue vtp <$> adjustM (\x' -> RV <$> adj (unRV x')) fld x
         ))

  Index_RefPath tp path idx ->
      adjustRefPath sym iTypes v path (\v' ->
        adjustVectorWithSymNat sym (muxRegForType sym iTypes tp) v' idx adj)


readRefPath :: IsSymInterface sym =>
  sym ->
  IntrinsicTypes sym ->
  RegValue sym tp ->
  MirReferencePath sym tp tp' ->
  IO (RegValue sym tp')
readRefPath sym iTypes v = \case
  Empty_RefPath -> return v
  Field_RefPath ctx path fld ->
    do (Empty :> _disc :> RV (AnyValue vtp variant)) <- readRefPath sym iTypes v path
       case testEquality vtp (StructRepr ctx) of
         Nothing -> fail ("Variant type mismatch expected: " ++ show (StructRepr ctx) ++ 
                           "\nbut got: " ++ show vtp)
         Just Refl -> return (unRV (variant ! fld))
  Index_RefPath tp path idx ->
    do v' <- readRefPath sym iTypes v path
       indexVectorWithSymNat sym (muxRegForType sym iTypes tp) v' idx


mirExtImpl :: forall sym p. IsSymInterface sym => ExtensionImpl p sym MIR
mirExtImpl = ExtensionImpl
             { extensionEval = \_sym -> \case
             , extensionExec = execMirStmt
             }



type MirSlice tp     = StructType (EmptyCtx ::>
                           MirReferenceType (VectorType tp) ::>
                           NatType ::>
                           NatType)

pattern MirSliceRepr :: () => tp' ~ MirSlice tp => TypeRepr tp -> TypeRepr tp'
pattern MirSliceRepr tp <- StructRepr
     (viewAssign -> AssignExtend (viewAssign -> AssignExtend (viewAssign -> AssignExtend (viewAssign -> AssignEmpty)
         (MirReferenceRepr (VectorRepr tp)))
         NatRepr)
         NatRepr)
 where MirSliceRepr tp = StructRepr (Empty :> MirReferenceRepr (VectorRepr tp) :> NatRepr :> NatRepr)

--------------------------------------------------------------------------------
-- ** Generator state for MIR translation to Crucible
--

data MirValue (ty :: CrucibleType) where
  FnValue :: FnHandle args ret -> MirValue (FunctionHandleType args ret)


valueToExpr :: MirValue ty -> Expr MIR s ty
valueToExpr (FnValue handle) = App $ HandleLit handle where

handleTy :: FnHandle args ret -> TypeRepr (FunctionHandleType args ret)
handleTy handle = fty where
    argtypes = handleArgTypes handle
    rettype  = handleReturnType handle
    fty      = FunctionHandleRepr argtypes rettype
  

-- | HandleMap maps mir function names to their corresponding function handle
type HandleMap = Map.Map Text.Text MirHandle
data MirHandle where
    MirHandle :: FnSig -> FnHandle init ret -> MirHandle



instance Show MirHandle where
    show (MirHandle sig c) = show c ++ ":" ++ show sig


-- | a VarMap maps identifier names to registers (if the id
--   corresponds to a local variable) or an atom (if the id
--   corresponds to a function argument)
type VarMap s = Map.Map Text.Text (Some (VarInfo s))
data VarInfo s tp where
  VarRegister  :: Reg s tp -> VarInfo s tp
  VarReference :: Reg s (MirReferenceType tp) -> VarInfo s tp
  VarAtom      :: Atom s tp -> VarInfo s tp

varInfoRepr :: VarInfo s tp -> TypeRepr tp
varInfoRepr (VarRegister reg0)  = typeOfReg reg0
varInfoRepr (VarReference reg0) =
  case typeOfReg reg0 of
    MirReferenceRepr tp -> tp
    _ -> error "impossible: varInfoRepr"
varInfoRepr (VarAtom a) = typeOfAtom a


-- | LabelMap maps identifiers to labels of their corresponding basicblock
type LabelMap s = Map.Map BasicBlockInfo (Label s)

-- | AdtMap maps ADT names to their definitions
type AdtMap = Map.Map Text.Text [Variant]


-- | A TraitMap maps trait names to their vtables and instances
-- The 'ctx' parameter lists the required members of the trait
data TraitMap = TraitMap (Map Text {- ^ trait name-} (Some TraitImpls))

data TraitImpls ctx = TraitImpls
  {_vtableTyRepr :: CtxRepr ctx
   -- ^ Describes the types of Crucible structs that store the VTable
   -- of implementations
  ,_methodIndex :: Map.Map Text.Text (Some (Index ctx))
   -- ^ Tells which fields (indices) of the struct correspond to
   -- method names of the given trait
  ,_vtables :: Map.Map Text.Text (Assignment MirValue ctx)
   -- ^ gives vtables for each type implementing a given trait
  }

traitImpls :: CtxRepr ctx
           -> Map.Map Text.Text (Some (Index ctx))
           -> Map.Map Text.Text (Assignment MirValue ctx)
           -> TraitImpls ctx
traitImpls str midx vtbls =
  TraitImpls {_vtableTyRepr = str
             ,_methodIndex  = midx
             ,_vtables      = vtbls
             }

-- | Generator state for MIR translation
data FnState s = FnState { _varMap    :: !(VarMap s),
                           _labelMap  :: !(LabelMap s),
                           _handleMap :: !HandleMap,
                           _adtMap    :: !AdtMap,
                           _traitMap  :: !TraitMap
                         }


-- | The main data type for values, bundling the term-level type tp along with a crucible expression of type tp.
data MirExp s where
    MirExp :: TypeRepr tp -> Expr MIR s tp -> MirExp s

instance Show (MirExp s) where
    show (MirExp tr e) = (show e) ++ ": " ++ (show tr)

makeLenses ''TraitImpls
makeLenses ''FnState


-- | Scan the function declarations to find ones that look like they
-- implement a given trait. Record the type and function identifiers
-- in a map (from type names to method names to names of implementing
-- functions). The relation between methods and their implementations
-- is not straightforward in MIR. The name of the function
-- implementating a method 'foo' of a trait 'Bar' by a type 'Tar'
-- looks like: '::{{impl}}[n]::foo[m]'. This function uses a heuristic
-- and looks at the names and the type of the first argument ('self')
-- of all the function declarations to figure out which ones could be
-- implementations of methods. 

getTraitImplementation :: [Trait] -> (Text,MirHandle) ->  Maybe (Text.Text, Text.Text, MirHandle)
getTraitImplementation trts (name, handle) = do
  [methodName] <- parseFnName (show name)
  --traceM $ "Found method " ++ methodName
  let getItem (TraitMethod tm _ts) =
        case parseTraitName (show tm) of
          Just [_tn,mn] -> mn == methodName
          _ -> False
      getItem _ = False
  traitName <- Maybe.listToMaybe [ tn | (Trait tn items) <- trts, (TraitMethod _ _) <- List.filter getItem items ]
  --traceM $ "Found trait " ++ show traitName
  return (fromString methodName, traitName, handle)


modid,impl,rustid,brk::String
modid = "[A-Za-z0-9]*"
impl = "{{impl}}" ++ brk
rustid = "[A-Za-z0-9]+"
brk = "\\[[0-9]+\\]"

parseFnName :: String -> Maybe [String]
parseFnName = Regex.matchRegex (Regex.mkRegex $ modid ++ "::"++impl++"::("++rustid++brk++")"++".*")

parseTraitName :: String -> Maybe [String]
parseTraitName = Regex.matchRegex (Regex.mkRegex $ "(" ++rustid++")"++brk++"::"++"("++rustid++brk++")")

parseStaticMethodName :: String -> Maybe [String]
parseStaticMethodName = Regex.matchRegex (Regex.mkRegex $ "(" ++ modid ++ ")::" ++ rustid++"(" ++ brk ++ ")" ++ "::" ++ "(" ++ rustid++brk++")")

-- If we have a static call for a trait, we need to mangle the format so that it looks like
-- a normal function call

mangleTraitId :: DefId -> DefId 
mangleTraitId defId = case parseStaticMethodName (Text.unpack defId) of
  Just [modname,implbrk,name] -> Text.pack (modname ++ "::" ++ "{{impl}}"++implbrk++"::"++name) 
                                   
  _ -> defId