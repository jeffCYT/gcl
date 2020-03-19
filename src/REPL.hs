{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module REPL where

import           Control.Monad.State     hiding ( guard )
-- import Control.Monad.Writer hiding (guard)
import           Control.Monad.Except    hiding ( guard )

import           Data.Aeson              hiding ( Error )
import qualified Data.ByteString.Lazy.Char8    as BS
import qualified Data.ByteString.Char8         as Strict
import           Data.Text.Lazy                 ( Text )
import qualified Data.Text.Lazy.IO             as Text
import           Data.Loc
import           GHC.Generics
import           System.IO
import           Control.Exception              ( IOException
                                                , try
                                                )

import           Error
import           GCL.WP                         ( wpProg
                                                , runWP
                                                )
import           GCL.WP2
import qualified GCL.WP2                       as WP2
-- import GCL.Type as Type
import           Syntax.Parser.Lexer            ( TokStream )
import qualified Syntax.Parser.Lexer           as Lexer
import qualified Syntax.Parser                 as Parser
import qualified Syntax.Concrete               as Concrete
import qualified Syntax.Predicate              as Predicate
import           Syntax.Predicate               ( Spec
                                                , PO
                                                , Origin
                                                )
import           Syntax.Location                ( )

--------------------------------------------------------------------------------
-- | The REPL Monad

-- State
data REPLState = REPLState
  { replFilePath :: Maybe FilePath
  , replProgram :: Maybe Concrete.Program
  , replStruct :: Maybe Predicate.Struct
  }

initREPLState :: REPLState
initREPLState = REPLState Nothing Nothing Nothing

-- Monad
type REPLM = ExceptT Error (StateT REPLState IO)

runREPLM :: REPLM a -> IO (Either Error a)
runREPLM f = evalStateT (runExceptT f) initREPLState

--------------------------------------------------------------------------------

loop :: REPLM ()
loop = do
  request <- recv
  result  <- handleRequest request
  case result of
    Just response -> do
      send response
      loop
    Nothing -> return ()

catchGlobalError :: REPLM (Maybe Response) -> REPLM (Maybe Response)
catchGlobalError program =
  program `catchError` (\err -> return $ Just $ Error [globalError err])

catchLocalError :: Int -> REPLM (Maybe Response) -> REPLM (Maybe Response)
catchLocalError i program =
  program `catchError` (\err -> return $ Just $ Error [localError i err])

-- returns Nothing to break the REPL loop
handleRequest :: Request -> REPLM (Maybe Response)
handleRequest (Load filepath) = catchGlobalError $ do
  (pos, specs) <- load filepath
  return $ Just $ OK pos specs
handleRequest (Refine i payload) = catchLocalError i $ do
  _ <- refine payload
  return $ Just $ Resolve i
handleRequest (InsertAssertion i) = catchGlobalError $ do
  expr <- insertAssertion i
  return $ Just $ Insert i expr
handleRequest Debug = error "crash!"
handleRequest Quit  = return Nothing

load :: FilePath -> REPLM ([PO], [Spec])
load filepath = do
  persistFilePath filepath

  result <-
    liftIO $ try $ Text.readFile filepath :: REPLM (Either IOException Text)
  case result of
    Left  _   -> throwError $ CannotReadFile filepath
    Right raw -> do
      tokens  <- scan filepath raw
      program <- parseProgram filepath tokens
      persistProgram program
      struct <- toStruct program
      persistStruct struct
      sweep2 struct

refine :: Text -> REPLM ()
refine payload = do
  _ <- scan "<spec>" payload >>= parseSpec
  return ()

insertAssertion :: Int -> REPLM Concrete.Expr
insertAssertion n = do
  program <- getProgram
  struct  <- getStruct
  withExceptT StructError2 $ liftEither $ runWPM $ do
    let pos = case locOf program of
          Loc p _ -> linePos (posFile p) n
          NoLoc   -> linePos "<untitled>" n
    case Predicate.precondAtLine n struct of
      Nothing -> throwError $ PreconditionUnknown (Loc pos pos)
      Just x  -> return $ Predicate.toExpr x

--------------------------------------------------------------------------------

persistFilePath :: FilePath -> REPLM ()
persistFilePath filepath = modify $ \s -> s { replFilePath = Just filepath }

persistProgram :: Concrete.Program -> REPLM ()
persistProgram program = modify $ \s -> s { replProgram = Just program }

persistStruct :: Predicate.Struct -> REPLM ()
persistStruct struct = modify $ \s -> s { replStruct = Just struct }

getProgram :: REPLM Concrete.Program
getProgram = do
  result <- gets replProgram
  case result of
    Nothing -> throwError NotLoaded
    Just p  -> return p

getStruct :: REPLM Predicate.Struct
getStruct = do
  result <- gets replStruct
  case result of
    Nothing -> throwError NotLoaded
    Just p  -> return p

--------------------------------------------------------------------------------

scan :: FilePath -> Text -> REPLM TokStream
scan filepath = withExceptT LexicalError . liftEither . Lexer.scan filepath

parse :: Parser.Parser a -> FilePath -> TokStream -> REPLM a
parse parser filepath =
  withExceptT SyntacticError . liftEither . Parser.parse parser filepath

parseProgram :: FilePath -> TokStream -> REPLM Concrete.Program
parseProgram = parse Parser.program

toStruct :: Concrete.Program -> REPLM Predicate.Struct
toStruct = withExceptT StructError2 . liftEither . runWPM . WP2.programToStruct

parseSpec :: TokStream -> REPLM [Concrete.Stmt]
parseSpec = parse Parser.specContent "<specification>"

sweep1 :: Concrete.Program -> REPLM ((Predicate.Pred, [PO]), [Spec])
sweep1 (Concrete.Program _ statements _) =
  withExceptT StructError $ liftEither $ runWP (wpProg statements)

sweep2 :: Predicate.Struct -> REPLM ([PO], [Spec])
sweep2 struct = withExceptT StructError2 $ liftEither $ runWPM $ do
  pos   <- runPOM $ genPO struct
  specs <- runSpecM $ genSpec struct
  return (pos, specs)

--------------------------------------------------------------------------------

-- typeCheck :: Concrete.Program -> Either Error ()
-- typeCheck = first (\x -> [TypeError x]) . Type.runTM . Type.checkProg

-- execute :: Concrete.Program -> Either Error [Exec.Store]
-- execute program = if null errors then Right stores else Left errors
--   where
--     errors = map ExecError $ lefts results
--     (results, stores) = unzip $ Exec.runExNondet (Exec.execProg program) Exec.prelude

recv :: FromJSON a => REPLM a
recv = do
  raw <- liftIO Strict.getLine
  case decode (BS.fromStrict raw) of
    Nothing -> throwError CannotDecodeRequest
    Just x  -> return x

send :: ToJSON a => a -> REPLM ()
send payload = liftIO $ do
  Strict.putStrLn $ BS.toStrict $ encode $ payload
  hFlush stdout

--------------------------------------------------------------------------------
-- | Request


data Request = Load FilePath | Refine Int Text | InsertAssertion Int | Debug | Quit
  deriving (Generic)

instance FromJSON Request where
instance ToJSON Request where

--------------------------------------------------------------------------------
-- | Response

data Response
  = OK [PO] [Spec]
  | Error [(Site, Error)]
  | Resolve Int -- resolves some Spec
  | Insert Int Concrete.Expr
  deriving (Generic)

instance ToJSON Response where

--------------------------------------------------------------------------------
-- | Instances of ToJSON

instance ToJSON Origin where
instance ToJSON PO where
instance ToJSON Spec where
