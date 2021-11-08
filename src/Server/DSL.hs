{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}

module Server.DSL where

import           Control.Monad.Cont
import           Control.Monad.Except
import           Control.Monad.Trans.Free
import           Control.Monad.Writer
import           Data.IntMap                    ( IntMap )
import           Data.List                      ( find
                                                , sortOn
                                                )
import qualified Data.List                     as List
import           Data.Loc                hiding ( fromLoc )
import           Data.Loc.Range
import           Data.Map                       ( Map )
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import           Error
import           GCL.Predicate
import           GCL.Predicate.Util             ( specPayloadWithoutIndentation
                                                )
import qualified GCL.Type                      as TypeChecking
import qualified GCL.WP                        as WP
import           GCL.WP.Type                    ( StructWarning )
import qualified Language.LSP.Types            as J
import           Prelude                 hiding ( span )
import           Pretty                         ( Pretty(pretty)
                                                , toText
                                                , vsep
                                                )
import           Render
import           Server.CustomMethod
import           Server.Handler.Diagnostic      ( Collect(collect) )
import           Server.Highlighting            ( collectHighlighting )
import           Server.TokenMap
import qualified Syntax.Abstract               as A
import           Syntax.Concrete                ( ToAbstract(toAbstract) )
import qualified Syntax.Concrete               as C
import           Syntax.Parser                  ( Parser
                                                , pProgram
                                                , pStmts
                                                , runParse
                                                )

--------------------------------------------------------------------------------

data Cache = Cache
  { cacheHighlighings :: Map Range J.SemanticTokenAbsolute
  , cacheTokenMap     :: TokenMap
  , cacheProgram      :: A.Program
    -- Proof Obligations 
  , cachePOs          :: [PO]
    -- Specs (holes)
  , cacheSpecs        :: [Spec]
    -- Global properties
  , cacheProps        :: [A.Expr]
    -- Warnings 
  , cacheWarnings     :: [StructWarning]
  , cacheRedexes      :: IntMap A.Redex
    -- counter (for generating fresh variables)
  , cacheCounter      :: Int
  }

instance Pretty Cache where
  pretty cache =
    "Cache { "
      <> vsep
           [ "POs: " <> pretty (cachePOs cache)
           , "Specs: " <> pretty (cacheSpecs cache)
           , "Props: " <> pretty (cacheProps cache)
           , "Warnings: " <> pretty (cacheWarnings cache)
           ]
      <> " }"

type Result = Either [Error] Cache

-- The "Syntax" of the DSL for handling LSP requests and responses
data Cmd next
  = EditText
      Range -- ^ Range to replace 
      Text -- ^ Text to replace with 
      (Text -> next) -- ^ Continuation with the text of the whole file after the edit

  -- | State for indicating whether we should ignore events like `STextDocumentDidChange` 
  | SetMute
      Bool
      next
  | GetMute (Bool -> next)

  | GetFilePath (FilePath -> next)

  | GetSource (Text -> next)

  -- | Store mouse selection 
  | SetLastSelection
      Range
      next
  -- | Read mouse selection 
  | GetLastSelection (Maybe Range -> next)
  -- | Each Response has a different ID, bump the counter of that ID
  | BumpResponseVersion (Int -> next)
  | Log Text next
  -- | Store the computed result 
  | SetCacheResult Result next
  -- | Read the computed result 
  | GetCachedResult (Maybe Result -> next)
  -- | SendDiagnostics from the LSP protocol 
  | SendDiagnostics [J.Diagnostic] next
  deriving (Functor)

type CmdM = FreeT Cmd (Except [Error])

runCmdM :: CmdM a -> Either [Error] (FreeF Cmd a (CmdM a))
runCmdM = runExcept . runFreeT

editText :: Range -> Text -> CmdM Text
editText range text = liftF (EditText range text id)

mute :: Bool -> CmdM ()
mute b = liftF (SetMute b ())

isMuted :: CmdM Bool
isMuted = liftF (GetMute id)

getFilePath :: CmdM FilePath
getFilePath = liftF (GetFilePath id)

getSource :: CmdM Text
getSource = liftF (GetSource id)

setLastSelection :: Range -> CmdM ()
setLastSelection selection = liftF (SetLastSelection selection ())

getLastSelection :: CmdM (Maybe Range)
getLastSelection = liftF (GetLastSelection id)

cacheResult :: Result -> CmdM ()
cacheResult result = liftF (SetCacheResult result ())

readCachedResult :: CmdM (Maybe Result)
readCachedResult = liftF (GetCachedResult id)

logText :: Text -> CmdM ()
logText text = liftF (Log text ())

bumpVersion :: CmdM Int
bumpVersion = liftF (BumpResponseVersion id)

sendDiagnostics :: [J.Diagnostic] -> CmdM ()
sendDiagnostics xs = do
  logText $ " ### Diagnostic " <> toText (length xs)
  liftF (SendDiagnostics xs ())

