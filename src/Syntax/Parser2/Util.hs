{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use camelCase" #-}
{-# LANGUAGE RecordWildCards #-}

module Syntax.Parser2.Util
  ( M
  , Parser
  , runM
  , getLastToken
  , getLoc
  , withLoc
  , getRange
  , withRange
  , symbol
  , extract
  , ignore
  , ignoreP
  , sepByAlignmentOrSemi
  , sepByAlignmentOrSemi1
  , sepByAlignment
  , sepByAlignment1
  ) where

import           Control.Monad.State
import           Data.Loc
import           Data.Loc.Range
import           Data.Map                       ( Map )
import qualified Data.Map                      as Map
import           Data.Set                       ( Set )
import qualified Data.Set                      as Set
import           Data.Void
import           Syntax.Parser2.Lexer           ( Tok(..)
                                                , TokStream
                                                )
import           Text.Megaparsec         hiding ( Pos
                                                , State
                                                , between
                                                )
import qualified Text.Megaparsec    as Mega
import qualified Data.List.NonEmpty as NEL
import Debug.Trace

--------------------------------------------------------------------------------
-- | Source location bookkeeping

type M = State Bookkeeping

type ID = Int
data Bookkeeping = Bookkeeping
  { currentLoc :: Loc         -- current Loc mark
  , lastToken  :: Maybe Tok   -- the last accepcted token
  , opened     :: Set ID      -- waiting to be moved to the "logged" map
                              -- when the starting position of the next token is determined
  , logged     :: Map ID Loc  -- waiting to be removed when the ending position is determined
  , index      :: Int         -- for generating fresh IDs
  , indentStack:: [L Tok]     -- Recording the tokens to indent/align to.
  }

runM :: State Bookkeeping a -> a
runM f = evalState f (Bookkeeping NoLoc Nothing Set.empty Map.empty 0 [])

getCurrentLoc :: M Loc
getCurrentLoc = gets currentLoc

getLastToken :: M (Maybe Tok)
getLastToken = gets lastToken

-- | Returns an ID (marking the start of the range of some source location)
markStart :: M ID
markStart = do
  i <- gets index
  modify $ \st -> st { index = succ i, opened = Set.insert i (opened st) }
  return i

-- | Returns the range of some source location.
--   The range starts from where the ID is retreived, and ends from here
markEnd :: ID -> M Loc
markEnd i = do
  end       <- getCurrentLoc
  loggedPos <- gets logged
  let loc = case Map.lookup i loggedPos of
        Nothing    -> NoLoc
        Just start -> start <--> end
  modify $ \st -> st { logged = Map.delete i loggedPos }
  return loc

-- | Updates the current source location
updateLoc :: Loc -> M ()
updateLoc loc = do
  set <- gets opened
  let addedLoc = Map.fromSet (const loc) set
  modify $ \st -> st { currentLoc = loc
                     , opened     = Set.empty
                     , logged     = Map.union (logged st) addedLoc
                     }

-- | Updates the latest scanned token
updateToken :: Tok -> M ()
updateToken tok = modify $ \st -> st { lastToken = Just tok }

--------------------------------------------------------------------------------
-- | Helper functions

type Parser = ParsecT Void TokStream M

getLoc :: Parser a -> Parser (a, Loc)
getLoc parser = do
  i      <- lift markStart
  result <- parser
  loc    <- lift (markEnd i)
  return (result, loc)

getRange :: Parser a -> Parser (a, Range)
getRange parser = do
  (result, loc) <- getLoc parser
  case loc of
    NoLoc         -> error "NoLoc when getting srcloc info from a token"
    Loc start end -> return (result, Range start end)

withLoc :: Parser (Loc -> a) -> Parser a
withLoc parser = do
  (result, loc) <- getLoc parser
  return $ result loc

withRange :: Parser (Range -> a) -> Parser a
withRange parser = do
  (result, range) <- getRange parser
  return $ result range

-- Functions below are for indentation.

-- insertAlignIndentReq :: Pos -> Parser ()
-- insertAlignIndentReq pos = do
--   stack <- gets indentStack
--   modify $ \st->st { indentStack = (pos,False):stack }

insertIndentReq :: L Tok -> Parser ()
insertIndentReq tok = do
  stack <- gets indentStack
  modify $ \st->st { indentStack = tok:stack }

popIndentReq :: Parser (Maybe (L Tok))
popIndentReq = do
  stack <- gets indentStack
  case stack of
    [] -> return Nothing
    p : ps -> do
      modify $ \st->st {indentStack = ps}
      return (Just p)

lastIndentReq :: Parser (Maybe (L Tok))
lastIndentReq = do
  stack <- gets indentStack
  case stack of
    [] -> return Nothing
    tok : _ -> return (Just tok)

fitsIndentReq :: L Tok -> Maybe (L Tok) -> Bool
fitsIndentReq tokToCheck indentReq = case indentReq of
  Nothing -> True
  Just tokToAlign ->
    (tokToCheck `strictEq` tokToAlign) 
      --If the token is the same to the leftTip(the token to align/indent to).
      -- This could happen when backtracking happens;
      -- For example, in 'definition = choice [try funcDefnSig, typeDefn, funcDefnF]',
      -- the starts of both funcDefnSig and funcDefnF are identifiers, when funcDefnSig fails then goes to funcDefnF,
      -- the starting identifier would be checked another once.
    || 
    (colOf tokToCheck > colOf tokToAlign)
  where
    colOf = posCol . (\(Loc s _)->s) . locOf
    strictEq (L l1 t1) (L l2 t2) = l1==l2 && t1==t2


-- an ideal method which doesn't work: 
-- * parse -> if success, indentCheck(without touching parser state), manually fail it when indentCheck fails
extractWithIndentCheck :: (L Tok -> Maybe (L Tok,a)) -> Parser a
extractWithIndentCheck tokpred = do
  ir <- lastIndentReq
  let f (lt,a) = do
        guard $ lt `fitsIndentReq` ir
        return a
  pr <- observing $ lookAhead anySingle --later indent check needs a token
  case pr of
    Left _ -> do -- safe to assume that indentation won't be involved since there's no next token
      (_,a) <- token tokpred Set.empty
      return a
    Right ltok -> do
      -- token (tokpred >=> f) Set.empty
      r <- observing $ token (tokpred >=> f) Set.empty
      case r of
        Left pe -> case pe of -- the extraction failed
          TrivialError _ m_ei set -> do
            if ltok `fitsIndentReq` ir
            then -- not caused by indentation error
              failure m_ei set
            else -- caused by indentation error, we need to proceed to adding error msg
              case m_ei of -- getting original error position
              Nothing -> failureWithoutLoc
              Just ei -> case ei of
                Tokens ((L loc errtok) NEL.:| tos) -> 
                  failure (Just$Tokens (newErrLTok loc errtok NEL.:| tos) ) set
                Label _ -> failureWithoutLoc --might need to change in the future
                EndOfInput -> failureWithoutLoc --a case that might not going to happen, for we filtered out the case at 'observing $ lookAhead anySingle'
              where 
                fromJust Nothing = error "An error that shouldn't happen here: fitsIndentReq==False implies that 'ir' is a Just."
                fromJust (Just x)= x
                irtok = fromJust ir
                lineNum = posLine $ (\(Loc s _)->s) $ locOf irtok
                newMsg = NEL.fromList $ "token '"<>show ltok<>"' not indent to '"<> show irtok<>"' of line "<>show lineNum
                newErrLTok loc errtok = L loc (ErrTokIndent errtok (unLoc irtok) lineNum)
                failureWithoutLoc = failure (Just$Label newMsg) set
          FancyError _ set -> fancyFailure set --We're not handling fancy errors yet.
        
        Right a -> return a -- successfully extract a will-indented token
      

  -- st <- getParserState
  -- (ltok, a) <- token tokpred Set.empty
  -- ir <- lastIndentReq
  -- if ltok `fitsIndentReq` ir
  -- then return a
  -- else do
  --   setParserState st
  --   registerFailure (Just $ Label (NEL.fromList $ "token '"<>show ltok<>"' not indent to token:"<> show ir )) Set.empty
  --   snd <$> token (const Nothing) Set.empty


--------------------------------------------------------------------------------
-- | Combinators

-- Parsing with bookkeeping actions: symbol, extract
-- Any parser should be built upon these combinators.

-- Create a parser of some symbol (while respecting source locations)
symbol :: Tok -> Parser Loc
symbol t = do
  -- ir <- lastIndentReq
  -- loctok@(L loc tok) <- satisfy (\lt@(L _ t') -> t == t' && lt `fitsIndentReq` ir)
  (loc, tok) <- extractWithIndentCheck (\lt@(L l t') -> if t == t' then Just (lt,(l,t')) else Nothing)
  lift $ do
    updateLoc loc
    updateToken tok
  return loc

-- Useful for extracting values from a Token 
extract :: (Tok -> Maybe a) -> Parser a
extract f = do
  -- ir <- lastIndentReq
  let p loctok@(L l tok') = do
        --guard $ loctok `fitsIndentReq` ir
        (\result->(loctok, (result,l,tok'))) <$> f tok'
  -- (result, loctok@(L loc tok)) <- token p Set.empty
  (result, loc, tok) <- extractWithIndentCheck p 
  lift $ do
    updateLoc loc
    updateToken tok
  return result

-- Create a parser of some symbol, that doesn't update source locations
-- effectively excluding it from source location tracking
ignore :: Tok -> Parser ()
ignore t = do
  L _ tok <- satisfy ((==) t . unLoc)
  lift $ updateToken tok
  return ()

-- The predicate version of `ignore`
ignoreP :: (Tok -> Bool) -> Parser ()
ignoreP p = do
  L _ tok <- satisfy (p . unLoc)
  lift $ updateToken tok
  return ()


-- combinators for indentation
-- the design principle of indentation constraints is to reduce ambiguity

-- The input Parser should be built from either 'symbol' or 'extract', or it'll raise NoLoc error when doing 'getRange'.
-- This is because the loc being extracted inside 'getRange'(and 'getLoc') is generated by bookkeeping actions: updateLoc,
-- which is only been done in 'symbol' and 'extract'.
-- So parsers supported by Megaparsec like 'anySingle' cannot be used here.

indentTo :: Parser a -> L Tok -> Parser a
indentTo p tok = do
  insertIndentReq tok
  x <- observing p
  _ <- popIndentReq 
  -- The requirement needs to be popped no matter the parser went successfully or not,
  -- because Bookkeeping is not back-trackable (cannot just undo insertion of IndentReq).
  case x of
    Left pe -> case pe of
      TrivialError _ m_ei set -> failure m_ei (Set.insert (Label (NEL.fromList $ "token indent to '"<>show tok<>"' of line "<>show lineNum)) set)
        where
          lineNum = posLine $ (\(Loc s _)->s) $ locOf tok
      FancyError _ set -> fancyFailure set
    Right r -> return r

alignAndIndentBodyTo :: Parser a -> L Tok -> Parser a
alignAndIndentBodyTo p tokToAlign = do
  tok <- lookAhead anySingle
  if colOf tok == colOf tokToAlign
    then p `indentTo` tok
    else failure Nothing (Set.fromList [Label (NEL.fromList $ "token align to '"<>show tokToAlign<>"' of line "<>show lineNum)])
  where 
    colOf = posCol . (\(Loc s _)->s) . locOf
    lineNum = posLine $ (\(Loc s _)->s) $ locOf tokToAlign



sepByAlignmentOrSemi :: Parser a -> Parser [a]
sepByAlignmentOrSemi parser = 
    do
      tok <- try $ lookAhead anySingle
      sepByAlignmentOrSemiHelper tok True parser
  <|>
    return []

sepByAlignmentOrSemi1 :: Parser a -> Parser [a]
sepByAlignmentOrSemi1 parser = do
  tokToAlign <- lookAhead anySingle <?> "anything to start the block"
  x <- parser `indentTo` tokToAlign
  xs <- sepByAlignmentOrSemiHelper tokToAlign True parser
  return (x:xs)

sepByAlignmentOrSemiHelper :: L Tok -> Bool -> Parser a -> Parser [a]
sepByAlignmentOrSemiHelper tokToAlign useSemi parser = do
  let oneLeadByAlign = parser `alignAndIndentBodyTo` tokToAlign
      oneLeadBySemi =  symbol TokSemi *> parser `indentTo` tokToAlign
  let semiParser = if useSemi then oneLeadBySemi else empty
  many (semiParser <|> oneLeadByAlign)

sepByAlignment :: Parser a -> Parser [a]
sepByAlignment parser = do
    do
      tok <- try $ lookAhead anySingle
      sepByAlignmentOrSemiHelper tok False parser
  <|>
    return []

sepByAlignment1 :: Parser a -> Parser [a]
sepByAlignment1 parser = do
  tokToAlign <- lookAhead anySingle <?> "anything to start the block"
  x <- parser `indentTo` tokToAlign
  xs <- sepByAlignmentOrSemiHelper tokToAlign False parser
  return (x:xs)