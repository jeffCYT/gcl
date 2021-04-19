{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}

module LSP.Handler (handlers) where

import Control.Monad.Except hiding (guard)
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Aeson as JSON
import qualified Data.Char as Char
import Data.Foldable (find)
import Data.List (sort)
import Data.Loc (Loc (..), Located (locOf), posCoff, posCol)
import Data.Text (Text, pack)
import qualified Data.Text as Text
import qualified Data.Text.Lazy as LazyText
import Error
import GCL.Expr (expand, runSubstM)
import qualified GCL.Type as TypeChecking
import GCL.WP (StructWarning)
import qualified GCL.WP as POGen
import GHC.Generics (Generic)
import LSP.Diagnostic (ToDiagnostics (toDiagnostics), locToRange)
import LSP.ExportPO ()
import LSP.Monad
import Language.LSP.Diagnostics (partitionBySource)
import Language.LSP.Server
import Language.LSP.Types hiding (TextDocumentSyncClientCapabilities (..))
import qualified Syntax.Abstract as A
import Syntax.Concrete (ToAbstract (toAbstract))
import qualified Syntax.Concrete as C
import Syntax.Parser
import Syntax.Predicate
  ( Origin (..),
    PO (..),
    Spec (..),
  )

-- handlers of the LSP server
handlers :: Handlers ServerM
handlers =
  mconcat
    [ -- custom methods, not part of LSP
      requestHandler (SCustomMethod "guacamole") $ \req responder -> do
        let RequestMessage _ i _ params = req
        -- JSON Value => Request => Response
        response <- case JSON.fromJSON params of
          JSON.Error msg -> do
            logText " --> CustomMethod: CannotDecodeRequest"
            return $ CannotDecodeRequest $ show msg ++ "\n" ++ show params
          JSON.Success request@(Req filepath kind) -> do
            logText $ " --> Custom Reqeust: " <> pack (show request)

            result <- readSavedSource filepath
            case result of
              Nothing -> pure NotLoaded
              Just source -> do
                -- send Diagnostics
                version <- case i of
                  IdInt n -> return n
                  IdString _ -> bumpCounter
                checkAndSendDiagnostics filepath source version
                -- convert Request to Response
                kinds <- case kind of
                  ReqInspect selStart selEnd -> do
                    updateSelection filepath (selStart, selEnd)
                    return $
                      asGlobalError $ do
                        (pos, _specs, _globalProps, _warnings) <- checkEverything filepath source (Just (selStart, selEnd))
                        return [ResInspect pos]
                  ReqRefine selStart selEnd -> do
                    result' <- readLatestSource filepath
                    case result' of
                      Nothing -> return [ResConsoleLog "no source"]
                      Just source' -> do
                        logText source'
                        let f = do
                              spec <- findPointedSpec filepath source' (selStart, selEnd)
                              case spec of
                                Nothing -> throwError $ Others "Cannot find pointed spec"
                                Just spec' -> do
                                  let payload = getSpecPayload source' spec'
                                  let indentationOfSpec = case specLoc spec' of
                                        NoLoc -> 0
                                        Loc pos _ -> posCol pos - 1
                                  let indentedPayload = Text.intercalate ("\n" <> Text.replicate indentationOfSpec " ") payload
                                  _ <- refine indentedPayload
                                  return (spec', indentedPayload)
                        case runM f of
                          Left err -> do
                            sendDiagnostics filepath 0 (toDiagnostics err)
                            return [ResError [globalError err]]
                          Right (spec, indentedPayload) -> do
                            let removeSpecOpen = TextEdit (locToRange (specLoc spec)) indentedPayload
                            let identifier = VersionedTextDocumentIdentifier (filePathToUri filepath) (Just 0)
                            let textDocumentEdit = TextDocumentEdit identifier (List [removeSpecOpen])
                            let change = InL textDocumentEdit
                            let workspaceEdit = WorkspaceEdit Nothing (Just (List [change]))
                            let applyWorkspaceEditParams = ApplyWorkspaceEditParams (Just "Resolve Spec") workspaceEdit
                            let responder' response = case response of
                                  Left _responseError -> return ()
                                  Right _value -> do
                                    -- ? ==> [!  !]
                                    result'' <- readLatestSource filepath
                                    case result'' of
                                      Nothing -> return ()
                                      Just source'' -> do
                                        logText "after"
                                        version' <- bumpCounter
                                        checkAndSendResponse filepath source'' version'
                                        checkAndSendDiagnostics filepath source'' version'

                            _ <- sendRequest SWorkspaceApplyEdit applyWorkspaceEditParams responder'
                            return []
                  ReqSubstitute index expr _subst -> return $
                    asGlobalError $ do
                      A.Program _ _ defns _ _ <- parseProgram filepath source
                      let expr' = runSubstM (expand (A.Subst expr _subst)) defns 1
                      return [ResSubstitute index expr']
                  ReqExportProofObligations -> return $
                    asGlobalError $ do
                      return [ResConsoleLog "Export"]
                  ReqDebug -> return $ error "crash!"
                return $ Res filepath kinds

        logText $ " <-- " <> pack (show response)
        responder $ Right $ JSON.toJSON response,
      -- when the client saved the document, store the text for later use
      notificationHandler STextDocumentDidSave $ \ntf -> do
        logText " --> TextDocumentDidSave"
        let NotificationMessage _ _ (DidSaveTextDocumentParams (TextDocumentIdentifier uri) text) = ntf
        case text of
          Nothing -> pure ()
          Just source ->
            case uriToFilePath uri of
              Nothing -> pure ()
              Just filepath -> do
                updateSource filepath source
                version <- bumpCounter
                checkAndSendResponse filepath source version
                checkAndSendDiagnostics filepath source version,
      -- when the client opened the document
      notificationHandler STextDocumentDidOpen $ \ntf -> do
        logText " --> TextDocumentDidOpen"
        let NotificationMessage _ _ (DidOpenTextDocumentParams (TextDocumentItem uri _ _ source)) = ntf
        case uriToFilePath uri of
          Nothing -> pure ()
          Just filepath -> do
            updateSource filepath source
            version <- bumpCounter
            checkAndSendResponse filepath source version
            checkAndSendDiagnostics filepath source version
    ]


--------------------------------------------------------------------------------

-- | Request
data ReqKind
  = ReqInspect Int Int
  | ReqRefine Int Int
  | ReqSubstitute Int A.Expr A.Subst
  | ReqExportProofObligations
  | ReqDebug
  deriving (Generic)

instance FromJSON ReqKind

instance Show ReqKind where
  show (ReqInspect x y) = "Inspect " <> show x <> " " <> show y
  show (ReqRefine i x) = "Refine #" <> show i <> " " <> show x
  show (ReqSubstitute i x y) = "Substitute #" <> show i <> " " <> show x <> " => " <> show y
  show ReqExportProofObligations = "ExportProofObligations"
  show ReqDebug = "Debug"

data Request = Req FilePath ReqKind
  deriving (Generic)

instance FromJSON Request

instance Show Request where
  show (Req _path kind) = show kind

checkAndSendResponse :: FilePath -> Text -> Int -> ServerM ()
checkAndSendResponse filepath source version = do
  lastSelection <- readLastSelection filepath
  let result = runM (checkEverything filepath source lastSelection)
  let response = case result of
        Left e -> Res filepath [ResError [globalError e]]
        Right (pos, specs, globalProps, warnings) -> Res filepath [ResOK (IdInt version) pos specs globalProps warnings]
  sendNotification (SCustomMethod "guacamole") $ JSON.toJSON response

checkAndSendDiagnostics :: FilePath -> Text -> Int -> ServerM ()
checkAndSendDiagnostics filepath source version = do
  -- send diagnostics
  diags <- do
    let result = runM $ checkEverything filepath source Nothing
    return $ case result of
      Left err -> toDiagnostics err
      Right (pos, _, _, warnings) -> concatMap toDiagnostics pos ++ concatMap toDiagnostics warnings
  sendDiagnostics filepath version diags

sendDiagnostics :: FilePath -> Int -> [Diagnostic] -> ServerM ()
sendDiagnostics filepath version diags = publishDiagnostics 100 (toNormalizedUri (filePathToUri filepath)) (Just version) (partitionBySource diags)

--------------------------------------------------------------------------------

-- | Given an interval of mouse selection, calculate POs within the interval, ordered by their vicinity
filterPOs :: (Int, Int) -> [PO] -> [PO]
filterPOs (selStart, selEnd) pos = opverlappedPOs
  where
    opverlappedPOs = reverse $ case overlapped of
      [] -> []
      (x : _) -> case locOf x of
        NoLoc -> []
        Loc start _ ->
          let same y = case locOf y of
                NoLoc -> False
                Loc start' _ -> start == start'
           in filter same overlapped
      where
        -- find the POs whose Range overlaps with the selection
        isOverlapped po = case locOf po of
          NoLoc -> False
          Loc start' end' ->
            let start = posCoff start'
                end = posCoff end' + 1
             in (selStart <= start && selEnd >= start) -- the end of the selection overlaps with the start of PO
                  || (selStart <= end && selEnd >= end) -- the start of the selection overlaps with the end of PO
                  || (selStart <= start && selEnd >= end) -- the selection covers the PO
                  || (selStart >= start && selEnd <= end) -- the selection is within the PO
                  -- sort them by comparing their starting position
        overlapped = reverse $ sort $ filter isOverlapped pos

type ID = LspId ('CustomMethod :: Method 'FromClient 'Request)

--------------------------------------------------------------------------------

type M = Except Error

runM :: M a -> Either Error a
runM = runExcept

ignoreError :: M [ResKind] -> [ResKind]
ignoreError program =
  case runM program of
    Left _err -> []
    Right val -> val

-- catches Error and convert it into a global ResError
asGlobalError :: M [ResKind] -> [ResKind]
asGlobalError program =
  case runM program of
    Left err -> [ResError [globalError err]]
    Right val -> val

-- catches Error and convert it into a local ResError with Hole id
asLocalError :: Int -> M [ResKind] -> [ResKind]
asLocalError i program =
  case runM program of
    Left err -> [ResError [localError i err]]
    Right val -> val

--------------------------------------------------------------------------------

-- | Parse with a parser
parse :: Parser a -> FilePath -> Text -> M a
parse p filepath = withExcept SyntacticError . liftEither . runParse p filepath . LazyText.fromStrict

-- | Parse the whole program
parseProgram :: FilePath -> Text -> M A.Program
parseProgram filepath source = toAbstract <$> parse pProgram filepath source

parseProgramC :: FilePath -> Text -> M C.Program
parseProgramC = parse pProgram

-- | Try to parse a piece of text in a Spec
refine :: Text -> M ()
refine = void . parse pStmts "<specification>"

-- | Type check + generate POs and Specs
checkEverything :: FilePath -> Text -> Maybe (Int, Int) -> M ([PO], [Spec], [A.Expr], [StructWarning])
checkEverything filepath source mouseSelection = do
  program@(A.Program _ globalProps _ _ _) <- parseProgram filepath source
  typeCheck program
  (pos, specs, warings) <- genPO program
  case mouseSelection of
    Nothing -> return (pos, specs, globalProps, warings)
    Just sel -> return (filterPOs sel pos, specs, globalProps, warings)

typeCheck :: A.Program -> M ()
typeCheck = withExcept TypeError . TypeChecking.checkProg

genPO :: A.Program -> M ([PO], [Spec], [StructWarning])
genPO = withExcept StructError . liftEither . POGen.sweep

tempGetSpecPositions :: FilePath -> Text -> M [Loc]
tempGetSpecPositions filepath source = do
  (_, specs, _) <- parseProgram filepath source >>= genPO
  return (map specLoc specs)

findPointedSpec :: FilePath -> Text -> (Int, Int) -> M (Maybe Spec)
findPointedSpec filepath source selection = do
  (_, specs, _) <- parseProgram filepath source >>= genPO
  return $ find (pointed selection) specs
  where
    pointed :: (Int, Int) -> Spec -> Bool
    pointed (start, end) spec = case specLoc spec of
      NoLoc -> False
      Loc open close ->
        (posCoff open <= start && start <= posCoff close)
          || (posCoff open <= end && end <= posCoff close)

getSpecPayload :: Text -> Spec -> [Text]
getSpecPayload source spec = case specLoc spec of
  NoLoc -> mempty
  Loc start end ->
    let payload = Text.drop (posCoff start) $ Text.take (posCoff end) source
        indentedLines = init $ tail $ Text.lines payload
        splittedIndentedLines = map (Text.break (not . Char.isSpace)) indentedLines
        smallestIndentation = minimum $ map (Text.length . fst) splittedIndentedLines
        trimmedLines = map (\(indentation, content) -> Text.drop smallestIndentation indentation <> content) splittedIndentedLines
     in trimmedLines

--------------------------------------------------------------------------------

-- | Response
data ResKind
  = ResOK ID [PO] [Spec] [A.Expr] [StructWarning]
  | ResInspect [PO]
  | ResError [(Site, Error)]
  | ResUpdateSpecPositions [Loc]
  | ResResolve Int -- resolves some Spec
  | ResSubstitute Int A.Expr
  | ResConsoleLog Text
  deriving (Generic)

instance ToJSON ResKind

instance Show ResKind where
  show (ResOK i pos specs props warnings) =
    "OK " <> show i <> " "
      <> show (length pos)
      <> " pos, "
      <> show (length specs)
      <> " specs, "
      <> show (length props)
      <> " props, "
      <> show (length warnings)
      <> " warnings"
  show (ResInspect pos) = "Inspect " <> show (length pos) <> " POs"
  show (ResError errors) = "Error " <> show (length errors) <> " errors"
  show (ResUpdateSpecPositions locs) = "UpdateSpecPositions " <> show (length locs) <> " locs"
  show (ResResolve i) = "Resolve " <> show i
  show (ResSubstitute i _) = "Substitute " <> show i
  show (ResConsoleLog x) = "ConsoleLog " <> show x

data Response
  = Res FilePath [ResKind]
  | CannotDecodeRequest String
  | NotLoaded
  deriving (Generic)

instance ToJSON Response

instance Show Response where
  show (Res _path kinds) = show kinds
  show (CannotDecodeRequest s) = "CannotDecodeRequest " <> s
  show NotLoaded = "NotLoaded"

--------------------------------------------------------------------------------

-- | Instances of ToJSON
instance ToJSON Origin

instance ToJSON PO

instance ToJSON Spec
