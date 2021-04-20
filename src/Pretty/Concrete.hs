{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}

module Pretty.Concrete where

-- import Syntax.Parser.Lexer (Tok (..))

import Data.Loc (locOf, (<-->))
import Data.Loc.Util (translateLoc)
import Data.Text.Prettyprint.Doc (Pretty (pretty))
import Pretty.Util
import Pretty.Variadic
import Syntax.Common (Fixity (..))
import Syntax.Concrete
import Prelude hiding (Ordering (..))
import Syntax.Parser.Token

--------------------------------------------------------------------------------

instance (PrettyWithLoc a, PrettyWithLoc b) => PrettyWithLoc (Either a b) where
  prettyWithLoc (Left x) = prettyWithLoc x
  prettyWithLoc (Right x) = prettyWithLoc x

-- | SepBy
instance (PrettyWithLoc (Token sep), PrettyWithLoc a) => PrettyWithLoc (SepBy sep a) where
  prettyWithLoc (Head x) = prettyWithLoc x
  prettyWithLoc (Delim x sep xs) =
    prettyWithLoc x <> prettyWithLoc sep <> prettyWithLoc xs

-- | Tokens
instance PrettyWithLoc (Token "con") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokCon) l r

instance PrettyWithLoc (Token "var") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokVar) l r

instance PrettyWithLoc (Token "let") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokLet) l r

instance PrettyWithLoc (Token "{") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokBraceStart) l r

instance PrettyWithLoc (Token "}") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokBraceEnd) l r

instance PrettyWithLoc (Token "[") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokBracketStart) l r

instance PrettyWithLoc (Token "]") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokBracketEnd) l r

instance PrettyWithLoc (Token "(") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokParenStart) l r

instance PrettyWithLoc (Token ")") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokParenEnd) l r

instance PrettyWithLoc (Token "<|") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokQuantStarts) l r

instance PrettyWithLoc (Token "⟨") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokQuantStartU) l r

instance PrettyWithLoc (Token "|>") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokQuantEnds) l r

instance PrettyWithLoc (Token "⟩") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokQuantEndU) l r

instance PrettyWithLoc (Token "[!") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokSpecStart) l r

instance PrettyWithLoc (Token "!]") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokSpecEnd) l r

instance PrettyWithLoc (Token "{-") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokBlockCommentStart) l r

instance PrettyWithLoc (Token "-}") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokBlockCommentEnd) l r

instance PrettyWithLoc (Token "{:") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokDeclStart) l r

instance PrettyWithLoc (Token ":}") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokDeclEnd) l r
  
instance PrettyWithLoc (Token ":") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokColon) l r

instance PrettyWithLoc (Token ",") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokComma) l r

instance PrettyWithLoc (Token "..") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokRange) l r

instance PrettyWithLoc (Token "array") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokArray) l r

instance PrettyWithLoc (Token "of") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokOf) l r

instance PrettyWithLoc (Token "bnd") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokBnd) l r

instance PrettyWithLoc (Token "if") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokIf) l r

instance PrettyWithLoc (Token "fi") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokFi) l r

instance PrettyWithLoc (Token "do") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokDo) l r

instance PrettyWithLoc (Token "od") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokOd) l r

instance PrettyWithLoc (Token ":=") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokAssign) l r

instance PrettyWithLoc (Token "=") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokEQ) l r

instance PrettyWithLoc (Token "|") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokGuardBar) l r

instance PrettyWithLoc (Token "->") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokArrow) l r

instance PrettyWithLoc (Token "→") where
  prettyWithLoc (Token l r) = DocWithLoc (pretty tokArrowU) l r

--------------------------------------------------------------------------------

-- | Program
instance Pretty Program where
  pretty = toDoc . prettyWithLoc

instance PrettyWithLoc Program where
  prettyWithLoc (Program decls stmts) =
    mconcat (map prettyWithLoc decls) <> mconcat (map prettyWithLoc stmts)

--------------------------------------------------------------------------------

-- | Declaration
instance Pretty Decl where
  pretty = toDoc . prettyWithLoc

instance PrettyWithLoc Decl where
  prettyWithLoc (Decl (names, colon, t)) =
    prettyWithLoc names
    <> prettyWithLoc colon
    <> prettyWithLoc t

instance Pretty DeclProp where
  pretty = toDoc . prettyWithLoc

instance PrettyWithLoc DeclProp where
  prettyWithLoc (DeclProp (l, p, r)) =
    prettyWithLoc l
    <> prettyWithLoc p
    <> prettyWithLoc r

instance Pretty Declaration where
  pretty = toDoc . prettyWithLoc

