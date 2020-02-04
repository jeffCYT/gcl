{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Syntax.Predicate where

import Data.Aeson
import Data.Loc
import GHC.Generics

import qualified Syntax.Concrete as C
import Syntax.Concrete (Expr, Fresh, Subst)

--------------------------------------------------------------------------------
-- | Predicates


data Sort = IF Loc | LOOP Loc
          deriving (Show, Generic)

data Pred = Constant  Expr
          | Guard     Expr Sort Loc
          | Assertion Expr Loc
          | LoopInvariant Expr Loc
          | Bound     Expr
          | Conjunct  [Pred]
          | Disjunct  [Pred]
          | Negate     Pred
          -- | Imply      Pred  Pred
          deriving (Show, Generic)

instance ToJSON Sort where
instance ToJSON Pred where

toExpr :: Pred -> Expr
toExpr (Constant e) = e
toExpr (Bound e) = e
toExpr (Assertion e _) = e
toExpr (LoopInvariant e _) = e
toExpr (Guard e _ _) = e
toExpr (Conjunct xs) = C.conjunct (map toExpr xs)
toExpr (Disjunct xs) = C.disjunct (map toExpr xs)
toExpr (Negate x) = C.neg (toExpr x)

subst :: Fresh m => Subst -> Pred -> m Pred
subst env (Constant e) = Constant <$> C.subst env e
subst env (Bound e) = Bound <$> C.subst env e
subst env (Assertion e l) = Assertion <$> C.subst env e <*> pure l
subst env (LoopInvariant e l) = LoopInvariant <$> C.subst env e <*> pure l
subst env (Guard e sort l) = Guard <$> C.subst env e <*> pure sort <*> pure l
subst env (Conjunct xs) = Conjunct <$> mapM (subst env) xs
subst env (Disjunct es) = Disjunct <$> mapM (subst env) es
subst env (Negate x) = Negate <$> subst env x

toGuard :: Sort -> Expr -> Pred
toGuard sort x = Guard x sort (locOf x)
