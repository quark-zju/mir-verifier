{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeInType #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}

{-# LANGUAGE AllowAmbiguousTypes #-}

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
, MirSlice
, pattern MirSliceRepr

  -- * MIR Syntax extension
, MIR
, MirStmt(..)
, mirExtImpl
) -} where

import           GHC.Natural
import           GHC.TypeLits
import           Control.Lens hiding (Empty, (:>), Index, view)
import           Control.Monad
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Maybe
import           Data.Kind(Type)
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import           Data.Map.Strict(Map)
import qualified Data.Map.Strict as Map
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.String
import qualified Data.Vector as V

import qualified Text.Regex as Regex
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import           Data.Parameterized.Some
import           Data.Parameterized.Classes
import           Data.Parameterized.Context
import           Data.Parameterized.TraversableFC
import qualified Data.Parameterized.TH.GADT as U
import qualified Data.Parameterized.Map as MapF
import qualified Data.Parameterized.NatRepr as N

import           Lang.Crucible.Backend
import           Lang.Crucible.CFG.Expr
import           Lang.Crucible.CFG.Extension.Safety(AssertionClassifier,NoAssertionClassifier,HasStructuredAssertions(..))
import           Lang.Crucible.CFG.Generator hiding (dropRef)
import           Lang.Crucible.FunctionHandle
import           Lang.Crucible.Syntax
import           Lang.Crucible.Types
import           Lang.Crucible.Simulator.ExecutionTree hiding (FnState)
import           Lang.Crucible.Simulator.Evaluation
import           Lang.Crucible.Simulator.GlobalState
import           Lang.Crucible.Simulator.Intrinsics
import           Lang.Crucible.Simulator.RegValue
import           Lang.Crucible.Simulator.RegMap
import           Lang.Crucible.Simulator.SimError

import           What4.Concrete (ConcreteVal(..), concreteType)
import           What4.Interface
import           What4.Partial
    (pattern Unassigned, maybePartExpr, justPartExpr, joinMaybePE, mergePartial, mkPE)
import           What4.Utils.MonadST

import           Mir.DefId
import           Mir.Mir
import           Mir.PP

import           Debug.Trace

import           Unsafe.Coerce


mirIntrinsicTypes :: IsSymInterface sym => IntrinsicTypes sym
mirIntrinsicTypes =
   MapF.insert (knownSymbol @MirReferenceSymbol) IntrinsicMuxFn $
   MapF.insert (knownSymbol @MirVectorSymbol) IntrinsicMuxFn $
   MapF.empty



-- Rust enum representation

-- A Rust enum, whose variants have the types listed in `ctx`.
type RustEnumType ctx = StructType (RustEnumFields ctx)
type RustEnumFields ctx = EmptyCtx ::> IsizeType ::> VariantType ctx

pattern RustEnumFieldsRepr :: () => ctx' ~ RustEnumFields ctx => CtxRepr ctx -> CtxRepr ctx'
pattern RustEnumFieldsRepr ctx = Empty :> IsizeRepr :> VariantRepr ctx
pattern RustEnumRepr :: () => tp ~ RustEnumType ctx => CtxRepr ctx -> TypeRepr tp
pattern RustEnumRepr ctx = StructRepr (RustEnumFieldsRepr ctx)

mkRustEnum :: CtxRepr ctx -> f IsizeType -> f (VariantType ctx) -> App ext f (RustEnumType ctx)
mkRustEnum ctx discr variant = MkStruct (RustEnumFieldsRepr ctx) (Empty :> discr :> variant)

rustEnumDiscriminant :: f (RustEnumType ctx) -> App ext f IsizeType
rustEnumDiscriminant e = GetStruct e i1of2 IsizeRepr

rustEnumVariant :: CtxRepr ctx -> f (RustEnumType ctx) -> App ext f (VariantType ctx)
rustEnumVariant ctx e = GetStruct e i2of2 (VariantRepr ctx)


-- Rust usize/isize representation

type SizeBits = 32

type UsizeType = BVType SizeBits
type IsizeType = BVType SizeBits
type BaseUsizeType = BaseBVType SizeBits
type BaseIsizeType = BaseBVType SizeBits

pattern UsizeRepr :: () => tp ~ UsizeType => TypeRepr tp
pattern UsizeRepr <- BVRepr (testEquality (knownRepr :: N.NatRepr SizeBits) -> Just Refl)
  where UsizeRepr = BVRepr (knownRepr :: N.NatRepr SizeBits)

pattern IsizeRepr :: () => tp ~ IsizeType => TypeRepr tp
pattern IsizeRepr <- BVRepr (testEquality (knownRepr :: N.NatRepr SizeBits) -> Just Refl)
  where IsizeRepr = BVRepr (knownRepr :: N.NatRepr SizeBits)

pattern BaseUsizeRepr :: () => tp ~ BaseUsizeType => BaseTypeRepr tp
pattern BaseUsizeRepr <- BaseBVRepr (testEquality (knownRepr :: N.NatRepr SizeBits) -> Just Refl)
  where BaseUsizeRepr = BaseBVRepr (knownRepr :: N.NatRepr SizeBits)

pattern BaseIsizeRepr :: () => tp ~ BaseIsizeType => BaseTypeRepr tp
pattern BaseIsizeRepr <- BaseBVRepr (testEquality (knownRepr :: N.NatRepr SizeBits) -> Just Refl)
  where BaseIsizeRepr = BaseBVRepr (knownRepr :: N.NatRepr SizeBits)


usizeLit :: Integer -> App ext f UsizeType
usizeLit = BVLit knownRepr

usizeAdd :: f UsizeType -> f UsizeType -> App ext f UsizeType
usizeAdd = BVAdd knownRepr

usizeSub :: f UsizeType -> f UsizeType -> App ext f UsizeType
usizeSub = BVSub knownRepr

usizeMul :: f UsizeType -> f UsizeType -> App ext f UsizeType
usizeMul = BVMul knownRepr

usizeDiv :: f UsizeType -> f UsizeType -> App ext f UsizeType
usizeDiv = BVUdiv knownRepr

usizeRem :: f UsizeType -> f UsizeType -> App ext f UsizeType
usizeRem = BVUrem knownRepr

usizeAnd :: f UsizeType -> f UsizeType -> App ext f UsizeType
usizeAnd = BVAnd knownRepr

usizeOr :: f UsizeType -> f UsizeType -> App ext f UsizeType
usizeOr = BVOr knownRepr

usizeXor :: f UsizeType -> f UsizeType -> App ext f UsizeType
usizeXor = BVXor knownRepr

usizeShl :: f UsizeType -> f UsizeType -> App ext f UsizeType
usizeShl = BVShl knownRepr

usizeShr :: f UsizeType -> f UsizeType -> App ext f UsizeType
usizeShr = BVLshr knownRepr

usizeEq :: f UsizeType -> f UsizeType -> App ext f BoolType
usizeEq = BVEq knownRepr

usizeLe :: f UsizeType -> f UsizeType -> App ext f BoolType
usizeLe = BVUle knownRepr

usizeLt :: f UsizeType -> f UsizeType -> App ext f BoolType
usizeLt = BVUlt knownRepr

natToUsize :: (App ext f IntegerType -> f IntegerType) -> f NatType -> App ext f UsizeType
natToUsize wrap = IntegerToBV knownRepr . wrap . NatToInteger

usizeToNat :: f UsizeType -> App ext f NatType
usizeToNat = BvToNat knownRepr

usizeToBv :: (1 <= r) => NatRepr r ->
    (App ext f (BVType r) -> f (BVType r)) ->
    f UsizeType -> f (BVType r)
usizeToBv r wrap = case compareNat r (knownRepr :: N.NatRepr SizeBits) of
    NatLT _ -> wrap . BVTrunc r knownRepr
    NatEQ -> id
    NatGT _ -> wrap . BVZext r knownRepr

bvToUsize :: (1 <= w) => NatRepr w ->
    (App ext f UsizeType -> f UsizeType) ->
    f (BVType w) -> f UsizeType
bvToUsize w wrap = case compareNat w (knownRepr :: N.NatRepr SizeBits) of
    NatLT _ -> wrap . BVZext knownRepr w
    NatEQ -> id
    NatGT _ -> wrap . BVTrunc knownRepr w

sbvToUsize :: (1 <= w) => NatRepr w ->
    (App ext f UsizeType -> f UsizeType) ->
    f (BVType w) -> f UsizeType
sbvToUsize w wrap = case compareNat w (knownRepr :: N.NatRepr SizeBits) of
    NatLT _ -> wrap . BVSext knownRepr w
    NatEQ -> id
    NatGT _ -> wrap . BVTrunc knownRepr w

usizeIte :: f BoolType -> f UsizeType -> f UsizeType -> App ext f UsizeType
usizeIte c t e = BVIte c knownRepr t e

vectorGetUsize :: (TypeRepr tp) ->
    (App ext f NatType -> f NatType) ->
    f (VectorType tp) -> f UsizeType -> App ext f tp
vectorGetUsize tpr wrap vec idx = VectorGetEntry tpr vec (wrap $ usizeToNat idx)

vectorSetUsize :: (TypeRepr tp) ->
    (App ext f NatType -> f NatType) ->
    f (VectorType tp) -> f UsizeType -> f tp -> App ext f (VectorType tp)