instance PrettyWithLoc Declaration where
  prettyWithLoc (ConstDecl con decl) =
    prettyWithLoc con
      <> prettyWithLoc decl
  prettyWithLoc (ConstDeclWithProp con decl declprop ) =
    prettyWithLoc con
      <> prettyWithLoc decl
      <> prettyWithLoc declprop
  prettyWithLoc (VarDecl v decl) =
    prettyWithLoc v <> prettyWithLoc decl 
  prettyWithLoc (VarDeclWithProp v decl declprop) =
    prettyWithLoc v <> prettyWithLoc decl <> prettyWithLoc declprop 
  prettyWithLoc (LetDecl a name args e expr) =
    prettyWithLoc a
      <> prettyWithLoc name
      <> mconcat (map prettyWithLoc args)
      <> prettyWithLoc e
      <> prettyWithLoc expr

instance Pretty BlockDeclaration where
  pretty = toDoc . prettyWithLoc

instance PrettyWithLoc BlockDeclaration where
  prettyWithLoc (BlockDecl l decls r) = prettyWithLoc l
      <> mconcat (map (\(decl, declProp) -> 
            prettyWithLoc decl 
            <> maybe Empty prettyWithLoc declProp
          ) decls)
      <> prettyWithLoc r

--------------------------------------------------------------------------------

-- | Name
-- instance Pretty Name where
--   pretty = toDoc . prettyWithLoc
instance PrettyWithLoc Name where
  prettyWithLoc (Name n l) = fromDoc l (pretty n)

--------------------------------------------------------------------------------

-- | Literals
-- instance Pretty Lit where
--   pretty = toDoc . prettyWithLoc
instance PrettyWithLoc Lit where
  prettyWithLoc (LitBool True l) = fromDoc l "True"
  prettyWithLoc (LitBool False l) = fromDoc l "False"
  prettyWithLoc (LitInt n l) = fromDoc l (pretty n)
  prettyWithLoc (LitChar c l) = fromDoc l (pretty [c])

--------------------------------------------------------------------------------

-- | Operators
instance PrettyWithLoc Op where
  prettyWithLoc (EQ l) = fromDoc l "="
  prettyWithLoc (NEQ l) = fromDoc l "/="
  prettyWithLoc (NEQU l) = fromDoc l "≠"
  prettyWithLoc (LTE l) = fromDoc l "<="
  prettyWithLoc (LTEU l) = fromDoc l "≤"
  prettyWithLoc (GTE l) = fromDoc l ">="
  prettyWithLoc (GTEU l) = fromDoc l "≥"
  prettyWithLoc (LT l) = fromDoc l "<"
  prettyWithLoc (GT l) = fromDoc l ">"
  prettyWithLoc (Implies l) = fromDoc l "=>"
  prettyWithLoc (ImpliesU l) = fromDoc l "→"
  prettyWithLoc (Conj l) = fromDoc l "&&"
  prettyWithLoc (ConjU l) = fromDoc l "∧"
  prettyWithLoc (Disj l) = fromDoc l "||"
  prettyWithLoc (DisjU l) = fromDoc l "∨"
  prettyWithLoc (Neg l) = fromDoc l "~"
  prettyWithLoc (NegU l) = fromDoc l "¬"
  prettyWithLoc (Add l) = fromDoc l "+"
  prettyWithLoc (Sub l) = fromDoc l "-"
  prettyWithLoc (Mul l) = fromDoc l "*"
  prettyWithLoc (Div l) = fromDoc l "/"
  prettyWithLoc (Mod l) = fromDoc l "%"
  prettyWithLoc (Sum l) = fromDoc l "Σ"
  prettyWithLoc (Forall l) = fromDoc l "∀"
  prettyWithLoc (Exists l) = fromDoc l "∃"

--------------------------------------------------------------------------------

-- | Stmt
instance Pretty Stmt where
  pretty = toDoc . prettyWithLoc

instance PrettyWithLoc Stmt where
  prettyWithLoc (Skip l) = fromDoc l "skip"
  prettyWithLoc (Abort l) = fromDoc l "abort"
  prettyWithLoc (Assign xs a es) =
    prettyWithLoc xs <> prettyWithLoc a <> prettyWithLoc es
  prettyWithLoc (Assert l p r) =
    prettyWithLoc l
      <> prettyWithLoc p
      <> prettyWithLoc r
  prettyWithLoc (LoopInvariant l p c b bnd d r) =
    prettyWithLoc l
      <> prettyWithLoc p
      <> prettyWithLoc c
      <> prettyWithLoc b
      <> prettyWithLoc bnd
      <> prettyWithLoc d
      <> prettyWithLoc r
  prettyWithLoc (Do l gdCmds r) =
    prettyWithLoc l
      <> prettyWithLoc gdCmds
      <> prettyWithLoc r
  prettyWithLoc (If l gdCmds r) =
    prettyWithLoc l
      <> prettyWithLoc gdCmds
      <> prettyWithLoc r
  prettyWithLoc (SpecQM l) = fromDoc l "?"
  prettyWithLoc (Spec l s r) =
    prettyWithLoc l
      <> fromDoc (translateLoc 2 0 (locOf l) <--> translateLoc 0 (-2) (locOf r)) (pretty s)
      <> prettyWithLoc r
  prettyWithLoc (Proof l r) = prettyWithLoc l <> prettyWithLoc r

