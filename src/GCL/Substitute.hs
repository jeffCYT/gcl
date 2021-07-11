{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module GCL.Substitute where

import           Control.Monad.State
import           Data.Loc                       ( locOf )
import           Data.Map                       ( Map )
import qualified Data.Map                      as Map
import qualified Data.Set                      as Set
import           Data.Set                       ( Set )
import           Data.Text                      ( Text )
import           GCL.Common                     ( Free(fv)
                                                , Fresh(fresh, freshWithLabel)
                                                )
import qualified GCL.Expand                    as Expand
import           GCL.Predicate                  ( Pred(..) )
import           Pretty                         ( (<+>)
                                                , Pretty(pretty)
                                                )
import           Syntax.Abstract                ( Expr(..) )
import           Syntax.Common                  ( Name(Name)
                                                , nameToText
                                                )


------------------------------------------------------------------

data Binding
    = UserDefinedBinding Expr
    | SubstitutionBinding Expr
    | NoBinding

type Mapping = Map Text Binding

type M = State Int

instance Fresh M where
    fresh = do
        i <- get
        put (succ i)
        return i

instance Free Binding where
    fv (UserDefinedBinding  x) = fv x
    fv (SubstitutionBinding x) = fv x
    fv NoBinding               = Set.empty

instance Pretty (Map Text Binding) where
    pretty = pretty . Map.toList

instance Pretty Binding where
    pretty (UserDefinedBinding expr) = "UserDefinedBinding" <+> pretty expr
    pretty (SubstitutionBinding reason) =
        "SubstitutionBinding" <+> pretty reason
    pretty NoBinding = "NoBinding"

------------------------------------------------------------------

-- perform substitution when there's a redex
reduceExpr :: Mapping -> Expr -> M Expr
reduceExpr mapping expr = case expr of
    App f x _ -> case f of
        Expand _ _ (Lam binder body _) -> do
            let
                mapping' = Map.insert (nameToText binder)
                                      (SubstitutionBinding x)
                                      mapping
            -- perform substitution
            Expand [] expr <$> substExpr mapping' body

        Lam binder body _ -> do 
            let
                mapping' = Map.insert (nameToText binder)
                                      (SubstitutionBinding x)
                                      mapping
            -- perform substitution
            substExpr mapping' body

        _ -> return expr
    _ -> return expr

run :: [Map Text Expand.Binding] -> Pred -> Pred
run scopes x = evalState (substPred (fromScopes scopes) x) 0


runExpr :: [Map Text Expand.Binding] -> Expr -> Expr
runExpr scopes x = evalState (substExpr (fromScopes scopes) x) 0


fromScopes :: [Map Text Expand.Binding] -> Mapping
fromScopes = Map.map fromBinding . Map.unions
  where
    fromBinding Expand.NoBinding                 = NoBinding
    fromBinding (Expand.UserDefinedBinding expr) = UserDefinedBinding expr
    fromBinding (Expand.SubstitutionBinding reason) =
        SubstitutionBinding (Expand.extract reason)

------------------------------------------------------------------

substPred :: Mapping -> Pred -> M Pred
substPred mapping = \case
    Constant a    -> Constant <$> substExpr mapping a
    GuardIf   a l -> GuardIf <$> substExpr mapping a <*> pure l
    GuardLoop a l -> GuardLoop <$> substExpr mapping a <*> pure l
    Assertion a l -> Assertion <$> substExpr mapping a <*> pure l
    LoopInvariant a b l ->
        LoopInvariant <$> substExpr mapping a <*> substExpr mapping b <*> pure l
    Bound a l   -> Bound <$> substExpr mapping a <*> pure l
    Conjunct as -> Conjunct <$> mapM (substPred mapping) as
    Disjunct as -> Disjunct <$> mapM (substPred mapping) as
    Negate   a  -> Negate <$> substPred mapping a

substExpr :: Mapping -> Expr -> M Expr
substExpr mapping expr = reduceExpr mapping =<< case expr of

    Paren e l  -> Paren <$> substExpr mapping e <*> pure l

    Lit{}      -> return expr

    Var name _ -> case Map.lookup (nameToText name) mapping of
        Nothing                            -> return expr
        Just (UserDefinedBinding  binding) -> return $ Expand [] expr binding
        Just (SubstitutionBinding binding) -> return binding
        Just NoBinding                     -> return expr

    Const name _ -> case Map.lookup (nameToText name) mapping of
        Nothing                            -> return expr
        Just (UserDefinedBinding  binding) -> return $ Expand [] expr binding
        Just (SubstitutionBinding binding) -> return binding
        Just NoBinding                     -> return expr

    Op{} -> return expr

    Chain a op b l ->
        Chain
            <$> substExpr mapping a
            <*> pure op
            <*> substExpr mapping b
            <*> pure l

    App f x l -> App <$> substExpr mapping f <*> substExpr mapping x <*> pure l

    Lam binder body l -> do

        -- rename the binder to avoid capturing only when necessary! 
        let (capturableNames, shrinkedMapping) =
                getCapturableNames mapping body

        (binder', alphaRenameMapping) <- alphaRename capturableNames binder

        Lam binder'
            <$> substExpr (alphaRenameMapping <> shrinkedMapping) body
            <*> pure l

    Quant op binders range body l -> do
        -- rename binders to avoid capturing only when necessary! 
        let (capturableNames, shrinkedMapping) =
                getCapturableNames mapping expr

        (binders', alphaRenameMapping) <-
            unzip <$> mapM (alphaRename capturableNames) binders

        -- combine individual renamings to get a new mapping 
        -- and use that mapping to rename other stuff
        let alphaRenameMappings = mconcat alphaRenameMapping

        Quant op binders'
            <$> substExpr (alphaRenameMappings <> shrinkedMapping) range
            <*> substExpr (alphaRenameMappings <> shrinkedMapping) body
            <*> pure l

    Subst{}  -> return expr

    Expand{} -> return expr

    ArrIdx array index l ->
        ArrIdx
            <$> substExpr mapping array
            <*> substExpr mapping index
            <*> pure l

    ArrUpd array index value l ->
        ArrUpd
            <$> substExpr mapping array
            <*> substExpr mapping index
            <*> substExpr mapping value
            <*> pure l

-- rename a binder if it is in the set of "capturableNames"
-- returns the renamed binder and the mapping of alpha renaming (for renaming other stuff)
alphaRename :: Set Text -> Name -> M (Name, Mapping)
alphaRename capturableNames binder =
    if Set.member (nameToText binder) capturableNames
        then do
            binder' <- Name <$> freshWithLabel (nameToText binder) <*> pure
                (locOf binder)
            return
                ( binder'
                , Map.singleton
                    (nameToText binder)
                    (SubstitutionBinding (Var binder' (locOf binder)))
                )
        else return (binder, Map.empty)

-- returns a set of free names that is susceptible to capturing 
-- also returns a Mapping that is reduced further with free variables in "body" 
getCapturableNames :: Mapping -> Expr -> (Set Text, Mapping)
getCapturableNames mapping body =
    let
        -- collect all free variables in "body"
        freeVarsInBody  = Set.map nameToText (fv body)
        -- reduce the mapping further with free variables in "body" 
        shrinkedMapping = Map.restrictKeys mapping freeVarsInBody
        -- collect all free varialbes in the mapped expressions 
        mappedExprs     = Map.elems shrinkedMapping
        freeVarsInMappedExprs =
            Set.map nameToText $ Set.unions (map fv mappedExprs)
    in
        (freeVarsInMappedExprs, shrinkedMapping)