vectorSetUsize tpr wrap vec idx val = VectorSetEntry tpr vec (wrap $ usizeToNat idx) val

vectorSizeUsize ::
    (forall tp'. App ext f tp' -> f tp') ->
    f (VectorType tp) -> App ext f UsizeType
vectorSizeUsize wrap vec = natToUsize wrap $ wrap $ VectorSize vec


isizeLit :: Integer -> App ext f IsizeType
isizeLit = BVLit knownRepr

isizeAdd :: f IsizeType -> f IsizeType -> App ext f IsizeType
isizeAdd = BVAdd knownRepr

isizeSub :: f IsizeType -> f IsizeType -> App ext f IsizeType
isizeSub = BVSub knownRepr

isizeMul :: f IsizeType -> f IsizeType -> App ext f IsizeType
isizeMul = BVMul knownRepr

isizeDiv :: f IsizeType -> f IsizeType -> App ext f IsizeType
isizeDiv = BVSdiv knownRepr

isizeRem :: f IsizeType -> f IsizeType -> App ext f IsizeType
isizeRem = BVSrem knownRepr

isizeNeg :: f IsizeType -> App ext f IsizeType
isizeNeg = BVNeg knownRepr

isizeAnd :: f IsizeType -> f IsizeType -> App ext f IsizeType
isizeAnd = BVAnd knownRepr

isizeOr :: f IsizeType -> f IsizeType -> App ext f IsizeType
isizeOr = BVOr knownRepr

isizeXor :: f IsizeType -> f IsizeType -> App ext f IsizeType
isizeXor = BVXor knownRepr

isizeShl :: f IsizeType -> f IsizeType -> App ext f IsizeType
isizeShl = BVShl knownRepr

isizeShr :: f IsizeType -> f IsizeType -> App ext f IsizeType
isizeShr = BVAshr knownRepr

isizeEq :: f IsizeType -> f IsizeType -> App ext f BoolType
isizeEq = BVEq knownRepr

isizeLe :: f IsizeType -> f IsizeType -> App ext f BoolType
isizeLe = BVSle knownRepr

isizeLt :: f IsizeType -> f IsizeType -> App ext f BoolType
isizeLt = BVSlt knownRepr

integerToIsize ::
    (App ext f IsizeType -> f IsizeType) ->
    f IntegerType -> f IsizeType
integerToIsize wrap = wrap . IntegerToBV knownRepr

isizeToBv :: (1 <= r) => NatRepr r ->
    (App ext f (BVType r) -> f (BVType r)) ->
    f IsizeType -> f (BVType r)
isizeToBv r wrap = case compareNat r (knownRepr :: N.NatRepr SizeBits) of
    NatLT _ -> wrap . BVTrunc r knownRepr
    NatEQ -> id
    NatGT _ -> wrap . BVSext r knownRepr

bvToIsize :: (1 <= w) => NatRepr w ->
    (App ext f IsizeType -> f IsizeType) ->
    f (BVType w) -> f IsizeType
bvToIsize w wrap = case compareNat w (knownRepr :: N.NatRepr SizeBits) of
    NatLT _ -> wrap . BVZext knownRepr w
    NatEQ -> id
    NatGT _ -> wrap . BVTrunc knownRepr w

sbvToIsize :: (1 <= w) => NatRepr w ->
    (App ext f IsizeType -> f IsizeType) ->
    f (BVType w) -> f IsizeType
sbvToIsize w wrap = case compareNat w (knownRepr :: N.NatRepr SizeBits) of
    NatLT _ -> wrap . BVSext knownRepr w
    NatEQ -> id
    NatGT _ -> wrap . BVTrunc knownRepr w

isizeIte :: f BoolType -> f IsizeType -> f IsizeType -> App ext f IsizeType
isizeIte c t e = BVIte c knownRepr t e


usizeToIsize :: (App ext f IsizeType -> f IsizeType) -> f UsizeType -> f IsizeType
usizeToIsize _wrap = id

isizeToUsize :: (App ext f UsizeType -> f UsizeType) -> f IsizeType -> f UsizeType
isizeToUsize _wrap = id


--------------------------------------------------------------
-- * A MirReference is a Crucible RefCell paired with a path to a sub-component
--
-- We use this to represent mutable data

type MirReferenceSymbol = "MirReference"
type MirReferenceType tp = IntrinsicType MirReferenceSymbol (EmptyCtx ::> tp)

pattern MirReferenceRepr :: () => tp' ~ MirReferenceType tp => TypeRepr tp -> TypeRepr tp'
pattern MirReferenceRepr tp <-
     IntrinsicRepr (testEquality (knownSymbol @MirReferenceSymbol) -> Just Refl) (Empty :> tp)
 where MirReferenceRepr tp = IntrinsicRepr (knownSymbol @MirReferenceSymbol) (Empty :> tp)

type family MirReferenceFam (sym :: Type) (ctx :: Ctx CrucibleType) :: Type where
  MirReferenceFam sym (EmptyCtx ::> tp) = MirReference sym tp
  MirReferenceFam sym ctx = TypeError ('Text "MirRefeence expects a single argument, but was given" ':<>:
                                       'ShowType ctx)
instance IsSymInterface sym => IntrinsicClass sym MirReferenceSymbol where
  type Intrinsic sym MirReferenceSymbol ctx = MirReferenceFam sym ctx

  muxIntrinsic sym iTypes _nm (Empty :> _tp) = muxRef sym iTypes
  muxIntrinsic _sym _tys nm ctx = typeError nm ctx

data MirReferenceRoot sym :: CrucibleType -> Type where
  RefCell_RefRoot :: !(RefCell tp) -> MirReferenceRoot sym tp
  GlobalVar_RefRoot :: !(GlobalVar tp) -> MirReferenceRoot sym tp
  Const_RefRoot :: !(TypeRepr tp) -> !(RegValue sym tp) -> MirReferenceRoot sym tp

data MirReferencePath sym :: CrucibleType -> CrucibleType -> Type where
  Empty_RefPath :: MirReferencePath sym tp tp
  Any_RefPath ::
    !(TypeRepr tp) ->
    !(MirReferencePath sym tp_base AnyType) ->
    MirReferencePath sym  tp_base tp
  Field_RefPath ::
    !(CtxRepr ctx) ->
    !(MirReferencePath sym tp_base (StructType ctx)) ->
    !(Index ctx tp) ->
    MirReferencePath sym tp_base tp
  Variant_RefPath ::
    !(CtxRepr ctx) ->
    !(MirReferencePath sym tp_base (RustEnumType ctx)) ->
    !(Index ctx tp) ->
    MirReferencePath sym tp_base tp
  Index_RefPath ::
    !(TypeRepr tp) ->
    !(MirReferencePath sym tp_base (MirVectorType tp)) ->
    !(RegValue sym UsizeType) ->
    MirReferencePath sym tp_base tp
  Just_RefPath ::
    !(TypeRepr tp) ->
    !(MirReferencePath sym tp_base (MaybeType tp)) ->
    MirReferencePath sym tp_base tp
  -- | Present `&mut Vector` as `&mut MirVector`.
  VectorAsMirVector_RefPath ::
    !(TypeRepr tp) ->
    !(MirReferencePath sym tp_base (VectorType tp)) ->
    MirReferencePath sym tp_base (MirVectorType tp)
  -- | Present `&mut Array` as `&mut MirVector`.
  ArrayAsMirVector_RefPath ::
    !(BaseTypeRepr btp) ->
    !(MirReferencePath sym tp_base (UsizeArrayType btp)) ->
    MirReferencePath sym tp_base (MirVectorType (BaseToType btp))

data MirReference sym (tp :: CrucibleType) where
  MirReference ::
    !(MirReferenceRoot sym tpr) ->
    !(MirReferencePath sym tpr tp) ->
    MirReference sym tp
  -- The result of an integer-to-pointer cast.  Guaranteed not to be
  -- dereferenceable.
  MirReference_Integer ::
    !(TypeRepr tp) ->
    !(RegValue sym UsizeType) ->
    MirReference sym tp

instance IsSymInterface sym => Show (MirReferencePath sym tp tp') where
    show Empty_RefPath = "Empty_RefPath"
    show (Any_RefPath tpr p) = "(Any_RefPath " ++ show tpr ++ " " ++ show p ++ ")"
    show (Field_RefPath ctx p idx) = "(Field_RefPath " ++ show ctx ++ " " ++ show p ++ " " ++ show idx ++ ")"
    show (Variant_RefPath ctx p idx) = "(Variant_RefPath " ++ show ctx ++ " " ++ show p ++ " " ++ show idx ++ ")"
    show (Index_RefPath tpr p idx) = "(Index_RefPath " ++ show tpr ++ " " ++ show p ++ " " ++ show (printSymExpr idx) ++ ")"
    show (Just_RefPath tpr p) = "(Just_RefPath " ++ show tpr ++ " " ++ show p ++ ")"
    show (VectorAsMirVector_RefPath tpr p) = "(VectorAsMirVector_RefPath " ++ show tpr ++ " " ++ show p ++ ")"
    show (ArrayAsMirVector_RefPath btpr p) = "(ArrayAsMirVector_RefPath " ++ show btpr ++ " " ++ show p ++ ")"

refRootType :: MirReferenceRoot sym tp -> TypeRepr tp
refRootType (RefCell_RefRoot r) = refType r
refRootType (GlobalVar_RefRoot r) = globalType r
refRootType (Const_RefRoot tpr _) = tpr

muxRefRoot ::
  IsSymInterface sym =>
  sym ->
  IntrinsicTypes sym ->
  Pred sym ->
  MirReferenceRoot sym tp ->
  MirReferenceRoot sym tp ->
  MaybeT IO (MirReferenceRoot sym tp)
muxRefRoot sym iTypes c root1 root2 = case (root1, root2) of
  (RefCell_RefRoot rc1, RefCell_RefRoot rc2)
    | Just Refl <- testEquality rc1 rc2 -> return root1
  (GlobalVar_RefRoot gv1, GlobalVar_RefRoot gv2)
    | Just Refl <- testEquality gv1 gv2 -> return root1
  (Const_RefRoot tpr v1, Const_RefRoot _tpr v2) -> do
    v' <- lift $ muxRegForType sym iTypes tpr c v1 v2
    return $ Const_RefRoot tpr v'
  _ -> mzero

muxRefPath ::
  IsSymInterface sym =>
  sym ->
  Pred sym ->
  MirReferencePath sym tp_base tp ->
  MirReferencePath sym tp_base tp ->
  MaybeT IO (MirReferencePath sym tp_base tp)
muxRefPath sym c path1 path2 = case (path1,path2) of
  (Empty_RefPath, Empty_RefPath) -> return Empty_RefPath
  (Any_RefPath ctx1 p1, Any_RefPath ctx2 p2)
    | Just Refl <- testEquality ctx1 ctx2 ->
         do p' <- muxRefPath sym c p1 p2
            return (Any_RefPath ctx1 p')
  (Field_RefPath ctx1 p1 f1, Field_RefPath ctx2 p2 f2)
    | Just Refl <- testEquality ctx1 ctx2
    , Just Refl <- testEquality f1 f2 ->
         do p' <- muxRefPath sym c p1 p2
            return (Field_RefPath ctx1 p' f1)
  (Variant_RefPath ctx1 p1 f1, Variant_RefPath ctx2 p2 f2)
    | Just Refl <- testEquality ctx1 ctx2
    , Just Refl <- testEquality f1 f2 ->
         do p' <- muxRefPath sym c p1 p2
            return (Variant_RefPath ctx1 p' f1)
  (Index_RefPath tp p1 i1, Index_RefPath _ p2 i2) ->
         do p' <- muxRefPath sym c p1 p2
            i' <- lift $ bvIte sym c i1 i2
            return (Index_RefPath tp p' i')
  (Just_RefPath tp p1, Just_RefPath _ p2) ->
         do p' <- muxRefPath sym c p1 p2
            return (Just_RefPath tp p')
  (VectorAsMirVector_RefPath tp p1, VectorAsMirVector_RefPath _ p2) ->
         do p' <- muxRefPath sym c p1 p2
            return (VectorAsMirVector_RefPath tp p')
  (ArrayAsMirVector_RefPath tp p1, ArrayAsMirVector_RefPath _ p2) ->
         do p' <- muxRefPath sym c p1 p2
            return (ArrayAsMirVector_RefPath tp p')
  _ -> mzero

muxRef :: forall sym tp.
  IsSymInterface sym =>
  sym ->
  IntrinsicTypes sym ->
  Pred sym ->
  MirReference sym tp ->
  MirReference sym tp ->
  IO (MirReference sym tp)
muxRef sym iTypes c (MirReference r1 p1) (MirReference r2 p2) =
   runMaybeT action >>= \case
     Nothing -> fail "Incompatible MIR reference merge"
     Just x  -> return x

  where
  action :: MaybeT IO (MirReference sym tp)
  action =
    do Refl <- MaybeT (return $ testEquality (refRootType r1) (refRootType r2))
       r' <- muxRefRoot sym iTypes c r1 r2
       p' <- muxRefPath sym c p1 p2
       return (MirReference r' p')
muxRef sym _iTypes c (MirReference_Integer tpr i1) (MirReference_Integer _ i2) = do
    i' <- bvIte sym c i1 i2
    return $ MirReference_Integer tpr i'
muxRef _ _ _ _ _ = do
    fail "incompatible MIR reference merge"


--------------------------------------------------------------
-- A MirVectorType is dynamically either a VectorType or a SymbolicArrayType.
-- We use this in `MirSlice` to allow taking slices of either
-- `crucible::vector::Vector` or `crucible::array::Array`.

-- Aliases for working with MIR arrays, which have a single usize index.
type UsizeArrayType btp = SymbolicArrayType (EmptyCtx ::> BaseUsizeType) btp
pattern UsizeArrayRepr :: () => tp' ~ UsizeArrayType btp => BaseTypeRepr btp -> TypeRepr tp'
pattern UsizeArrayRepr btp <-
    SymbolicArrayRepr (testEquality (Empty :> BaseUsizeRepr) -> Just Refl) btp
  where UsizeArrayRepr btp = SymbolicArrayRepr (Empty :> BaseUsizeRepr) btp


type MirVectorSymbol = "MirVector"
type MirVectorType tp = IntrinsicType MirVectorSymbol (EmptyCtx ::> tp)

pattern MirVectorRepr :: () => tp' ~ MirVectorType tp => TypeRepr tp -> TypeRepr tp'
pattern MirVectorRepr tp <-
     IntrinsicRepr (testEquality (knownSymbol @MirVectorSymbol) -> Just Refl) (Empty :> tp)
 where MirVectorRepr tp = IntrinsicRepr (knownSymbol @MirVectorSymbol) (Empty :> tp)

type family MirVectorFam (sym :: Type) (ctx :: Ctx CrucibleType) :: Type where
  MirVectorFam sym (EmptyCtx ::> tp) = MirVector sym tp
  MirVectorFam sym ctx = TypeError ('Text "MirVector expects a single argument, but was given" ':<>:
                                       'ShowType ctx)
instance IsSymInterface sym => IntrinsicClass sym MirVectorSymbol where
  type Intrinsic sym MirVectorSymbol ctx = MirVectorFam sym ctx

  muxIntrinsic sym tys _nm (Empty :> tpr) = muxMirVector sym tys tpr
  muxIntrinsic _sym _tys nm ctx = typeError nm ctx

data MirVector sym (tp :: CrucibleType) where
  MirVector_Vector ::
    !(RegValue sym (VectorType tp)) ->
    MirVector sym tp
  MirVector_PartialVector ::
    !(RegValue sym (VectorType (MaybeType tp))) ->
    MirVector sym tp
  MirVector_Array ::
    !(RegValue sym (UsizeArrayType btp)) ->
    MirVector sym (BaseToType btp)

muxMirVector :: forall sym tp.
  IsSymInterface sym =>
  sym ->
  IntrinsicTypes sym ->
  TypeRepr tp ->
  Pred sym ->
  MirVector sym tp ->
  MirVector sym tp ->
  IO (MirVector sym tp)
-- Two total vectors of matching length can remain total.
muxMirVector sym itefns tpr c (MirVector_Vector v1) (MirVector_Vector v2)
  | V.length v1 == V.length v2 =
    MirVector_Vector <$> muxRegForType sym itefns (VectorRepr tpr) c v1 v2
-- All other combinations of total and partial vectors become partial.
muxMirVector sym itefns tpr c (MirVector_Vector v1) (MirVector_Vector v2) = do
    pv1 <- toPartialVector sym tpr v1
    pv2 <- toPartialVector sym tpr v2
    MirVector_PartialVector <$> muxPartialVectors sym itefns tpr c pv1 pv2
muxMirVector sym itefns tpr c (MirVector_PartialVector pv1) (MirVector_Vector v2) = do
    pv2 <- toPartialVector sym tpr v2
    MirVector_PartialVector <$> muxPartialVectors sym itefns tpr c pv1 pv2
muxMirVector sym itefns tpr c (MirVector_Vector v1) (MirVector_PartialVector pv2) = do
    pv1 <- toPartialVector sym tpr v1
    MirVector_PartialVector <$> muxPartialVectors sym itefns tpr c pv1 pv2
muxMirVector sym itefns tpr c (MirVector_PartialVector pv1) (MirVector_PartialVector pv2) = do
    MirVector_PartialVector <$> muxPartialVectors sym itefns tpr c pv1 pv2
-- Arrays only merge with arrays.
muxMirVector sym itefns (asBaseType -> AsBaseType btpr) c
        (MirVector_Array a1) (MirVector_Array a2) =
    MirVector_Array <$> muxRegForType sym itefns (UsizeArrayRepr btpr) c a1 a2
muxMirVector sym _ _ _ _ _ =
    addFailedAssertion sym $ Unsupported $ "Cannot merge dissimilar MirVectors."

toPartialVector :: IsSymInterface sym =>
    sym -> TypeRepr tp ->
    RegValue sym (VectorType tp) -> IO (RegValue sym (VectorType (MaybeType tp)))
toPartialVector sym _tpr v = return $ fmap (justPartExpr sym) v

muxPartialVectors :: IsSymInterface sym =>
    sym -> IntrinsicTypes sym -> TypeRepr tp ->
    Pred sym ->
    RegValue sym (VectorType (MaybeType tp)) ->
    RegValue sym (VectorType (MaybeType tp)) ->
    IO (RegValue sym (VectorType (MaybeType tp)))
muxPartialVectors sym itefns tpr c pv1 pv2 = do
    let len = max (V.length pv1) (V.length pv2)
    V.generateM len $ \i -> do
        let x = getPE i pv1
        let y = getPE i pv2
        muxRegForType sym itefns (MaybeRepr tpr) c x y
  where
    getPE i pv = Maybe.fromMaybe Unassigned $ pv V.!? i

indexMirVectorWithSymIndex ::
    IsSymInterface sym =>
    sym ->
    (Pred sym -> RegValue sym tp -> RegValue sym tp -> IO (RegValue sym tp)) ->
    MirVector sym tp ->
    RegValue sym UsizeType ->
    IO (RegValue sym tp)
indexMirVectorWithSymIndex sym iteFn (MirVector_Vector v) i = do
    i' <- bvToNat sym i
    indexVectorWithSymNat sym iteFn v i'
indexMirVectorWithSymIndex sym iteFn (MirVector_PartialVector pv) i = do
    i' <- bvToNat sym i
    -- Lift iteFn from `RegValue sym tp` to `RegValue sym (MaybeType tp)`
    let iteFn' c x y = mergePartial sym (\c' x' y' -> lift $ iteFn c' x' y') c x y
    maybeVal <- indexVectorWithSymNat sym iteFn' pv i'
    readPartExpr sym maybeVal $ ReadBeforeWriteSimError $
        "Attempted to read uninitialized vector index"
indexMirVectorWithSymIndex sym _ (MirVector_Array a) i =
    arrayLookup sym a (Empty :> i)

adjustMirVectorWithSymIndex ::
    IsSymInterface sym =>
    sym ->
    (Pred sym -> RegValue sym tp -> RegValue sym tp -> IO (RegValue sym tp)) ->
    MirVector sym tp ->
    RegValue sym UsizeType ->
    (RegValue sym tp -> IO (RegValue sym tp)) ->
    IO (MirVector sym tp)
adjustMirVectorWithSymIndex sym iteFn (MirVector_Vector v) i adj = do
    i' <- bvToNat sym i
    MirVector_Vector <$> adjustVectorWithSymNat sym iteFn v i' adj
adjustMirVectorWithSymIndex sym iteFn (MirVector_PartialVector pv) i adj = do
    i' <- bvToNat sym i
    let iteFn' c x y = mergePartial sym (\c' x' y' -> lift $ iteFn c' x' y') c x y
    pv' <- adjustVectorWithSymNat sym iteFn' pv i' $ \maybeVal -> do
        val <- readPartExpr sym maybeVal $ ReadBeforeWriteSimError $
            "Attempted to read uninitialized vector index"
        val' <- adj val
        return $ justPartExpr sym val'
    return $ MirVector_PartialVector pv'
adjustMirVectorWithSymIndex sym _ (MirVector_Array a) i adj = do
    x <- arrayLookup sym a (Empty :> i)
    x' <- adj x
    MirVector_Array <$> arrayUpdate sym a (Empty :> i) x'

-- Write a new value.  Unlike `adjustMirVectorWithSymIndex`, this doesn't
-- require a successful read from the given index.
writeMirVectorWithSymIndex ::
    IsSymInterface sym =>
    sym ->
    (Pred sym -> RegValue sym tp -> RegValue sym tp -> IO (RegValue sym tp)) ->
    MirVector sym tp ->
    RegValue sym UsizeType ->
    RegValue sym tp ->
    IO (MirVector sym tp)
writeMirVectorWithSymIndex sym iteFn (MirVector_Vector v) i val = do
    i' <- bvToNat sym i
    MirVector_Vector <$> adjustVectorWithSymNat sym iteFn v i' (\_ -> return val)
writeMirVectorWithSymIndex sym iteFn (MirVector_PartialVector pv) i val = do
    i' <- bvToNat sym i
    let iteFn' c x y = mergePartial sym (\c' x' y' -> lift $ iteFn c' x' y') c x y
    pv' <- adjustVectorWithSymNat sym iteFn' pv i' $ \_ -> return $ justPartExpr sym val
    return $ MirVector_PartialVector pv'
writeMirVectorWithSymIndex sym _ (MirVector_Array a) i val = do
    MirVector_Array <$> arrayUpdate sym a (Empty :> i) val



-- | Sigil type indicating the MIR syntax extension
data MIR
type instance ExprExtension MIR = EmptyExprExtension
type instance StmtExtension MIR = MirStmt
type instance AssertionClassifier MIR = NoAssertionClassifier

-- First `Any` is the data pointer - either an immutable or mutable reference.
-- Second `Any` is the vtable.
type DynRefType = StructType (EmptyCtx ::> AnyType ::> AnyType)

dynRefDataIndex :: Index (EmptyCtx ::> AnyType ::> AnyType) AnyType
dynRefDataIndex = skipIndex baseIndex

dynRefVtableIndex :: Index (EmptyCtx ::> AnyType ::> AnyType) AnyType
dynRefVtableIndex = lastIndex (incSize $ incSize zeroSize)


data MirStmt :: (CrucibleType -> Type) -> CrucibleType -> Type where
  MirNewRef ::
     !(TypeRepr tp) ->
     MirStmt f (MirReferenceType tp)
  MirIntegerToRef ::
     !(TypeRepr tp) ->
     !(f UsizeType) ->
     MirStmt f (MirReferenceType tp)
  MirGlobalRef ::
     !(GlobalVar tp) ->
     MirStmt f (MirReferenceType tp)
  MirConstRef ::
     !(TypeRepr tp) ->
     !(f tp) ->
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
  MirSubanyRef ::
     !(TypeRepr tp) ->
     !(f (MirReferenceType AnyType)) ->
     MirStmt f (MirReferenceType tp)
  MirSubfieldRef ::
     !(CtxRepr ctx) ->
     !(f (MirReferenceType (StructType ctx))) ->
     !(Index ctx tp) ->
     MirStmt f (MirReferenceType tp)
  MirSubvariantRef ::
     !(CtxRepr ctx) ->
     !(f (MirReferenceType (RustEnumType ctx))) ->
     !(Index ctx tp) ->
     MirStmt f (MirReferenceType tp)
  MirSubindexRef ::
     !(TypeRepr tp) ->
     !(f (MirReferenceType (MirVectorType tp))) ->
     !(f UsizeType) ->
     MirStmt f (MirReferenceType tp)
  MirSubjustRef ::
     !(TypeRepr tp) ->
     !(f (MirReferenceType (MaybeType tp))) ->
     MirStmt f (MirReferenceType tp)
  MirRef_VectorAsMirVector ::
     !(TypeRepr tp) ->
     !(f (MirReferenceType (VectorType tp))) ->
     MirStmt f (MirReferenceType (MirVectorType tp))
  MirRef_ArrayAsMirVector ::
     !(BaseTypeRepr btp) ->
     !(f (MirReferenceType (UsizeArrayType btp))) ->
     MirStmt f (MirReferenceType (MirVectorType (BaseToType btp)))
  MirRef_Eq ::
     !(f (MirReferenceType tp)) ->
     !(f (MirReferenceType tp)) ->
     MirStmt f BoolType
  -- Rust `ptr::offset`.  Steps by `count` units of `size_of::<T>`.  Arithmetic
  -- must not overflow and the resulting pointer must be in bounds.
  MirRef_Offset ::
     !(TypeRepr tp) ->
     !(f (MirReferenceType tp)) ->
     !(f IsizeType) ->
     MirStmt f (MirReferenceType tp)
  -- Rust `ptr::wrapping_offset`.  Steps by `count` units of `size_of::<T>`,
  -- with no additional restrictions.
  MirRef_OffsetWrap ::
     !(TypeRepr tp) ->
     !(f (MirReferenceType tp)) ->
     !(f IsizeType) ->
     MirStmt f (MirReferenceType tp)
  -- | Try to subtract two references, as in `pointer::offset_from`.  If both
  -- point into the same array, return their difference; otherwise, return
  -- Nothing.  The `Nothing` result is useful for overlap checks: slices from
  -- different arrays cannot overlap.
  MirRef_TryOffsetFrom ::
     !(f (MirReferenceType tp)) ->
     !(f (MirReferenceType tp)) ->
     MirStmt f (MaybeType IsizeType)
  -- | Peel off an outermost `Index_RefPath`.  Given a pointer to an element of
  -- a vector, this produces a pointer to the parent vector and the index of
  -- the element.  If the outermost path segment isn't `Index_RefPath`, this
  -- operation raises an error.
  MirRef_PeelIndex ::
     !(TypeRepr tp) ->
     !(f (MirReferenceType tp)) ->
     MirStmt f (StructType (EmptyCtx ::> MirReferenceType (MirVectorType tp) ::> UsizeType))
  VectorSnoc ::
     !(TypeRepr tp) ->
     !(f (VectorType tp)) ->
     !(f tp) ->
     MirStmt f (VectorType tp)
  VectorHead ::
     !(TypeRepr tp) ->
     !(f (VectorType tp)) ->
     MirStmt f (MaybeType tp)
  VectorTail ::
     !(TypeRepr tp) ->
     !(f (VectorType tp)) ->
     MirStmt f (VectorType tp)
  VectorInit ::
     !(TypeRepr tp) ->
     !(f (VectorType tp)) ->
     MirStmt f (VectorType tp)
  VectorLast ::
     !(TypeRepr tp) ->
     !(f (VectorType tp)) ->
     MirStmt f (MaybeType tp)
  VectorConcat ::
     !(TypeRepr tp) ->
     !(f (VectorType tp)) ->
     !(f (VectorType tp)) ->
     MirStmt f (VectorType tp)
  VectorTake ::
     !(TypeRepr tp) ->
     !(f (VectorType tp)) ->
     !(f NatType) ->
     MirStmt f (VectorType tp)
  VectorDrop ::
     !(TypeRepr tp) ->
     !(f (VectorType tp)) ->
     !(f NatType) ->
     MirStmt f (VectorType tp)
  ArrayZeroed ::
     (1 <= w) =>
     !(Assignment BaseTypeRepr (idxs ::> idx)) ->
     !(NatRepr w) ->
     MirStmt f (SymbolicArrayType (idxs ::> idx) (BaseBVType w))
  MirVector_Uninit ::
    !(TypeRepr tp) ->
    !(f UsizeType) ->
    MirStmt f (MirVectorType tp)
  MirVector_FromVector ::
    !(TypeRepr tp) ->
    !(f (VectorType tp)) ->
    MirStmt f (MirVectorType tp)
  MirVector_FromArray ::
    !(BaseTypeRepr btp) ->
    !(f (UsizeArrayType btp)) ->
    MirStmt f (MirVectorType (BaseToType btp))
  MirVector_Resize ::
    !(TypeRepr tp) ->
    !(f (MirVectorType tp)) ->
    !(f UsizeType) ->
    MirStmt f (MirVectorType tp)

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
       , (U.ConType [t|BaseTypeRepr|] `U.TypeApp` U.AnyType, [|testEquality|])
       , (U.ConType [t|CtxRepr|] `U.TypeApp` U.AnyType, [|testEquality|])
       , (U.ConType [t|Index|] `U.TypeApp` U.AnyType `U.TypeApp` U.AnyType, [|testEquality|])
       , (U.ConType [t|GlobalVar|] `U.TypeApp` U.AnyType, [|testEquality|])
       , (U.ConType [t|NatRepr|] `U.TypeApp` U.AnyType, [|testEquality|])
       , (U.ConType [t|Assignment|] `U.TypeApp` U.AnyType `U.TypeApp` U.AnyType, [|testEquality|])
       ])
instance TestEquality f => TestEquality (MirStmt f) where
  testEquality = testEqualityFC testEquality

instance OrdFC MirStmt where
  compareFC compareSubterm =
    $(U.structuralTypeOrd [t|MirStmt|]
       [ (U.DataArg 0 `U.TypeApp` U.AnyType, [|compareSubterm|])
       , (U.ConType [t|TypeRepr|] `U.TypeApp` U.AnyType, [|compareF|])
       , (U.ConType [t|BaseTypeRepr|] `U.TypeApp` U.AnyType, [|compareF|])
       , (U.ConType [t|CtxRepr|] `U.TypeApp` U.AnyType, [|compareF|])
       , (U.ConType [t|Index|] `U.TypeApp` U.AnyType `U.TypeApp` U.AnyType, [|compareF|])
       , (U.ConType [t|GlobalVar|] `U.TypeApp` U.AnyType, [|compareF|])
       , (U.ConType [t|NatRepr|] `U.TypeApp` U.AnyType, [|compareF|])
       , (U.ConType [t|Assignment|] `U.TypeApp` U.AnyType `U.TypeApp` U.AnyType, [|compareF|])
       ])

instance TypeApp MirStmt where
  appType = \case
    MirNewRef tp    -> MirReferenceRepr tp
    MirIntegerToRef tp _ -> MirReferenceRepr tp
    MirGlobalRef gv -> MirReferenceRepr (globalType gv)
    MirConstRef tp _ -> MirReferenceRepr tp
    MirReadRef tp _ -> tp
    MirWriteRef _ _ -> UnitRepr
    MirDropRef _    -> UnitRepr
    MirSubanyRef tp _ -> MirReferenceRepr tp
    MirSubfieldRef ctx _ idx -> MirReferenceRepr (ctx ! idx)
    MirSubvariantRef ctx _ idx -> MirReferenceRepr (ctx ! idx)
    MirSubindexRef tp _ _ -> MirReferenceRepr tp
    MirSubjustRef tp _ -> MirReferenceRepr tp
    MirRef_VectorAsMirVector tp _ -> MirReferenceRepr (MirVectorRepr tp)
    MirRef_ArrayAsMirVector btp _ -> MirReferenceRepr (MirVectorRepr $ baseToType btp)
    MirRef_Eq _ _ -> BoolRepr
    MirRef_Offset tp _ _ -> MirReferenceRepr tp
    MirRef_OffsetWrap tp _ _ -> MirReferenceRepr tp
    MirRef_TryOffsetFrom _ _ -> MaybeRepr IsizeRepr
    MirRef_PeelIndex tp _ -> StructRepr (Empty :> MirReferenceRepr (MirVectorRepr tp) :> UsizeRepr)
    VectorSnoc tp _ _ -> VectorRepr tp
    VectorHead tp _ -> MaybeRepr tp
    VectorTail tp _ -> VectorRepr tp
    VectorInit tp _ -> VectorRepr tp
    VectorLast tp _ -> MaybeRepr tp
    VectorConcat tp _ _ -> VectorRepr tp
    VectorTake tp _ _ -> VectorRepr tp
    VectorDrop tp _ _ -> VectorRepr tp
    ArrayZeroed idxs w -> SymbolicArrayRepr idxs (BaseBVRepr w)
    MirVector_Uninit tp _ -> MirVectorRepr tp
    MirVector_FromVector tp _ -> MirVectorRepr tp
    MirVector_FromArray btp _ -> MirVectorRepr (baseToType btp)
    MirVector_Resize tp _ _ -> MirVectorRepr tp

instance PrettyApp MirStmt where
  ppApp pp = \case 
    MirNewRef tp -> "newMirRef" <+> pretty tp
    MirIntegerToRef tp i -> "integerToMirRef" <+> pretty tp <+> pp i
    MirGlobalRef gv -> "globalMirRef" <+> pretty gv
    MirConstRef _ v -> "constMirRef" <+> pp v
    MirReadRef _ x  -> "readMirRef" <+> pp x
    MirWriteRef x y -> "writeMirRef" <+> pp x <+> "<-" <+> pp y
    MirDropRef x    -> "dropMirRef" <+> pp x
    MirSubanyRef tpr x -> "subanyRef" <+> pretty tpr <+> pp x
    MirSubfieldRef _ x idx -> "subfieldRef" <+> pp x <+> text (show idx)
    MirSubvariantRef _ x idx -> "subvariantRef" <+> pp x <+> text (show idx)
    MirSubindexRef _ x idx -> "subindexRef" <+> pp x <+> pp idx
    MirSubjustRef _ x -> "subjustRef" <+> pp x
    MirRef_VectorAsMirVector _ v -> "mirRef_vectorAsMirVector" <+> pp v
    MirRef_ArrayAsMirVector _ a -> "mirRef_arrayAsMirVector" <+> pp a
    MirRef_Eq x y -> "mirRef_eq" <+> pp x <+> pp y
    MirRef_Offset _ p o -> "mirRef_offset" <+> pp p <+> pp o
    MirRef_OffsetWrap _ p o -> "mirRef_offsetWrap" <+> pp p <+> pp o
    MirRef_TryOffsetFrom p o -> "mirRef_tryOffsetFrom" <+> pp p <+> pp o
    MirRef_PeelIndex _ p -> "mirRef_peelIndex" <+> pp p
    VectorSnoc _ v e -> "vectorSnoc" <+> pp v <+> pp e
    VectorHead _ v -> "vectorHead" <+> pp v
    VectorTail _ v -> "vectorTail" <+> pp v
    VectorInit _ v -> "vectorInit" <+> pp v
    VectorLast _ v -> "vectorLast" <+> pp v
    VectorConcat _ v1 v2 -> "vectorConcat" <+> pp v1 <+> pp v2
    VectorTake _ v i -> "vectorTake" <+> pp v <+> pp i
    VectorDrop _ v i -> "vectorDrop" <+> pp v <+> pp i
    ArrayZeroed idxs w -> "arrayZeroed" <+> text (show idxs) <+> text (show w)
    MirVector_Uninit tp len -> "mirVector_uninit" <+> pretty tp <+> pp len
    MirVector_FromVector tp v -> "mirVector_fromVector" <+> pretty tp <+> pp v
    MirVector_FromArray btp a -> "mirVector_fromArray" <+> pretty btp <+> pp a
    MirVector_Resize _ v i -> "mirVector_resize" <+> pp v <+> pp i


instance FunctorFC MirStmt where
  fmapFC = fmapFCDefault
instance FoldableFC MirStmt where
  foldMapFC = foldMapFCDefault
instance TraversableFC MirStmt where
  traverseFC = traverseMirStmt


instance HasStructuredAssertions MIR where
  explain _       = \case
  toPredicate _ _ = \case
      

instance IsSyntaxExtension MIR

readBeforeWriteMsg :: SimErrorReason
readBeforeWriteMsg = ReadBeforeWriteSimError
    "Attempted to read uninitialized reference cell"

newConstMirRef ::
    TypeRepr tp ->
    RegValue sym tp ->
    MirReference sym tp
newConstMirRef tpr v = MirReference (Const_RefRoot tpr v) Empty_RefPath

readRefRoot :: IsSymInterface sym =>
    SimState p sym ext rtp f a ->
    sym ->
    MirReferenceRoot sym tp ->
    IO (RegValue sym tp)
readRefRoot s sym (RefCell_RefRoot rc) =
    readPartExpr sym (lookupRef rc (s ^. stateTree . actFrame . gpGlobals)) readBeforeWriteMsg
readRefRoot s sym (GlobalVar_RefRoot gv) =
    case lookupGlobal gv (s ^. stateTree . actFrame . gpGlobals) of
        Just x -> return x
        Nothing -> addFailedAssertion sym readBeforeWriteMsg
readRefRoot _ _ (Const_RefRoot _ v) = return v

writeRefRoot :: IsSymInterface sym =>
    SimState p sym ext rtp f a ->
    sym ->
    MirReferenceRoot sym tp ->
    RegValue sym tp ->
    IO (SimState p sym ext rtp f a)
writeRefRoot s sym (RefCell_RefRoot rc) v =
    return $ s & stateTree . actFrame . gpGlobals %~ insertRef sym rc v
writeRefRoot s _sym (GlobalVar_RefRoot gv) v =
    return $ s & stateTree . actFrame . gpGlobals %~ insertGlobal gv v
writeRefRoot _ sym (Const_RefRoot tpr _) _ =
    addFailedAssertion sym $ GenericSimError $
        "Cannot write to Const_RefRoot (of type " ++ show tpr ++ ")"

dropRefRoot :: IsSymInterface sym =>
    SimState p sym ext rtp f a ->
    sym ->
    MirReferenceRoot sym tp ->
    IO (SimState p sym ext rtp f a)
dropRefRoot s _sym (RefCell_RefRoot rc) =
    return $ s & stateTree . actFrame . gpGlobals %~ dropRef rc
dropRefRoot _ sym (GlobalVar_RefRoot gv) =
    addFailedAssertion sym $ GenericSimError $
        "Cannot drop global variable " ++ show gv
dropRefRoot _ sym (Const_RefRoot tpr _) =
    addFailedAssertion sym $ GenericSimError $
        "Cannot drop Const_RefRoot (of type " ++ show tpr ++ ")"

dropMirRefIO :: IsSymInterface sym => SimState p sym ext rtp f a -> sym ->
    MirReference sym tp -> IO (SimState p sym ext rtp f a)
dropMirRefIO s sym (MirReference root Empty_RefPath) = dropRefRoot s sym root
dropMirRefIO _ sym (MirReference _ _) = addFailedAssertion sym $ GenericSimError $
    "attempted to drop an interior reference (non-empty ref path)"
dropMirRefIO _ sym (MirReference_Integer _ _) = addFailedAssertion sym $ GenericSimError $
    "attempted to drop the result of an integer-to-pointer cast"

readMirRefIO :: IsSymInterface sym => SimState p sym ext rtp f a -> sym ->
    MirReference sym tp -> IO (RegValue sym tp)
readMirRefIO s sym (MirReference r path) = do
    let iTypes = ctxIntrinsicTypes $ s^.stateContext
    v <- readRefRoot s sym r
    v' <- readRefPath sym iTypes v path
    return v'
readMirRefIO _ sym (MirReference_Integer _ _) = addFailedAssertion sym $ GenericSimError $
    "attempted to dereference the result of an integer-to-pointer cast"

writeMirRefIO :: IsSymInterface sym => SimState p sym ext rtp f a -> sym ->
    MirReference sym tp -> RegValue sym tp -> IO (SimState p sym ext rtp f a)
writeMirRefIO s sym (MirReference root Empty_RefPath) val = writeRefRoot s sym root val
writeMirRefIO s sym (MirReference root path) val = do
    let iTypes = ctxIntrinsicTypes $ s^.stateContext
    x <- readRefRoot s sym root
    x' <- writeRefPath sym iTypes x path val
    writeRefRoot s sym root x'
writeMirRefIO _ sym (MirReference_Integer _ _) _ = addFailedAssertion sym $ GenericSimError $
    "attempted to write to the result of an integer-to-pointer cast"

subanyMirRefIO :: IsSymInterface sym => sym ->
    TypeRepr tp -> MirReference sym AnyType -> IO (MirReference sym tp)
subanyMirRefIO _ tpr (MirReference root path) =
    return $ MirReference root (Any_RefPath tpr path)
subanyMirRefIO sym _ (MirReference_Integer _ _) = addFailedAssertion sym $ GenericSimError $
    "attempted subany on the result of an integer-to-pointer cast"

subfieldMirRefIO :: IsSymInterface sym => sym ->
    CtxRepr ctx -> MirReference sym (StructType ctx) -> Index ctx tp ->
    IO (MirReference sym tp)
subfieldMirRefIO _ ctx (MirReference root path) idx =
    return $ MirReference root (Field_RefPath ctx path idx)
subfieldMirRefIO sym _ (MirReference_Integer _ _) _ = addFailedAssertion sym $ GenericSimError $
    "attempted subfield on the result of an integer-to-pointer cast"

subvariantMirRefIO :: IsSymInterface sym => sym ->
    CtxRepr ctx -> MirReference sym (RustEnumType ctx) -> Index ctx tp ->
    IO (MirReference sym tp)
subvariantMirRefIO _ ctx (MirReference root path) idx =
    return $ MirReference root (Variant_RefPath ctx path idx)
subvariantMirRefIO sym _ (MirReference_Integer _ _) _ = addFailedAssertion sym $ GenericSimError $
    "attempted subvariant on the result of an integer-to-pointer cast"

subindexMirRefIO :: IsSymInterface sym => sym ->
    TypeRepr tp -> MirReference sym (MirVectorType tp) -> RegValue sym UsizeType ->
    IO (MirReference sym tp)
subindexMirRefIO _ tpr (MirReference root path) idx =
    return $ MirReference root (Index_RefPath tpr path idx)
subindexMirRefIO sym _ (MirReference_Integer _ _) _ = addFailedAssertion sym $ GenericSimError $
    "attempted subindex on the result of an integer-to-pointer cast"

subjustMirRefIO :: IsSymInterface sym => sym ->
    TypeRepr tp -> MirReference sym (MaybeType tp) -> IO (MirReference sym tp)
subjustMirRefIO _ tpr (MirReference root path) =
    return $ MirReference root (Just_RefPath tpr path)
subjustMirRefIO sym _ (MirReference_Integer _ _) = addFailedAssertion sym $ GenericSimError $
    "attempted subjust on the result of an integer-to-pointer cast"

mirRef_vectorAsMirVectorIO :: IsSymInterface sym => sym ->
    TypeRepr tp -> MirReference sym (VectorType tp) -> IO (MirReference sym (MirVectorType tp))
mirRef_vectorAsMirVectorIO _ tpr (MirReference root path) =
    return $ MirReference root (VectorAsMirVector_RefPath tpr path)
mirRef_vectorAsMirVectorIO sym _ (MirReference_Integer _ _) =
    addFailedAssertion sym $ GenericSimError $
        "attempted Vector->MirVector conversion on the result of an integer-to-pointer cast"

mirRef_arrayAsMirVectorIO :: IsSymInterface sym => sym ->
    BaseTypeRepr btp -> MirReference sym (UsizeArrayType btp) ->
    IO (MirReference sym (MirVectorType (BaseToType btp)))
mirRef_arrayAsMirVectorIO _ btpr (MirReference root path) =
    return $ MirReference root (ArrayAsMirVector_RefPath btpr path)
mirRef_arrayAsMirVectorIO sym _ (MirReference_Integer _ _) =
    addFailedAssertion sym $ GenericSimError $
        "attempted Array->MirVector conversion on the result of an integer-to-pointer cast"

refRootEq :: IsSymInterface sym => sym ->
    MirReferenceRoot sym tp1 -> MirReferenceRoot sym tp2 ->
    IO (RegValue sym BoolType)
refRootEq sym (RefCell_RefRoot rc1) (RefCell_RefRoot rc2)
  | Just Refl <- testEquality rc1 rc2 = return $ truePred sym
refRootEq sym (GlobalVar_RefRoot gv1) (GlobalVar_RefRoot gv2)
  | Just Refl <- testEquality gv1 gv2 = return $ truePred sym
refRootEq sym (Const_RefRoot _ _) (Const_RefRoot _ _) =
    addFailedAssertion sym $ Unsupported $ "Cannot compare Const_RefRoots"
refRootEq sym _ _ = return $ falsePred sym

refPathEq :: IsSymInterface sym => sym ->
    MirReferencePath sym tp_base1 tp1 -> MirReferencePath sym tp_base2 tp2 ->
    IO (RegValue sym BoolType)
refPathEq sym Empty_RefPath Empty_RefPath = return $ truePred sym
refPathEq sym (Any_RefPath tpr1 p1) (Any_RefPath tpr2 p2)
  | Just Refl <- testEquality tpr1 tpr2 = refPathEq sym p1 p2
refPathEq sym (Field_RefPath ctx1 p1 idx1) (Field_RefPath ctx2 p2 idx2)
  | Just Refl <- testEquality ctx1 ctx2
  , Just Refl <- testEquality idx1 idx2 = refPathEq sym p1 p2
refPathEq sym (Variant_RefPath ctx1 p1 idx1) (Variant_RefPath ctx2 p2 idx2)
  | Just Refl <- testEquality ctx1 ctx2
  , Just Refl <- testEquality idx1 idx2 = refPathEq sym p1 p2
refPathEq sym (Index_RefPath tpr1 p1 idx1) (Index_RefPath tpr2 p2 idx2)
  | Just Refl <- testEquality tpr1 tpr2 = do
    pEq <- refPathEq sym p1 p2
    idxEq <- bvEq sym idx1 idx2
    andPred sym pEq idxEq
refPathEq sym (Just_RefPath tpr1 p1) (Just_RefPath tpr2 p2)
  | Just Refl <- testEquality tpr1 tpr2 = refPathEq sym p1 p2
refPathEq sym (VectorAsMirVector_RefPath tpr1 p1) (VectorAsMirVector_RefPath tpr2 p2)
  | Just Refl <- testEquality tpr1 tpr2 = refPathEq sym p1 p2
refPathEq sym (ArrayAsMirVector_RefPath tpr1 p1) (ArrayAsMirVector_RefPath tpr2 p2)
  | Just Refl <- testEquality tpr1 tpr2 = refPathEq sym p1 p2
refPathEq sym _ _ = return $ falsePred sym

mirRef_eqIO :: IsSymInterface sym => sym ->
    MirReference sym tp -> MirReference sym tp -> IO (RegValue sym BoolType)
mirRef_eqIO sym (MirReference root1 path1) (MirReference root2 path2) = do
    rootEq <- refRootEq sym root1 root2
    pathEq <- refPathEq sym path1 path2
    andPred sym rootEq pathEq
mirRef_eqIO sym (MirReference_Integer _ i1) (MirReference_Integer _ i2) =
    isEq sym i1 i2
mirRef_eqIO sym _ _ =
    -- All valid references are disjoint from all integer references.
    return $ falsePred sym

mirRef_offsetIO :: IsSymInterface sym => sym ->
    TypeRepr tp -> MirReference sym tp -> RegValue sym IsizeType -> IO (MirReference sym tp)
-- TODO: `offset` has a number of preconditions that we should check here:
-- * addition must not overflow
-- * resulting pointer must be in-bounds for the allocation
-- * total offset in bytes must not exceed isize::MAX
mirRef_offsetIO = mirRef_offsetWrapIO

mirRef_offsetWrapIO :: IsSymInterface sym => sym ->
    TypeRepr tp -> MirReference sym tp -> RegValue sym IsizeType -> IO (MirReference sym tp)
mirRef_offsetWrapIO sym _tpr (MirReference root (Index_RefPath tpr path idx)) offset = do
    -- `wrapping_offset` puts no restrictions on the arithmetic performed.
    idx' <- bvAdd sym idx offset
    return $ MirReference root $ Index_RefPath tpr path idx'
mirRef_offsetWrapIO sym _ ref@(MirReference _ _) offset = do
    isZero <- bvEq sym offset =<< bvLit sym knownNat 0
    assert sym isZero $ Unsupported $
        "pointer arithmetic outside arrays is not yet implemented"
    return ref
mirRef_offsetWrapIO sym _ ref@(MirReference_Integer _ _) offset = do
    -- Offsetting by zero is a no-op, and is always allowed, even on invalid
    -- pointers.  In particular, this permits `(&[])[0..]`.
    isZero <- bvEq sym offset =<< bvLit sym knownNat 0
    assert sym isZero $ Unsupported $
        "cannot perform pointer arithmetic on invalid pointer"
    return ref

mirRef_tryOffsetFromIO :: IsSymInterface sym => sym ->
    MirReference sym tp -> MirReference sym tp -> IO (RegValue sym (MaybeType IsizeType))
mirRef_tryOffsetFromIO sym (MirReference root1 path1) (MirReference root2 path2) = do
    rootEq <- refRootEq sym root1 root2
    case (path1, path2) of
        (Index_RefPath _ path1' idx1, Index_RefPath _ path2' idx2) -> do
            pathEq <- refPathEq sym path1' path2'
            similar <- andPred sym rootEq pathEq
            -- TODO: implement overflow checks, similar to `offset`
            offset <- bvSub sym idx1 idx2
            return $ mkPE similar offset
        _ -> do
            pathEq <- refPathEq sym path1 path2
            similar <- andPred sym rootEq pathEq
            mkPE similar <$> bvLit sym knownNat 0
mirRef_tryOffsetFromIO _ _ _ = do
    -- MirReference_Integer pointers are always disjoint from all MirReference
    -- pointers, so we report them as being in different objects.
    --
    -- For comparing two MirReference_Integer pointers, this answer is clearly
    -- wrong, but it's (hopefully) a moot point since there's almost nothing
    -- you can do with a MirReference_Integer anyway without causing a crash.
    return Unassigned

mirRef_peelIndexIO :: IsSymInterface sym => sym ->
    TypeRepr tp -> MirReference sym tp ->
    IO (RegValue sym (StructType (EmptyCtx ::> MirReferenceType (MirVectorType tp) ::> UsizeType)))
mirRef_peelIndexIO _sym _tpr (MirReference root (Index_RefPath _tpr' path idx)) = do
    return $ Empty :> RV (MirReference root path) :> RV idx
mirRef_peelIndexIO sym _ (MirReference _ _) =
    addFailedAssertion sym $ Unsupported $
        "peelIndex is not yet implemented for this RefPath kind"
mirRef_peelIndexIO sym _ _ = do
    addFailedAssertion sym $ Unsupported $
        "cannot perform peelIndex on invalid pointer"


execMirStmt :: IsSymInterface sym => EvalStmtFunc p sym MIR
execMirStmt stmt s =
  let ctx = s^.stateContext
      sym = ctx^.ctxSymInterface
      halloc = simHandleAllocator ctx
  in case stmt of
       MirNewRef tp ->
         do r <- freshRefCell halloc tp
            let r' = MirReference (RefCell_RefRoot r) Empty_RefPath
            return (r', s)

       MirIntegerToRef tp (regValue -> i) ->
         do let r' = MirReference_Integer tp i
            return (r', s)

       MirGlobalRef gv ->
         do let r = MirReference (GlobalVar_RefRoot gv) Empty_RefPath
            return (r, s)

       MirConstRef tpr (regValue -> v) ->
         do let r = MirReference (Const_RefRoot tpr v) Empty_RefPath
            return (r, s)

       MirDropRef (regValue -> ref) -> writeOnly $ dropMirRefIO s sym ref
       MirReadRef _tp (regValue -> ref) -> readOnly s $ readMirRefIO s sym ref
       MirWriteRef (regValue -> ref) (regValue -> x) -> writeOnly $ writeMirRefIO s sym ref x
       MirSubanyRef tp (regValue -> ref) ->
         readOnly s $ subanyMirRefIO sym tp ref
       MirSubfieldRef ctx0 (regValue -> ref) idx ->
         readOnly s $ subfieldMirRefIO sym ctx0 ref idx
       MirSubvariantRef ctx0 (regValue -> ref) idx ->
         readOnly s $ subvariantMirRefIO sym ctx0 ref idx
       MirSubindexRef tpr (regValue -> ref) (regValue -> idx) ->
         readOnly s $ subindexMirRefIO sym tpr ref idx
       MirSubjustRef tpr (regValue -> ref) ->
         readOnly s $ subjustMirRefIO sym tpr ref
       MirRef_VectorAsMirVector tpr (regValue -> ref) ->
         readOnly s $ mirRef_vectorAsMirVectorIO sym tpr ref
       MirRef_ArrayAsMirVector tpr (regValue -> ref) ->
         readOnly s $ mirRef_arrayAsMirVectorIO sym tpr ref
       MirRef_Eq (regValue -> r1) (regValue -> r2) ->
         readOnly s $ mirRef_eqIO sym r1 r2
       MirRef_Offset tpr (regValue -> ref) (regValue -> off) ->
         readOnly s $ mirRef_offsetIO sym tpr ref off
       MirRef_OffsetWrap tpr (regValue -> ref) (regValue -> off) ->
         readOnly s $ mirRef_offsetWrapIO sym tpr ref off
       MirRef_TryOffsetFrom (regValue -> r1) (regValue -> r2) ->
         readOnly s $ mirRef_tryOffsetFromIO sym r1 r2
       MirRef_PeelIndex tpr (regValue -> ref) ->
         readOnly s $ mirRef_peelIndexIO sym tpr ref

       VectorSnoc _tp (regValue -> vecValue) (regValue -> elemValue) ->
            return (V.snoc vecValue elemValue, s)
       VectorHead _tp (regValue -> vecValue) -> do
            let val = maybePartExpr sym $
                    if V.null vecValue then Nothing else Just $ V.head vecValue
            return (val, s)
       VectorTail _tp (regValue -> vecValue) ->
            return (if V.null vecValue then V.empty else V.tail vecValue, s)
       VectorInit _tp (regValue -> vecValue) ->
            return (if V.null vecValue then V.empty else V.init vecValue, s)
       VectorLast _tp (regValue -> vecValue) -> do
            let val = maybePartExpr sym $
                    if V.null vecValue then Nothing else Just $ V.last vecValue
            return (val, s)
       VectorConcat _tp (regValue -> v1) (regValue -> v2) ->
            return (v1 <> v2, s)
       VectorTake _tp (regValue -> v) (regValue -> idx) -> case asConcrete idx of
            Just (ConcreteNat idx') -> return (V.take (fromIntegral idx') v, s)
            Nothing -> addFailedAssertion sym $
                GenericSimError "VectorTake index must be concrete"
       VectorDrop _tp (regValue -> v) (regValue -> idx) -> case asConcrete idx of
            Just (ConcreteNat idx') -> return (V.drop (fromIntegral idx') v, s)
            Nothing -> addFailedAssertion sym $
                GenericSimError "VectorDrop index must be concrete"
       ArrayZeroed idxs w -> do
            zero <- bvLit sym w 0
            val <- constantArray sym idxs zero
            return (val, s)

       MirVector_Uninit _tp (regValue -> lenSym) -> do
            len <- case asUnsignedBV lenSym of
                Just x -> return x
                Nothing -> addFailedAssertion sym $ Unsupported $
                    "Attempted to allocate vector of symbolic length"
            let pv = V.replicate (fromInteger len) Unassigned
            return (MirVector_PartialVector pv, s)
       MirVector_FromVector _tp (regValue -> v) ->
            return (MirVector_Vector v, s)
       MirVector_FromArray _tp (regValue -> a) ->
            return (MirVector_Array a, s)
       MirVector_Resize _tpr (regValue -> mirVec) (regValue -> newLenSym) -> do
            newLen <- case asUnsignedBV newLenSym of
                Just x -> return x
                Nothing -> addFailedAssertion sym $ Unsupported $
                    "Attempted to resize vector to symbolic length"
            get <- case mirVec of
                MirVector_PartialVector pv -> return $ \i -> joinMaybePE (pv V.!? i)
                MirVector_Vector v -> return $ \i -> maybePartExpr sym $ v V.!? i
                MirVector_Array _ -> addFailedAssertion sym $ Unsupported $
                    "Attempted to resize MirVector backed by symbolic array"
            let pv' = V.generate (fromInteger newLen) get
            return (MirVector_PartialVector pv', s)
  where
    readOnly :: SimState p sym ext rtp f a -> IO b ->
        IO (b, SimState p sym ext rtp f a)
    readOnly s' act = act >>= \x -> return (x, s')

    writeOnly :: IO (SimState p sym ext rtp f a) ->
        IO ((), SimState p sym ext rtp f a)
    writeOnly act = act >>= \s' -> return ((), s')

writeRefPath :: IsSymInterface sym =>
  sym ->
  IntrinsicTypes sym ->
  RegValue sym tp ->
  MirReferencePath sym tp tp' ->
  RegValue sym tp' ->
  IO (RegValue sym tp)
-- Special case: when the final path segment is `Just_RefPath`, we can write to
-- it by replacing `Nothing` with `Just`.  This is useful for writing to
-- uninitialized struct fields.  Using `adjust` here would fail, since it can't
-- read the old value out of the `Nothing`.
--
-- There is a similar special case above for MirWriteRef with Empty_RefPath,
-- which allows writing to an uninitialized MirReferenceRoot.
writeRefPath sym iTypes v (Just_RefPath _tp path) x =
  adjustRefPath sym iTypes v path (\_ -> return $ justPartExpr sym x)
-- Similar case for writing to MirVectors.  Uninitialized entries of a
-- MirVector_PartialVector can be initialized by a write.
writeRefPath sym iTypes v (Index_RefPath tp path idx) x = do
  adjustRefPath sym iTypes v path (\vec ->
    writeMirVectorWithSymIndex sym (muxRegForType sym iTypes tp) vec idx x)
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
  Any_RefPath tpr path ->
      adjustRefPath sym iTypes v path (\(AnyValue vtp x) ->
         case testEquality vtp tpr of
           Nothing -> fail ("Any type mismatch! Expected: " ++ show tpr ++
                            "\nbut got: " ++ show vtp)
           Just Refl -> AnyValue vtp <$> adj x
         )
  Field_RefPath _ctx path fld ->
      adjustRefPath sym iTypes v path
        (\x -> adjustM (\x' -> RV <$> adj (unRV x')) fld x)
  Variant_RefPath _ctx path fld ->
      -- TODO: report an error if variant `fld` is not selected
      adjustRefPath sym iTypes v path (field @1 (\(RV x) ->
        RV <$> adjustM (\x' -> VB <$> mapM adj (unVB x')) fld x))
  Index_RefPath tp path idx ->
      adjustRefPath sym iTypes v path (\v' -> do
        adjustMirVectorWithSymIndex sym (muxRegForType sym iTypes tp) v' idx adj)
  Just_RefPath tp path ->
      adjustRefPath sym iTypes v path $ \v' -> do
          let msg = ReadBeforeWriteSimError $
                  "attempted to modify uninitialized Maybe of type " ++ show tp
          v'' <- readPartExpr sym v' msg
          mv <- adj v''
          return $ justPartExpr sym mv
  VectorAsMirVector_RefPath _ path -> do
    adjustRefPath sym iTypes v path $ \v' -> do
        mv <- adj $ MirVector_Vector v'
        case mv of
            MirVector_Vector v'' -> return v''
            _ -> addFailedAssertion sym $ Unsupported $
                "tried to change underlying type of MirVector ref"
  ArrayAsMirVector_RefPath _ path -> do
    adjustRefPath sym iTypes v path $ \v' -> do
        mv <- adj $ MirVector_Array v'
        case mv of
            MirVector_Array v'' -> return v''
            _ -> addFailedAssertion sym $ Unsupported $
                "tried to change underlying type of MirVector ref"

readRefPath :: IsSymInterface sym =>
  sym ->
  IntrinsicTypes sym ->
  RegValue sym tp ->
  MirReferencePath sym tp tp' ->
  IO (RegValue sym tp')
readRefPath sym iTypes v = \case
  Empty_RefPath -> return v
  Any_RefPath tpr path ->
    do AnyValue vtp x <- readRefPath sym iTypes v path
       case testEquality vtp tpr of
         Nothing -> fail ("Any type mismatch! Expected: " ++ show tpr ++ 
                           "\nbut got: " ++ show vtp)
         Just Refl -> return x
  Field_RefPath _ctx path fld ->
    do flds <- readRefPath sym iTypes v path
       return $ unRV $ flds ! fld
  Variant_RefPath ctx path fld ->
    do (Empty :> _discr :> RV variant) <- readRefPath sym iTypes v path
       let msg = GenericSimError $
               "attempted to read from wrong variant (" ++ show fld ++ " of " ++ show ctx ++ ")"
       readPartExpr sym (unVB $ variant ! fld) msg
  Index_RefPath tp path idx ->
    do v' <- readRefPath sym iTypes v path
       indexMirVectorWithSymIndex sym (muxRegForType sym iTypes tp) v' idx
  Just_RefPath tp path ->
    do v' <- readRefPath sym iTypes v path
       let msg = ReadBeforeWriteSimError $
               "attempted to read from uninitialized Maybe of type " ++ show tp
       readPartExpr sym v' msg
  VectorAsMirVector_RefPath _ path -> do
    MirVector_Vector <$> readRefPath sym iTypes v path
  ArrayAsMirVector_RefPath _ path -> do
    MirVector_Array <$> readRefPath sym iTypes v path



mirExtImpl :: forall sym p. IsSymInterface sym => ExtensionImpl p sym MIR
mirExtImpl = ExtensionImpl
             { extensionEval = \_sym -> \case
             , extensionExec = execMirStmt
             }

--------------------------------------------------------------------------------
-- ** Slices

-- A Slice is a sequence of values plus an index to the first element
-- and a length.

type MirSlice tp     = StructType (EmptyCtx ::>
                           MirReferenceType tp ::> -- first element
                           UsizeType)       --- length

pattern MirSliceRepr :: () => tp' ~ MirSlice tp => TypeRepr tp -> TypeRepr tp'
pattern MirSliceRepr tp <- StructRepr
     (viewAssign -> AssignExtend (viewAssign -> AssignExtend (viewAssign -> AssignEmpty)
         (MirReferenceRepr tp))
         UsizeRepr)
 where MirSliceRepr tp = StructRepr (Empty :> MirReferenceRepr tp :> UsizeRepr)

mirSliceCtxRepr :: TypeRepr tp -> CtxRepr (EmptyCtx ::>
                           MirReferenceType tp ::>
                           UsizeType)
mirSliceCtxRepr tp = (Empty :> MirReferenceRepr tp :> UsizeRepr)

mkSlice ::
    TypeRepr tp ->
    Expr MIR s (MirReferenceType tp) ->
    Expr MIR s UsizeType ->
    Expr MIR s (MirSlice tp)
mkSlice tpr vec len = App $ MkStruct (mirSliceCtxRepr tpr) $
    Empty :> vec :> len

getSlicePtr :: Expr MIR s (MirSlice tp) -> Expr MIR s (MirReferenceType tp)
getSlicePtr e = getStruct i1of2 e

getSliceLen :: Expr MIR s (MirSlice tp) -> Expr MIR s UsizeType
getSliceLen e = getStruct i2of2 e
