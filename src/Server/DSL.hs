{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}

module Server.DSL where

import Control.Monad.Cont
import Control.Monad.Except
import Control.Monad.Trans.Free
import Control.Monad.Writer
import Data.List (find, sortOn)
import Data.Loc
import Data.Loc.Range
import Data.Text (Text)
import qualified Data.Text as Text
import Error
import qualified GCL.Type as TypeChecking
import GCL.WP (StructWarning)
import qualified GCL.WP as WP
import Language.LSP.Types ( Diagnostic )
import qualified Syntax.Abstract as A
import Syntax.Concrete.ToAbstract
import Syntax.Parser (Parser, pProgram, pStmts, runParse)
import GCL.Predicate
import GCL.Predicate.Util ( specPayloadWithoutIndentation )
import Prelude hiding (span)
import Pretty (toText)
import qualified Data.List as List
import Server.CustomMethod 
import Render
import Server.Handler.Diagnostic ()
import Server.Stab (collect)

--------------------------------------------------------------------------------

type Result = Either [Error] ([PO], [Spec], [A.Expr], [StructWarning])

-- The "Syntax" of the DSL for handling LSP requests and responses
data Cmd next
  = EditText Range Text (Text -> next)
  | Mute Bool next
  | GetFilePath (FilePath -> next)
  | GetSource (Text -> next)
  | PutLastSelection Range next
  | GetLastSelection (Maybe Range -> next)
  | BumpResponseVersion (Int -> next)
  | Log Text next
  | CacheResult Result next
  | ReadCachedResult (Result -> next)
  | SendDiagnostics [Diagnostic] next
  deriving (Functor)

type CmdM = FreeT Cmd (Except [Error])

runCmdM :: CmdM a -> Either [Error] (FreeF Cmd a (CmdM a))
runCmdM = runExcept . runFreeT

editText :: Range -> Text -> CmdM Text
editText range text = liftF (EditText range text id)

mute :: Bool -> CmdM ()
mute b = liftF (Mute b ())

getFilePath :: CmdM FilePath
getFilePath = liftF (GetFilePath id)

getSource :: CmdM Text
getSource = liftF (GetSource id)

setLastSelection :: Range -> CmdM ()
setLastSelection selection = liftF (PutLastSelection selection ())

getLastSelection :: CmdM (Maybe Range)
getLastSelection = liftF (GetLastSelection id)

cacheResult :: Result -> CmdM ()
cacheResult result = liftF (CacheResult result ())

readCachedResult :: CmdM Result
readCachedResult = liftF (ReadCachedResult id)

logM :: Text -> CmdM ()
logM text = liftF (Log text ())

bumpVersion :: CmdM Int
bumpVersion = liftF (BumpResponseVersion id)

sendDiagnostics :: [Diagnostic] -> CmdM ()
sendDiagnostics xs = do
  logM $ " ### Diagnostic " <> toText (length xs)
  liftF (SendDiagnostics xs ())

------------------------------------------------------------------------------

-- converts the "?" at a given location to "[!   !]"
-- and returns the modified source and the difference of source length
digHole :: Range -> CmdM Text
digHole range = do
  logM $ " ### DigHole " <> toText range
  let indent = Text.replicate (posCol (rangeStart range) - 1) " "
  let holeText = "[!\n" <> indent <> "\n" <> indent <> "!]"
  editText range holeText

-- | Try to parse a piece of text in a Spec
refine :: Text -> Range -> CmdM (Spec, [Text])
refine source range  = do
  result <- findPointedSpec
  case result of
    Nothing -> throwError [Others "Please place the cursor in side a Spec to refine it"]
    Just spec -> do
      source' <- getSource
      let payload = Text.unlines $ specPayloadWithoutIndentation source' spec
      -- HACK, `pStmts` will kaput if we feed empty strings into it
      let payloadIsEmpty = Text.null (Text.strip payload)
      if payloadIsEmpty
        then return ()
        else void $ parse pStmts payload
      return (spec, specPayloadWithoutIndentation source' spec)
  where
    findPointedSpec :: CmdM (Maybe Spec)
    findPointedSpec = do
      program <- parseProgram source
      (_, specs, _, _) <- sweep program
      return $ find (withinRange range) specs

typeCheck :: A.Program -> CmdM ()
typeCheck p = case TypeChecking.runTM (TypeChecking.checkProg p) of
  Left e -> throwError [TypeError e]
  Right v -> return v

sweep :: A.Program -> CmdM ([PO], [Spec], [A.Expr], [StructWarning])
sweep program@(A.Program _ globalProps _ _ _) =
  case WP.sweep program of
    Left e -> throwError [StructError e]
    Right (pos, specs, warings) -> do
      return (List.sort pos, sortOn locOf specs, globalProps, warings)

--------------------------------------------------------------------------------

-- | Parse with a parser
parse :: Parser a -> Text -> CmdM a
parse p source = do
  filepath <- getFilePath
  case runParse p filepath source of
    Left errors -> throwError $ map SyntacticError errors
    Right val -> return val

parseProgram :: Text -> CmdM A.Program
parseProgram source = do
  concrete <- parse pProgram source
  case runExcept (toAbstract concrete) of
    Left NoLoc -> throwError [Others "NoLoc in parseProgram"]
    Left (Loc start end) -> digHole (Range start end) >>= parseProgram
    Right program -> return program

--------------------------------------------------------------------------------



generateResponseAndDiagnosticsFromResult :: Result -> CmdM [ResKind]
generateResponseAndDiagnosticsFromResult (Left errors) = throwError errors
generateResponseAndDiagnosticsFromResult (Right (pos, specs, globalProps, warnings))
  = do
  -- leave only POs & Specs around the mouse selection
    lastSelection <- getLastSelection
    let overlappedSpecs = case lastSelection of
          Nothing  -> specs
          Just sel -> filter (withinRange sel) specs
    let overlappedPOs = case lastSelection of
          Nothing  -> pos
          Just sel -> filter (withinRange sel) pos
    -- render stuff
    let warningsSection = if null warnings
          then []
          else headerE "Warnings" : map renderBlock warnings
    let globalPropsSection = if null globalProps
          then []
          else headerE "Global Properties" : map renderBlock globalProps
    let specsSection = if null overlappedSpecs
          then []
          else headerE "Specs" : map renderBlock overlappedSpecs
    let poSection = if null overlappedPOs
          then []
          else headerE "Proof Obligations" : map renderBlock overlappedPOs
    let blocks = mconcat
          [warningsSection, specsSection, poSection, globalPropsSection]

    version <- bumpVersion
    let encodeSpec spec =
          ( specID spec
          , toText $ render (specPreCond spec)
          , toText $ render (specPostCond spec)
          , specRange spec
          )

    let responses =
          [ResDisplay version blocks, ResUpdateSpecs (map encodeSpec specs)]
    let diagnostics =
          concatMap collect pos ++ concatMap collect warnings
    sendDiagnostics diagnostics

    return responses
