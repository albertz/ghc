%
% (c) The University of Glasgow 2006
% (c) The AQUA Project, Glasgow University, 1993-1998
%

TcRules: Typechecking transformation rules

\begin{code}
module TcRules ( tcRules ) where

import HsSyn
import TcRnMonad
import TcSimplify
import TcMType
import TcType
import TcHsType
import TcExpr
import TcEnv
import Id
import Var	( Var )
import Name
import VarSet
import SrcLoc
import Outputable
import FastString
import Data.List( partition )
\end{code}

Note [Typechecking rules]
~~~~~~~~~~~~~~~~~~~~~~~~~
We *infer* the typ of the LHS, and use that type to *check* the type of 
the RHS.  That means that higher-rank rules work reasonably well. Here's
an example (test simplCore/should_compile/rule2.hs) produced by Roman:

   foo :: (forall m. m a -> m b) -> m a -> m b
   foo f = ...

   bar :: (forall m. m a -> m a) -> m a -> m a
   bar f = ...

   {-# RULES "foo/bar" foo = bar #-}

He wanted the rule to typecheck.

\begin{code}
tcRules :: [LRuleDecl Name] -> TcM [LRuleDecl TcId]
tcRules decls = mapM (wrapLocM tcRule) decls

tcRule :: RuleDecl Name -> TcM (RuleDecl TcId)
tcRule (HsRule name act hs_bndrs lhs fv_lhs rhs fv_rhs)
  = addErrCtxt (ruleCtxt name)	$
    do { traceTc "---- Rule ------" (ppr name)

    	-- Note [Typechecking rules]
       ; vars <- tcRuleBndrs hs_bndrs
       ; let (id_bndrs, tv_bndrs) = partition isId vars
       ; (lhs', lhs_lie, rhs', rhs_lie, rule_ty)
            <- tcExtendTyVarEnv tv_bndrs $
               tcExtendIdEnv id_bndrs $
               do { ((lhs', rule_ty), lhs_lie) <- captureConstraints (tcInferRho lhs)
                  ; (rhs', rhs_lie) <- captureConstraints (tcMonoExpr rhs rule_ty)
                  ; return (lhs', lhs_lie, rhs', rhs_lie, rule_ty) }

       ; (lhs_dicts, lhs_ev_binds, rhs_ev_binds) 
             <- simplifyRule name tv_bndrs lhs_lie rhs_lie

	-- IMPORTANT!  We *quantify* over any dicts that appear in the LHS
	-- Reason: 
	--	(a) The particular dictionary isn't important, because its value
	--	   depends only on the type
	--		e.g	gcd Int $fIntegralInt
	--         Here we'd like to match against (gcd Int any_d) for any 'any_d'
	--
	--	(b) We'd like to make available the dictionaries bound 
	--	    on the LHS in the RHS, so quantifying over them is good
	--	    See the 'lhs_dicts' in tcSimplifyAndCheck for the RHS

	-- We quantify over any tyvars free in *either* the rule
	--  *or* the bound variables.  The latter is important.  Consider
	--	ss (x,(y,z)) = (x,z)
	--	RULE:  forall v. fst (ss v) = fst v
	-- The type of the rhs of the rule is just a, but v::(a,(b,c))
	--
	-- We also need to get the free tyvars of the LHS; but we do that
	-- during zonking (see TcHsSyn.zonkRule)

       ; let tpl_ids    = lhs_dicts ++ id_bndrs
             forall_tvs = tyVarsOfTypes (rule_ty : map idType tpl_ids)

	     -- Now figure out what to quantify over
	     -- c.f. TcSimplify.simplifyInfer
       ; zonked_forall_tvs <- zonkTcTyVarsAndFV forall_tvs
       ; gbl_tvs           <- tcGetGlobalTyVars	     -- Already zonked
       ; qtvs <- zonkQuantifiedTyVars $
                 varSetElems (zonked_forall_tvs `minusVarSet` gbl_tvs)

       ; return (HsRule name act
		    (map (RuleBndr . noLoc) (qtvs ++ tpl_ids))	-- yuk
		    (mkHsDictLet lhs_ev_binds lhs') fv_lhs
		    (mkHsDictLet rhs_ev_binds rhs') fv_rhs) }

tcRuleBndrs :: [RuleBndr Name] -> TcM [Var]
tcRuleBndrs [] 
  = return []
tcRuleBndrs (RuleBndr var : rule_bndrs)
  = do 	{ ty <- newFlexiTyVarTy openTypeKind
        ; vars <- tcRuleBndrs rule_bndrs
	; return (mkLocalId (unLoc var) ty : vars) }
tcRuleBndrs (RuleBndrSig var rn_ty : rule_bndrs)
--  e.g 	x :: a->a
--  The tyvar 'a' is brought into scope first, just as if you'd written
--		a::*, x :: a->a
  = do	{ let ctxt = FunSigCtxt (unLoc var)
	; (tyvars, ty) <- tcHsPatSigType ctxt rn_ty
        ; let skol_tvs = tcSuperSkolTyVars tyvars
	      id_ty = substTyWith tyvars (mkTyVarTys skol_tvs) ty
	      id = mkLocalId (unLoc var) id_ty

	      -- The type variables scope over subsequent bindings; yuk
        ; vars <- tcExtendTyVarEnv skol_tvs $ 
                  tcRuleBndrs rule_bndrs 
	; return (skol_tvs ++ id : vars) }

ruleCtxt :: FastString -> SDoc
ruleCtxt name = ptext (sLit "When checking the transformation rule") <+> 
		doubleQuotes (ftext name)
\end{code}