------------------------------------------------------------------------------

-- converts the "?" at a given location to "[!   !]"
-- and returns the modified source and the difference of source length
digHole :: Range -> CmdM Text
digHole range = do
  logText $ " ### DigHole " <> toText range
  let indent   = Text.replicate (posCol (rangeStart range) - 1) " "
  let holeText = "[!\n" <> indent <> "\n" <> indent <> "!]"
  editText range holeText

-- | Try to parse a piece of text in a Spec
refine :: Text -> Range -> CmdM (Spec, [Text])
refine source range = do
  result <- findPointedSpec
  case result of
    Nothing ->
      throwError [Others "Please place the cursor in side a Spec to refine it"]
    Just spec -> do
      source' <- getSource
      let payload = Text.unlines $ specPayloadWithoutIndentation source' spec
      -- HACK, `pStmts` will kaput if we feed empty strings into it
      let payloadIsEmpty = Text.null (Text.strip payload)
      if payloadIsEmpty then return () else void $ parse pStmts payload
      return (spec, specPayloadWithoutIndentation source' spec)
 where
  findPointedSpec :: CmdM (Maybe Spec)
  findPointedSpec = do
    (concrete, abstract) <- parseProgram source
    cache                <- sweep concrete abstract
    return $ find (withinRange range) (cacheSpecs cache)

typeCheck :: A.Program -> CmdM ()
typeCheck p = case TypeChecking.runTM (TypeChecking.checkProgram p) of
  Left  e -> throwError [TypeError e]
  Right v -> return v

sweep :: C.Program -> A.Program -> CmdM Cache
sweep concrete abstract@(A.Program _ _ globalProps _ _) =
  case WP.sweep abstract of
    Left  e -> throwError [StructError e]
    Right (pos, specs, warings, redexes, counter) -> do
      let highlighings = collectHighlighting concrete
      let tokenMap     = collectTokenMap abstract
      return $ Cache { cacheHighlighings = highlighings
                     , cacheTokenMap     = tokenMap
                     , cacheProgram      = abstract
                     , cachePOs          = List.sort pos
                     , cacheSpecs        = sortOn locOf specs
                     , cacheProps        = globalProps
                     , cacheWarnings     = warings
                     , cacheRedexes      = redexes
                     , cacheCounter      = counter
                     }

--------------------------------------------------------------------------------

-- | Parse with a parser
parse :: Parser a -> Text -> CmdM a
parse p source = do
  filepath <- getFilePath
  case runParse p filepath source of
    Left  errors -> throwError $ map SyntacticError errors
    Right val    -> return val

parseProgram :: Text -> CmdM (C.Program, A.Program)
parseProgram source = do
  concrete <- parse pProgram source
  case runExcept (toAbstract concrete) of
    Left  (Range start end) -> digHole (Range start end) >>= parseProgram
    Right abstract          -> return (concrete, abstract)

--------------------------------------------------------------------------------

generateResponseAndDiagnosticsFromResult :: Result -> CmdM [ResKind]
generateResponseAndDiagnosticsFromResult (Left  errors) = throwError errors
generateResponseAndDiagnosticsFromResult (Right cache ) = do
  let (Cache _ _ _ pos specs globalProps warnings _redexes _) = cache

  -- get Specs around the mouse selection
  lastSelection <- getLastSelection
  let overlappedSpecs = case lastSelection of
        Nothing        -> specs
        Just selection -> filter (withinRange selection) specs
  -- get POs around the mouse selection (including their corresponding Proofs)

  let withinPOrange sel po = case poAnchorLoc po of
        Nothing     -> withinRange sel po
        Just anchor -> withinRange sel po || withinRange sel anchor

  let overlappedPOs = case lastSelection of
        Nothing        -> pos
        Just selection -> filter (withinPOrange selection) pos
  -- render stuff
  let warningsSections =
        if null warnings then [] else map renderSection warnings
  let globalPropsSections = if null globalProps
        then []
        else map
          (\expr -> Section
            Plain
            [Header "Property" (fromLoc (locOf expr)), Code (render expr)]
          )
          globalProps
  let specsSections =
        if null overlappedSpecs then [] else map renderSection overlappedSpecs
  let poSections =
        if null overlappedPOs then [] else map renderSection overlappedPOs
  let sections = mconcat
        [warningsSections, specsSections, poSections, globalPropsSections]

  version <- bumpVersion
  let encodeSpec spec =
        ( specID spec
        , toText $ render (specPreCond spec)
        , toText $ render (specPostCond spec)
        , specRange spec
        )

  let responses =
        [ResDisplay version sections, ResUpdateSpecs (map encodeSpec specs)]
  let diagnostics = concatMap collect pos ++ concatMap collect warnings
  sendDiagnostics diagnostics

  return responses
