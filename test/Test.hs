{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wall -fno-warn-unused-top-binds #-}


import           Data.Char (isSpace)
import           Data.List (dropWhileEnd, isPrefixOf,intersperse)
import qualified Data.Map as Map
import           Data.Maybe (catMaybes)
import           System.Directory (listDirectory, doesDirectoryExist, doesFileExist, removeFile)
import           System.Exit (ExitCode(..))
import           System.FilePath ((<.>), (</>), takeBaseName, takeExtension)
import qualified System.Process as Proc
import           Text.Parsec (parse, (<|>), (<?>), string, many1, digit)
import           Text.Parsec.String (Parser)

import           Mir.SAWInterface (translateMIR, extractMIR, generateMIR)
import qualified Verifier.SAW.FiniteValue as FV
import qualified Verifier.SAW.Prelude as SC
import qualified Verifier.SAW.SCTypeCheck as SC
import qualified Verifier.SAW.SharedTerm as SC
import qualified Verifier.SAW.Typechecker as SC
import qualified Verifier.SAW.Simulator.Concrete as Conc

import           Test.Tasty (defaultMain, testGroup, TestTree)
import           Test.Tasty.HUnit (Assertion, testCaseSteps, assertBool, assertFailure)

import qualified Data.AIG.Interface as AIG



type OracleTest = FilePath -> String -> (String -> IO ()) -> Assertion



cruxOracleTest :: FilePath -> String -> (String -> IO ()) -> Assertion
cruxOracleTest dir name step = do
  
  step "Compiling and running oracle program"
  oracleOut <- compileAndRun dir name >>= \case
    Nothing -> assertFailure "failed to compile and run"
    Just out -> return out

  let orOut = dropWhileEnd isSpace oracleOut
  step ("Oracle output: " ++ orOut)

  (_cruxEC, cruxOutFull, _err) <- Proc.readProcessWithExitCode "cabal" ["new-exec", "crux-mir", dir </> name <.> "rs"] ""

  let cruxOut = dropWhileEnd isSpace cruxOutFull
  step ("Crux output: " ++ cruxOut ++ "\n")

  assertBool "crux doesn't match oracle" (orOut == cruxOut)


sawOracleTest :: FilePath -> String -> (String -> IO ()) -> Assertion
sawOracleTest dir name step = do
  sc <- SC.mkSharedContext
  step "Initializing saw-core Prelude"
  SC.tcInsertModule sc SC.preludeModule
  
  step "Compiling and running oracle program"
  oracleOut <- compileAndRun dir name >>= \case
    Nothing -> assertFailure "failed to compile and run"
    Just out -> return out

  step ("Oracle output: " ++ (dropWhileEnd isSpace oracleOut))

  step "Generating MIR JSON"
  collection <- generateMIR dir name 

  step "Tranlating MIR to Crucible"
  let mir = translateMIR collection
  
  step "Extracting function f"
  f <- extractMIR proxy sc mir "f"
  step "Extracting argument ARG"
  arg <- extractMIR proxy sc mir "ARG"
  step "Typechecking f(ARG)"
  app <- SC.scApply sc f arg
  rty <- SC.scTypeCheck sc Nothing app >>= \case
    Left e -> assertFailure $ "ill-typed result: " ++ concat (intersperse " " (SC.prettyTCError e))
    Right rty -> return rty
  ty <- FV.asFiniteType sc rty

  step "Parsing oracle output at inferred type"
  oracle <- case parse (parseRustFV ty) "oracleOut" oracleOut of
    Left e -> error $ "error parsing Rust output: " ++ show e
    Right (Just fv) -> FV.scFiniteValue sc fv
    Right Nothing -> assertFailure "panics not yet handled"

  step "Comparing oracle output"
  eq <- SC.scEq sc oracle app
  mm <- SC.scGetModuleMap sc
  assertBool "oracle output mismatch"
    (Conc.toBool (Conc.evalSharedTerm mm Map.empty eq))

main :: IO ()
main = defaultMain =<< suite

suite :: IO TestTree
suite = do trees <- sequence $
             [ --testGroup "saw"  <$> sequence [testDir sawOracleTest "test/conc_eval"  ]
               testGroup "crux" <$> sequence [testDir cruxOracleTest "test/conc_eval" ] ]
           return $ testGroup "mir-verifier" trees





-- For newSAWCoreBackend
proxy :: AIG.Proxy AIG.BasicLit AIG.BasicGraph
proxy = AIG.basicProxy

compileAndRun :: FilePath -> String -> IO (Maybe String)
compileAndRun dir name = do
  (ec, _, _) <- Proc.readProcessWithExitCode "rustc" [dir </> name <.> "rs", "--cfg", "with_main"] ""
  case ec of
    ExitFailure _ -> do
      putStrLn $ "rustc compilation failed for " ++ name
      return Nothing
    ExitSuccess -> do
      let execFile = "." </> name
      (ec', out, _) <- Proc.readProcessWithExitCode execFile [] ""
      doesFileExist execFile >>= \case
        True -> removeFile execFile
        False -> return ()
      case ec' of
        ExitFailure _ -> do
          putStrLn $ "non-zero exit code for test executable " ++ name
          return Nothing
        ExitSuccess -> return $ Just out


testDir :: OracleTest -> FilePath -> IO TestTree
testDir oracleTest dir = do
  let gen f | "." `isPrefixOf` takeBaseName f = return Nothing
      gen f | takeExtension f == ".rs" = return (Just (testCaseSteps name (oracleTest dir name)))
        where name = (takeBaseName f)
      gen f = doesDirectoryExist (dir </> f) >>= \case
        False -> return Nothing
        True -> Just <$> testDir oracleTest (dir </> f)
  fs <- listDirectory dir
  tcs <- mapM gen fs
  return (testGroup (takeBaseName dir) (catMaybes tcs))

-- | Parse the Rust program output into a finite value at a given type
parseRustFV :: FV.FiniteType -> Parser (Maybe FV.FiniteValue)
parseRustFV ft = panic <|> (Just <$> p)
  where
    panic = string "<<PANIC>>" *> pure Nothing
    p = case ft of
          FV.FTBit ->
            string "true" *> pure (FV.FVBit True)
            <|> string "false" *> pure (FV.FVBit False)
            <?> "boolean"
          FV.FTVec w FV.FTBit -> do
            i <- read <$> many1 digit
            return (FV.FVWord w i)
          FV.FTVec _n _elt -> error "unimplemented"
          FV.FTTuple _elts -> error "unimplemented"
          FV.FTRec _fields -> error "unimplemented"

