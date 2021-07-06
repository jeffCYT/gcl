{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}

module Render.Syntax.Abstract where

import qualified Data.Map as Map
import Pretty.Variadic (Variadic (..), var)
import Render.Class
import Render.Element
import Render.Syntax.Common ()
import Syntax.Abstract
import Syntax.Abstract.Util ( assignBindingToExpr )
import Syntax.Common (Fixity (..), Op(..), ArithOp(..), classify, Name)
import Data.Map (Map)

------------------------------------------------------------------------------

-- | Literals
instance Render Lit where
  render (Num i) = render (show i)
  render (Bol b) = render (show b)
  render (Chr c) = render (show c)
  render Emp     = "emp"

--------------------------------------------------------------------------------

-- | Expr
instance Render Expr where
  renderPrec n expr = case handleExpr n expr of
    Expect _ -> mempty
    Complete s -> s

handleExpr :: Int -> Expr -> Variadic Expr Inlines
handleExpr _ (Paren x l) = return $ tempHandleLoc l $ render x
handleExpr _ (Var x l) = return $ tempHandleLoc l $ render x
handleExpr _ (Const x l) = return $ tempHandleLoc l $ render x
handleExpr _ (Lit x l) = return $ tempHandleLoc l $ render x
handleExpr n (Op x) = handleOp n x
handleExpr _ (Chain a op b _) =
  return $
    render a
      <+> render op
      <+> render b
handleExpr n (App p q _) = case handleExpr n p of
  Expect f -> f q
  Complete s -> do
    t <- handleExpr n q
    -- see if the second argument is an application, apply parenthesis when needed
    return $ case q of
      App {} -> s <+> parensIf n (-1) t
      _ -> s <+> t
handleExpr _ (Lam p q _) = return $ "λ" <+> render p <+> "→" <+> render q
handleExpr _ (Quant op xs r t _) =
  return $
    "⟨"
      <+> renderQOp op
      <+> horzE (map render xs)
      <+> ":"
      <+> render r
      <+> ":"
      <+> render t
      <+> "⟩"
  where renderQOp (Op (ArithOp (Conj _)))  = "∀"
        renderQOp (Op (ArithOp (ConjU _))) = "∀"
        renderQOp (Op (ArithOp (Disj _)))  = "∃"
        renderQOp (Op (ArithOp (DisjU _))) = "∃"
        renderQOp (Op (ArithOp (Add _)))   = "Σ"
        renderQOp (Op (ArithOp (Mul _)))   = "Π"
        renderQOp (Op op') = render op'
        renderQOp op' = render op'
handleExpr _ (Subst before env after) =
  return $ substE (render before) (render env) (if isLam after then parensE (render after) else render after)
  where
    isLam :: Expr -> Bool
    isLam Lam {} = True
    isLam _ = False
handleExpr _ (Expand before after) =
  return $ clickE (render before) (if isLam after then parensE (render after) else render after)
  where
    isLam :: Expr -> Bool
    isLam Lam {} = True
    isLam _ = False
handleExpr _ (ArrIdx e1 e2 _) =
  return $ render e1 <> "[" <> render e2 <> "]"
handleExpr _ (ArrUpd e1 e2 e3 _) =
  return $ "(" <+> render e1 <+> ":" <+> render e2 <+> "↣" <+> render e3 <+> ")"
    -- SCM: need to print parenthesis around e1 when necessary.

instance Render Subst where
  render = render . Map.mapMaybe assignBindingToExpr

instance Render (Map Name Expr) where
  render env
    | null env = mempty
    | otherwise = "[" <+> exprs <+> "/" <+> vars <+> "]"
      where
        vars = punctuateE "," $ map render $ Map.keys env
        exprs = punctuateE "," $ map render $ Map.elems env

--------------------------------------------------------------------------------

handleOp :: Int -> Op -> Variadic Expr Inlines
handleOp n op = case classify op of
  Infix m -> do
    p <- var
    q <- var
    return $
      parensIf n m $
        renderPrec (succ m) p
          <+> render op
          <+> renderPrec (succ m) q
  InfixL m -> do
    p <- var
    q <- var
    return $
      parensIf n m $
        renderPrec m p
          <+> render op
          <+> renderPrec (succ m) q
  InfixR m -> do
    p <- var
    q <- var
    return $
      parensIf n m $
        renderPrec (succ m) p
          <+> render op
          <+> renderPrec m q
  Prefix m -> do
    p <- var
    return $ parensIf n m $ render op <+> renderPrec m p
  Postfix m -> do
    p <- var
    return $ parensIf n m $ renderPrec m p <+> render op

--------------------------------------------------------------------------------

-- | Type
instance Render Type where
  render (TBase TInt _) = "Int"
  render (TBase TBool _) = "Bool"
  render (TBase TChar _) = "Char"
  render (TFunc a b _) = render a <+> "→" <+> render b
  render (TArray i b _) = "array" <+> render i <+> "of" <+> render b
  render (TVar i _) = "TVar" <+> render i

-- | Interval
instance Render Interval where
  render (Interval (Including a) (Including b) _) =
    "[" <+> render a <+> ".." <+> render b <+> "]"
  render (Interval (Including a) (Excluding b) _) =
    "[" <+> render a <+> ".." <+> render b <+> ")"
  render (Interval (Excluding a) (Including b) _) =
    "(" <+> render a <+> ".." <+> render b <+> "]"
  render (Interval (Excluding a) (Excluding b) _) =
    "(" <+> render a <+> ".." <+> render b <+> ")"

--------------------------------------------------------------------------------

parensIf :: Int -> Int -> Inlines -> Inlines
parensIf n m
  | n > m = parensE
  | otherwise = id
