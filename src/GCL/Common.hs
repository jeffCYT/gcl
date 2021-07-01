{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
module GCL.Common where

import Data.Text(Text)
import qualified Data.Text as Text
import Data.Loc ( Loc(..), Loc, Located(..) )
import Control.Monad (liftM2)
import Data.Map (Map)
import Syntax.Common (Name(..), nameToText)
import Data.Set (Set, (\\))
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Syntax.Abstract as A
import qualified Syntax.Abstract.Util as A
import GCL.Predicate (Pred (..))
import Control.Monad.RWS (RWST(..))
import Control.Monad.State (StateT(..))

-- Monad for generating fresh variable
class Monad m => Fresh m where
  fresh :: m Int
  freshText :: m Text
  freshWithLabel :: Text -> m Text
  freshTexts :: Int -> m [Text]
  -- freshName :: m Name

  freshText =
    (\i -> Text.pack ("?m_" ++ show i)) <$> fresh

  freshWithLabel l =
    (\i -> Text.pack ("?" ++ Text.unpack l ++ "_" ++ show i)) <$> fresh

  freshTexts 0 = return []
  freshTexts n = liftM2 (:) freshText (freshTexts (n - 1))


freshName :: Fresh m => Loc -> m Name
freshName l = Name <$> freshText <*> pure l

freshName' :: Fresh m => m Name
freshName' = freshName NoLoc

type FreshState = Int

initFreshState :: FreshState
initFreshState = 0

type Subs a = Map Name a
type Env a = Map Name a

emptySubs :: Subs a
emptySubs = mempty

emptyEnv :: Env a
emptyEnv = mempty

-- Monad for free variable
class Free a where
  fv :: a -> Set Name

occurs :: Free a => Name -> a -> Bool
occurs n x = n `Set.member` fv x

instance Free a => Free (Subs a) where
  fv = Set.unions . Map.map fv

instance Free A.Type where
  fv (A.TBase _ _) = mempty
  fv (A.TArray _ t _) = fv t
  fv (A.TFunc t1 t2 _) = fv t1 <> fv t2
  fv (A.TVar x _) = Set.singleton x

instance Free A.Expr where
  fv (A.Paren expr _) = fv expr
  fv (A.Var x _) = Set.singleton x
  fv (A.Const x _) = Set.singleton x
  fv (A.Op _) = mempty
  fv (A.Lit _ _) = mempty
  fv (A.Chain a _ b _) = fv a <> fv b
  fv (A.App e1 e2 _) = fv e1 <> fv e2
  fv (A.Lam x e _) = fv e \\ Set.singleton x
  fv (A.Quant op xs range term _) =
    (fv op <> fv range <> fv term) \\ Set.fromList xs
  fv (A.Hole _) = mempty -- banacorn: `subs` has been always empty anyway
  -- concat (map freeSubst subs) -- correct?
  fv (A.Subst _ _ after) = fv after
  fv (A.ArrIdx e1 e2 _) = fv e1 <> fv e2
  fv (A.ArrUpd e1 e2 e3 _) = fv e1 <> fv e2 <> fv e3

instance Free A.Bindings where
  fv = fv . A.bindingsToExpr

-- class for data that is substitutable
class Substitutable a b where
  subst :: Subs a -> b -> b

compose :: Substitutable a a => Subs a -> Subs a -> Subs a
s1 `compose` s2 = s1 <> Map.map (subst s1) s2

instance {-# INCOHERENT #-} Substitutable a b => Substitutable a [b] where
  subst = map . subst

instance Substitutable A.Type A.Type where
  subst _ t@(A.TBase _ _) = t
  subst s (A.TArray i t l) = A.TArray i (subst s t) l
  subst s (A.TFunc t1 t2 l) = A.TFunc (subst s t1) (subst s t2) l
  subst s t@(A.TVar x _) = Map.findWithDefault t x s

instance Substitutable A.Expr A.Expr where
  subst s (A.Paren expr l) = A.Paren (subst s expr) l
  subst _ lit@A.Lit {} = lit
  subst s v@(A.Var n _) = 
    case Map.lookup n s of
      Just v' -> subst (Map.delete n s) v'
      Nothing -> v
  subst s c@(A.Const n _) = 
    case Map.lookup n s of
      Just c' -> subst (Map.delete n s) c'
      Nothing -> c
  subst _ o@A.Op {} = o
  subst s (A.Chain a op b l) = A.Chain (subst s a) op (subst s b) l
  subst s (A.App a b l) =
    let a' = subst s a in
    let b' = subst s b in
      case a' of
        A.Lam x body _ -> subst (Map.singleton x b') body
        A.Subst _ _ (A.Lam x body _) -> subst (Map.singleton x b') body
        _ -> A.App a' b' l
  subst s (A.Lam x e l) =
    let s' = Map.withoutKeys s (Set.singleton x) in
    A.Lam x (subst s' e) l
  subst _ h@A.Hole {} = h
  subst s (A.Quant qop xs rng t l) =
    let s' = Map.withoutKeys s (Set.fromList xs) in
    A.Quant (subst s' qop) xs (subst s' rng) (subst s' t) l
  subst s1 (A.Subst before s2 after) = A.Subst (subst s1 before) s2 (subst s1 after)
  subst s (A.ArrIdx e1 e2 l) =
    A.ArrIdx (subst s e1) (subst s e2) l
  subst s (A.ArrUpd e1 e2 e3 l) =
    A.ArrUpd (subst s e1) (subst s e2) (subst s e3) l

bindingToSubst :: Subs A.Bindings -> A.Expr -> A.Expr
bindingToSubst = subst . Map.map A.bindingsToExpr 

instance {-# OVERLAPPABLE #-} Substitutable a b => Substitutable (Maybe a) b where
  subst = subst . Map.mapMaybe id

-- should make sure `fv Bindings` and `fv Expr` are disjoint before substitution
instance Substitutable A.Bindings A.Expr where
  subst sub expr =
    let s = shrinkSubs expr sub in
    if null s
    then expr
    else
    case expr of
      (A.Paren e l) -> A.Paren (subst s e) l
      A.Lit {} -> expr
      (A.Var n _) ->
        let s' = Map.delete n s in
        case Map.lookup n s of
          Just (A.LetBinding v) -> A.Subst expr s (subst s' v)
          Just v -> bindingToSubst s' (A.bindingsToExpr v) 
          Nothing -> expr

-- (P, let binding c), c --subst (n // s)--> c'
-- ---------------------------------------------
-- P --[s]--> c'  

-- (P, _ c), c --subst (n // s)--> c'
-- ----------------------------------
-- c'

      (A.Const n _) ->
        let s' = Map.delete n s in
        case Map.lookup n s of
          Just (A.LetBinding c) -> A.Subst expr s (subst s' c)
          Just c -> bindingToSubst s' (A.bindingsToExpr c)
          Nothing -> expr
      A.Op {} -> expr
      (A.Chain a op b l) -> A.Chain (subst s a) op (subst s b) l
      A.App a b l ->
        let a' = subst s a in
        let b' = subst s b in
        let expr' = A.App a' b' l in
        let (s', r) = betaReduce expr' in
        if a == a'
        then reduceSubs expr' s' r
        else reduceSubs (reduceSubs expr s expr') s' r
      (A.Lam x e l) ->
        let s' = Map.withoutKeys s (Set.singleton x) in
        let e' = subst s' e in
        reduceSubs expr s (A.Lam x e' l)
      A.Hole {} -> expr
      (A.Quant qop xs rng t l) ->
        let s' = Map.withoutKeys s (Set.fromList xs) in
        A.Quant (subst s' qop) xs (subst s' rng) (subst s' t) l
      A.Subst b s1 a ->
        case b of
          A.Subst b1 sb1 (A.App b2a b2b l)
            | isAllApp b && isAllBetaBindings s1 ->
              let b2a' = subst s b2a in
              let b2b' = subst s b2b in
              let b2' = A.App b2a' b2b' l in
              let (sb2, a') = betaReduce b2' in
              if b2a == b2a'
              then reduceSubs (A.Subst b1 sb1 b2') sb2 a'
              else reduceSubs (reduceSubs b s b2') sb2 a'
          A.App b1 b2 l
            | isAllBetaBindings s1 ->
              let b1' = subst s b1 in
              let b2' = subst s b2 in
              let b' = A.App b1' b2' l in
              let (sb, a') = betaReduce b' in
              if b1 == b1'
              then reduceSubs b' sb a'
              else reduceSubs (reduceSubs b s b') sb a'
          _ ->
            let a' = getSubstAfter (subst s a) in
            A.Subst expr s a'
      A.ArrIdx e1 e2 l ->
        A.ArrIdx (subst s e1) (subst s e2) l
      A.ArrUpd e1 e2 e3 l ->
        A.ArrUpd (subst s e1) (subst s e2) (subst s e3) l


shrinkSubs :: A.Expr -> Subs a -> Subs a
shrinkSubs expr = Map.filterWithKey (\n _ -> n `Set.member` fv expr)

isAllBetaBindings :: Subs A.Bindings -> Bool
isAllBetaBindings = Map.foldl f True
  where
    f t A.BetaBinding {} = t
    f _ _ = False

isAllLetBindings :: Subs A.Bindings -> Bool
isAllLetBindings = Map.foldl f True
  where
    f t A.LetBinding {} = t
    f _ _ = False

betaReduce :: A.Expr -> (Subs A.Bindings, A.Expr)
betaReduce (A.App a b l) =
  case a of
    A.Lam x body _ ->
      let s = Map.singleton x b in
      (Map.map A.BetaBinding s, getSubstAfter (subst s body))
    A.Subst _ _ (A.Lam x body _) ->
      let s = Map.singleton x b in
      (Map.map A.BetaBinding s, getSubstAfter (subst s body))
    _ -> (emptySubs, A.App a b l)
betaReduce expr = (emptySubs, expr)

-- e1 [s] -> e2
-- e1 [s] -> e2 [s//(n, e2)]
simpleSubs :: A.Expr -> Subs A.Bindings -> Name -> A.Expr -> A.Expr
simpleSubs e1 s n e2 =
  A.Subst e1 s
    (reduceSubs e2 (Map.delete n s) (subst (Map.delete n s) e2))

reduceSubs :: A.Expr -> Subs A.Bindings -> A.Expr -> A.Expr
reduceSubs before s after
  | before == after = before
  | getSubstAfter before == after = before
  | isAllLetBindings s = after
  | null s = before
  | otherwise = A.Subst before s after

getSubstAfter :: A.Expr -> A.Expr
getSubstAfter (A.Subst _ _ after) = after
getSubstAfter (A.Chain a op b l) = A.Chain (getSubstAfter a) op (getSubstAfter b) l
getSubstAfter (A.App a b l) = A.App (getSubstAfter a) (getSubstAfter b) l
getSubstAfter (A.Lam x body l) = A.Lam x (getSubstAfter body) l
getSubstAfter expr = expr

isAllApp :: A.Expr -> Bool
isAllApp (A.Subst A.App {} _ A.App {}) = True
isAllApp (A.Subst b@A.Subst {} _ A.App {}) = isAllApp b
isAllApp _ = False

instance Substitutable A.Bindings Pred where
  subst s (Constant e) = Constant (subst s e)
  subst s (Bound e l) = Bound (subst s e) l
  subst s (Assertion e l) = Assertion (subst s e) l
  subst s (LoopInvariant e b l) = LoopInvariant (subst s e) b l
  subst s (GuardIf e l) = GuardLoop (subst s e) l
  subst s (GuardLoop e l) = GuardLoop (subst s e) l
  subst s (Conjunct xs) = Conjunct (subst s xs)
  subst s (Disjunct es) = Disjunct (subst s es)
  subst s (Negate x) = Negate (subst s x)

class Fresh m => AlphaRename m a where
  alphaRename :: [Name] -> a -> m a

instance (Fresh m, AlphaRename m a) => AlphaRename m (Subs a) where
  alphaRename = mapM . alphaRename

instance (Fresh m, AlphaRename m a) => AlphaRename m (Maybe a) where
  alphaRename = mapM . alphaRename

instance Fresh m => AlphaRename m A.Expr where
  alphaRename s expr =
    case expr of
      A.Paren e l -> A.Paren <$> alphaRename s e <*> pure l
      A.Chain a op b l -> A.Chain <$> alphaRename s a <*> pure op <*> alphaRename s b <*> pure l
      A.App a b l -> A.App <$> alphaRename s a <*> alphaRename s b <*> pure l
      A.Lam x body l -> do
        x' <- capture x
        let vx' = A.Var x' (locOf x)
        A.Lam x' <$> alphaRename s (subst (Map.singleton x vx') body) <*> pure l
      A.Quant op ns rng t l -> do
        ns' <- mapM capture ns
        let mns' = Map.fromList . zip ns . map (\x -> A.Var x (locOf x)) $ ns'
        return $ A.Quant op ns' (subst mns' rng) (subst mns' t) l
      _ -> return expr
    where
      capture x = do
        if x `elem` s
        then do
          tx <- freshWithLabel (Text.pack "m" <> nameToText x)
          return $ Name tx (locOf x)
        else return x

instance Fresh m => AlphaRename m A.Bindings where
  alphaRename s (A.AssignBinding e) = A.AssignBinding <$> alphaRename s e
  alphaRename s (A.LetBinding e) = A.LetBinding <$> alphaRename s e
  alphaRename s (A.BetaBinding e) = A.BetaBinding <$> alphaRename s e
  alphaRename s (A.AlphaBinding e) = A.AlphaBinding <$> alphaRename s e

instance Fresh m => AlphaRename m Pred where
  alphaRename s (Constant e) = Constant <$> alphaRename s e
  alphaRename s (Bound e l) = Bound <$> alphaRename s e <*> pure l
  alphaRename s (Assertion e l) = Assertion <$> alphaRename s e <*> pure l
  alphaRename s (LoopInvariant e b l) = LoopInvariant <$> alphaRename s e <*> alphaRename s b <*> pure l
  alphaRename s (GuardIf e l) = GuardIf <$> alphaRename s e <*> pure l
  alphaRename s (GuardLoop e l) = GuardLoop <$> alphaRename s e <*> pure l
  alphaRename s (Conjunct xs) = Conjunct <$> mapM (alphaRename s) xs
  alphaRename s (Disjunct es) = Disjunct <$> mapM (alphaRename s) es
  alphaRename s (Negate x) = Negate <$> alphaRename s x

toStateT :: Monad m => r -> RWST r w s m a -> StateT s m a
toStateT r m = StateT (\s -> do
    (a, s', _) <- runRWST m r s
    return (a, s')
  )

toEvalStateT :: Monad m => r -> RWST r w s m a -> StateT s m (a, w)
toEvalStateT r m = StateT (\s -> do
    (a, s', w) <- runRWST m r s
    return ((a, w), s')
  )