instance Pretty GdCmd where
  pretty = toDoc . prettyWithLoc

instance PrettyWithLoc GdCmd where
  prettyWithLoc (GdCmd guard a body) =
    prettyWithLoc guard
      <> prettyWithLoc a
      <> mconcat (map prettyWithLoc body)

--------------------------------------------------------------------------------

-- | Expr
instance Pretty Expr where
  pretty = toDoc . prettyWithLoc

instance PrettyWithLoc Expr where
  prettyWithLoc expr = case handleExpr expr of
    Expect _ -> mempty
    Complete s -> s

handleExpr :: Expr -> Variadic Expr (DocWithLoc ann)
handleExpr (Paren l x r) =
  return $
    prettyWithLoc l
      <> prettyWithLoc x
      <> prettyWithLoc r
handleExpr (Var x) = return $ prettyWithLoc x
handleExpr (Const x) = return $ prettyWithLoc x
handleExpr (Lit x) = return $ prettyWithLoc x
handleExpr (Op x) = handleOp x
handleExpr (Chain x op y) =
  return $
    prettyWithLoc x
    <> prettyWithLoc op
    <> prettyWithLoc y
handleExpr (Arr arr l i r) = 
  return $
    prettyWithLoc arr
    <> prettyWithLoc l
    <> prettyWithLoc i
    <> prettyWithLoc r
handleExpr (App p q) = case handleExpr p of
  Expect f -> f q
  Complete s -> do
    t <- handleExpr q
    return $ s <> t
handleExpr (Quant open op xs m r n t close) =
  return $
    prettyWithLoc open
      <> prettyWithLoc op
      <> mconcat (map prettyWithLoc xs)
      <> prettyWithLoc m
      <> prettyWithLoc r
      <> prettyWithLoc n
      <> prettyWithLoc t
      <> prettyWithLoc close

handleOp :: Op -> Variadic Expr (DocWithLoc ann)
handleOp op = case classify op of
  Infix _ -> do
    p <- var
    q <- var
    return $
      prettyWithLoc p
        <> prettyWithLoc op
        <> prettyWithLoc q
  InfixL _ -> do
    p <- var
    q <- var
    return $
      prettyWithLoc p
        <> prettyWithLoc op
        <> prettyWithLoc q
  InfixR _ -> do
    p <- var
    q <- var
    return $
      prettyWithLoc p
        <> prettyWithLoc op
        <> prettyWithLoc q
  Prefix _ -> do
    p <- var
    return $ prettyWithLoc op <> prettyWithLoc p
  Postfix _ -> do
    p <- var
    return $ prettyWithLoc p <> prettyWithLoc op

--------------------------------------------------------------------------------

-- | Type
instance Pretty Type where
  pretty = toDoc . prettyWithLoc

instance PrettyWithLoc Type where
  prettyWithLoc (TParen l t r) = prettyWithLoc l <> prettyWithLoc t <> prettyWithLoc r
  -- DocWithLoc "(" l l <> prettyWithLoc t <> DocWithLoc ")" m m
  prettyWithLoc (TBase (TInt l)) = fromDoc l "Int"
  prettyWithLoc (TBase (TBool l)) = fromDoc l "Bool"
  prettyWithLoc (TBase (TChar l)) = fromDoc l "Char"
  prettyWithLoc (TFunc a l b) = prettyWithLoc a <> prettyWithLoc l <> prettyWithLoc b
  prettyWithLoc (TArray l a r b) =
    prettyWithLoc l <> prettyWithLoc a <> prettyWithLoc r
      <> prettyWithLoc b
  prettyWithLoc (TVar i) = prettyWithLoc i

--------------------------------------------------------------------------------

-- | Endpoint & Interval
instance PrettyWithLoc EndpointOpen where
  prettyWithLoc (IncludingOpening l e) = prettyWithLoc l <> prettyWithLoc e
  prettyWithLoc (ExcludingOpening l e) = prettyWithLoc l <> prettyWithLoc e

instance PrettyWithLoc EndpointClose where
  prettyWithLoc (IncludingClosing e l) = prettyWithLoc e <> prettyWithLoc l
  prettyWithLoc (ExcludingClosing e l) = prettyWithLoc e <> prettyWithLoc l

instance PrettyWithLoc Interval where
  prettyWithLoc (Interval a b c) = prettyWithLoc a <> prettyWithLoc b <> prettyWithLoc c
