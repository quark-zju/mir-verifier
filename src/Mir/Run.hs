{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE PartialTypeSignatures #-}

{-# OPTIONS_GHC -Wincomplete-patterns -Wall -fno-warn-name-shadowing -fno-warn-unused-top-binds #-}

module Mir.Run (mirToCFG, extractFromCFGPure) where

import System.IO
import qualified Mir.Trans as T
import qualified Data.Map.Strict as Map
import qualified Mir.Mir as M

import Control.Lens
import Data.Foldable
import qualified Data.Text as Text
import Control.Monad.ST
import Data.Parameterized.Nonce

import Data.IORef
import qualified Data.Parameterized.Map as MapF
import qualified Verifier.SAW.SharedTerm as SC
import qualified Verifier.SAW.TypedAST as SC
import qualified Lang.Crucible.FunctionHandle as C
import qualified Lang.Crucible.CFG.Core as C

import qualified What4.Config as C
import qualified Lang.Crucible.Simulator as C
import qualified What4.Expr as C

import qualified Lang.Crucible.Backend.SAWCore as C

import qualified Data.Parameterized.Context as Ctx
import qualified Data.Vector as V
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Parameterized.TraversableFC as Ctx

import           Mir.Intrinsics
import qualified Mir.Pass as Pass

import qualified Data.AIG.Interface as AIG




type Sym = C.SAWCoreBackend GlobalNonceGenerator (C.Flags C.FloatReal)


type SymOverride arg_ctx ret = C.OverrideSim (C.SAWCruciblePersonality Sym) Sym MIR (C.RegEntry Sym ret) arg_ctx ret ()

unfoldAssign ::
     C.CtxRepr ctx
    -> Ctx.Assignment f ctx
    -> (forall ctx' tp. C.TypeRepr tp -> f tp  -> C.CtxRepr ctx' -> Ctx.Assignment f ctx' -> a)
    -> a
unfoldAssign ctx0 asgn k =
  case Ctx.viewAssign ctx0 of
    Ctx.AssignEmpty -> error "packType: ran out of actual arguments!"
    Ctx.AssignExtend ctx' ctp' ->
          let asgn' = Ctx.init asgn
              idx   = Ctx.nextIndex (Ctx.size asgn')
           in k ctp' (asgn Ctx.! idx)
                ctx'
                asgn'

show_val :: C.TypeRepr tp -> C.RegValue Sym tp -> String
show_val tp reg_val =
    case tp of
      C.BVRepr _w -> show reg_val
      C.BoolRepr -> show reg_val
      C.StructRepr reprasgn -> show_regval_assgn reprasgn reg_val
      _ -> "Cannot show type: " ++ (show tp)

show_regval_assgn :: C.CtxRepr ctx -> Ctx.Assignment (C.RegValue' Sym) ctx -> String
show_regval_assgn ctxrepr asgn = "[" ++ go ctxrepr asgn (Ctx.sizeInt (Ctx.size ctxrepr)) ++ "]"
    where go :: forall ctx. C.CtxRepr ctx -> Ctx.Assignment (C.RegValue' Sym) ctx -> Int -> String
          go _ _ 0 = ""
          go cr as i = unfoldAssign cr as $ \repr val cr' as' ->
              go cr' as' (i-1) ++ ", " ++ show_val repr (C.unRV val)


asgnCtxToListM :: (Monad m) => C.CtxRepr ctx -> Int -> Ctx.Assignment f ctx -> (forall tp. C.TypeRepr tp -> f tp -> m a) -> m [a]
asgnCtxToListM _ 0 _ _ = return []
asgnCtxToListM cr i as f = unfoldAssign cr as $ \repr val cr' as' -> do
    e <- f repr val
    rest <- asgnCtxToListM cr' (i-1) as' f
    return (rest ++ [e])


show_regentry :: C.RegEntry Sym ret -> String
show_regentry (C.RegEntry tp reg_val) = show_val tp reg_val

print_cfg :: C.AnyCFG MIR -> IO ()
print_cfg cfg = case cfg of
                     C.AnyCFG c -> print $ C.ppCFG False c



--extractFromCFGPure :: SymOverride Ctx.EmptyCtx ret -> SC.SharedContext -> C.CFG MIR blocks argctx ret -> IO SC.Term -- no global variables
extractFromCFGPure
  :: AIG.IsAIG l g =>
     SymOverride Ctx.EmptyCtx tp
     -> AIG.Proxy l g
     -> SC.SharedContext
     -> C.CFG MIR blocks args tp
     -> IO SC.Term
extractFromCFGPure setup proxy sc cfg = do
    let h  =  C.cfgHandle cfg
    _config <- C.initialConfig 0 C.sawOptions
    sym    <- C.newSAWCoreBackend proxy sc globalNonceGenerator
    halloc <- C.newHandleAllocator
    (ecs, args) <- setupArgs sc sym h
    print $ "Type of h " ++ show (C.handleArgTypes h) ++ " -> " ++ show (C.handleReturnType h)
    print $ "Length of ecs is " ++ show (length ecs)
    let simctx = C.initSimContext sym MapF.empty halloc stdout C.emptyHandleMap mirExtImpl C.SAWCruciblePersonality
        simst  = C.initSimState simctx C.emptyGlobals C.defaultAbortHandler
        osim   = do setup
                    C.regValue <$> C.callCFG cfg args
    res <- C.executeCrucible simst $ C.runOverrideSim (C.handleReturnType h) osim
    case res of
      C.FinishedResult _ pr -> do
          gp <- case pr of
                  C.TotalRes gp -> return gp
                  C.PartialRes _ gp _ -> do
                      putStrLn "Symbolic simulation failed along some paths"
                      return gp
          t  <- toSawCore sc sym (gp^.C.gpValue)
          t' <- SC.scAbstractExts sc (toList ecs) t
          return t'
      C.AbortedResult _a ar -> do
          fail $ "aborted failure: " ++ handleAbortedResult ar
      C.TimeoutResult _ -> fail "timed out"

handleAbortedResult :: C.AbortedResult sym MIR -> String
handleAbortedResult (C.AbortedExec simerror _) = show simerror -- TODO
handleAbortedResult _ = "unknown"

mirToCFG :: M.Collection ->  Maybe ([M.Fn] -> [M.Fn]) -> Map.Map Text.Text (C.AnyCFG MIR)
mirToCFG col Nothing = mirToCFG col (Just Pass.passId)
mirToCFG col (Just pass) =
    runST $ C.withHandleAllocator $ T.transCollection $ col &M.functions %~ pass

toSawCore :: SC.SharedContext -> Sym -> (C.RegEntry Sym tp) -> IO SC.Term
toSawCore sc sym (C.RegEntry tp v) =
    case tp of
        C.NatRepr -> C.toSC sym v
        C.IntegerRepr -> C.toSC sym v
        C.RealValRepr -> C.toSC sym v
        C.ComplexRealRepr -> C.toSC sym v
        C.BoolRepr -> C.toSC sym v
        C.BVRepr _w -> C.toSC sym v
        C.StructRepr ctx -> -- ctx is of type CtxRepr; v is of type Ctx.Assignment (RegValue' sym) ctx
            go_struct ctx v
        C.VectorRepr t -> go_vector t v
        _ -> fail $ unwords ["unknown type: ", show tp]

   where go_struct :: C.CtxRepr ctx -> Ctx.Assignment (C.RegValue' Sym) ctx -> IO SC.Term
         go_struct cr as = do
             terms <- asgnCtxToListM cr (Ctx.sizeInt (Ctx.size cr)) as $ \repr val -> toSawCore sc sym (C.RegEntry repr (C.unRV val))
             SC.scTuple sc terms

         go_vector :: C.TypeRepr t -> V.Vector (C.RegValue Sym t) -> IO SC.Term -- This should actually be a sawcore list; this requires one to also have a function from typereprs to terms
         go_vector tp v =
             case C.asBaseType tp of
               C.AsBaseType btp -> do
                   sc_tp <- C.baseSCType sym sc btp
                   let l = V.toList v
                   rs <- mapM (\e -> toSawCore sc sym (C.RegEntry tp e)) l
                   SC.scVector sc sc_tp rs
               _ -> fail $ "Cannot return vectors of non-base type"

-- one could perhaps do more about ADTs below by giving the below access to the MIR types

setupArg :: SC.SharedContext
         -> Sym
         -> IORef (Seq (SC.ExtCns SC.Term))
         -> C.TypeRepr tp
         -> IO (C.RegEntry Sym tp)
setupArg sc sym ecRef tp =
  case C.asBaseType tp of
    C.AsBaseType btp -> do
       sc_tp <- C.baseSCType sym sc btp
       i     <- SC.scFreshGlobalVar sc
       ecs   <- readIORef ecRef
       let len = Seq.length ecs
       let ec = SC.EC i ("arg_"++show len) sc_tp
       writeIORef ecRef (ecs Seq.|> ec)
       t     <- SC.scFlatTermF sc (SC.ExtCns ec)
       elt   <- C.bindSAWTerm sym btp t
       return (C.RegEntry tp elt)

    C.NotBaseType ->
        case tp of
          C.StructRepr ctr -> do
              sargs_ <- Ctx.traverseFC (setupArg sc sym ecRef) ctr -- sargs : Ctx.Assignment (C.RegEntry Sym) ctx
              sargs <- Ctx.traverseWithIndex (\_ e -> return $ C.RV $ C.regValue e) sargs_
              return (C.RegEntry tp sargs)
          C.AnyRepr -> fail $ "AnyRepr cannot be made symbolic. This is probably due to attempting to extract an ADT or closure."
          _ -> fail $ unwords ["unimp",  show tp]

setupArgs :: SC.SharedContext
          -> Sym
          -> C.FnHandle init ret
          -> IO (Seq (SC.ExtCns SC.Term), C.RegMap Sym init)
setupArgs sc sym fn = do
  ecRef  <- newIORef Seq.empty
  regmap <- C.RegMap <$> Ctx.traverseFC (setupArg sc sym ecRef) (C.handleArgTypes fn)
  ecs    <- readIORef ecRef
  return (ecs, regmap)
