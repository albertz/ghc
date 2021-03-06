%
% (c) The AQUA Project, Glasgow University, 1993-1998
%
\section[SimplUtils]{The simplifier utilities}

\begin{code}
module SimplUtils (
	-- Rebuilding
	mkLam, mkCase, prepareAlts, tryEtaExpand,

	-- Inlining,
	preInlineUnconditionally, postInlineUnconditionally, 
	activeUnfolding, activeRule, 
	getUnfoldingInRuleMatch, 
        simplEnvForGHCi, updModeForInlineRules,

	-- The continuation type
	SimplCont(..), DupFlag(..), ArgInfo(..),
        isSimplified,
	contIsDupable, contResultType, contIsTrivial, contArgs, dropArgs, 
	pushSimplifiedArgs, countValArgs, countArgs, addArgTo,
	mkBoringStop, mkRhsStop, mkLazyArgStop, contIsRhsOrArg,
	interestingCallContext, 

	interestingArg, mkArgInfo,
	
	abstractFloats
    ) where

#include "HsVersions.h"

import SimplEnv
import CoreMonad        ( SimplifierMode(..), Tick(..) )
import DynFlags
import StaticFlags
import CoreSyn
import qualified CoreSubst
import PprCore
import CoreFVs
import CoreUtils
import CoreArity
import CoreUnfold
import Name
import Id
import Var
import Demand
import SimplMonad
import TcType	( isDictLikeTy )
import Type	hiding( substTy )
import Coercion ( coercionKind )
import TyCon
import Unify	( dataConCannotMatch )
import VarSet
import BasicTypes
import Util
import MonadUtils
import Outputable
import FastString

import Data.List
\end{code}


%************************************************************************
%*									*
		The SimplCont type
%*									*
%************************************************************************

A SimplCont allows the simplifier to traverse the expression in a 
zipper-like fashion.  The SimplCont represents the rest of the expression,
"above" the point of interest.

You can also think of a SimplCont as an "evaluation context", using
that term in the way it is used for operational semantics. This is the
way I usually think of it, For example you'll often see a syntax for
evaluation context looking like
	C ::= []  |  C e   |  case C of alts  |  C `cast` co
That's the kind of thing we are doing here, and I use that syntax in
the comments.


Key points:
  * A SimplCont describes a *strict* context (just like 
    evaluation contexts do).  E.g. Just [] is not a SimplCont

  * A SimplCont describes a context that *does not* bind
    any variables.  E.g. \x. [] is not a SimplCont

\begin{code}
data SimplCont	
  = Stop		-- An empty context, or hole, []     
	CallCtxt	-- True <=> There is something interesting about
			--          the context, and hence the inliner
			--	    should be a bit keener (see interestingCallContext)
			-- Specifically:
			--     This is an argument of a function that has RULES
			--     Inlining the call might allow the rule to fire

  | CoerceIt 		-- C `cast` co
	OutCoercion		-- The coercion simplified
	SimplCont

  | ApplyTo  		-- C arg
	DupFlag			-- See Note [DupFlag invariants]
	InExpr StaticEnv	-- The argument and its static env
	SimplCont

  | Select   		-- case C of alts
	DupFlag 	        -- See Note [DupFlag invariants]
	InId [InAlt] StaticEnv	-- The case binder, alts, and subst-env
	SimplCont

  -- The two strict forms have no DupFlag, because we never duplicate them
  | StrictBind 		-- (\x* \xs. e) C
	InId [InBndr]		-- let x* = [] in e 	
	InExpr StaticEnv	--	is a special case 
	SimplCont	

  | StrictArg 		-- f e1 ..en C
 	ArgInfo		-- Specifies f, e1..en, Whether f has rules, etc
			--     plus strictness flags for *further* args
        CallCtxt        -- Whether *this* argument position is interesting
	SimplCont		

data ArgInfo 
  = ArgInfo {
        ai_fun   :: Id,		-- The function
	ai_args  :: [OutExpr],	-- ...applied to these args (which are in *reverse* order)
	ai_rules :: [CoreRule],	-- Rules for this function

	ai_encl :: Bool,	-- Flag saying whether this function 
				-- or an enclosing one has rules (recursively)
				--	True => be keener to inline in all args
	
	ai_strs :: [Bool],	-- Strictness of remaining arguments
				--   Usually infinite, but if it is finite it guarantees
				--   that the function diverges after being given
				--   that number of args
	ai_discs :: [Int]	-- Discounts for remaining arguments; non-zero => be keener to inline
				--   Always infinite
    }

addArgTo :: ArgInfo -> OutExpr -> ArgInfo
addArgTo ai arg = ai { ai_args = arg : ai_args ai }

instance Outputable SimplCont where
  ppr (Stop interesting)    	     = ptext (sLit "Stop") <> brackets (ppr interesting)
  ppr (ApplyTo dup arg _ cont)       = ((ptext (sLit "ApplyTo") <+> ppr dup <+> pprParendExpr arg)
					  {-  $$ nest 2 (pprSimplEnv se) -}) $$ ppr cont
  ppr (StrictBind b _ _ _ cont)      = (ptext (sLit "StrictBind") <+> ppr b) $$ ppr cont
  ppr (StrictArg ai _ cont)          = (ptext (sLit "StrictArg") <+> ppr (ai_fun ai)) $$ ppr cont
  ppr (Select dup bndr alts se cont) = (ptext (sLit "Select") <+> ppr dup <+> ppr bndr) $$ 
				       (nest 2 $ vcat [ppr (seTvSubst se), ppr alts]) $$ ppr cont 
  ppr (CoerceIt co cont)	     = (ptext (sLit "CoerceIt") <+> ppr co) $$ ppr cont

data DupFlag = NoDup       -- Unsimplified, might be big
             | Simplified  -- Simplified
             | OkToDup     -- Simplified and small

isSimplified :: DupFlag -> Bool
isSimplified NoDup = False
isSimplified _     = True	-- Invariant: the subst-env is empty

instance Outputable DupFlag where
  ppr OkToDup    = ptext (sLit "ok")
  ppr NoDup      = ptext (sLit "nodup")
  ppr Simplified = ptext (sLit "simpl")
\end{code}

Note [DupFlag invariants]
~~~~~~~~~~~~~~~~~~~~~~~~~
In both (ApplyTo dup _ env k)
   and  (Select dup _ _ env k)
the following invariants hold

  (a) if dup = OkToDup, then continuation k is also ok-to-dup
  (b) if dup = OkToDup or Simplified, the subst-env is empty
      (and and hence no need to re-simplify)

\begin{code}
-------------------
mkBoringStop :: SimplCont
mkBoringStop = Stop BoringCtxt

mkRhsStop :: SimplCont	-- See Note [RHS of lets] in CoreUnfold
mkRhsStop = Stop (ArgCtxt False)

mkLazyArgStop :: CallCtxt -> SimplCont
mkLazyArgStop cci = Stop cci

-------------------
contIsRhsOrArg :: SimplCont -> Bool
contIsRhsOrArg (Stop {})       = True
contIsRhsOrArg (StrictBind {}) = True
contIsRhsOrArg (StrictArg {})  = True
contIsRhsOrArg _               = False

-------------------
contIsDupable :: SimplCont -> Bool
contIsDupable (Stop {})                  = True
contIsDupable (ApplyTo  OkToDup _ _ _)   = True	-- See Note [DupFlag invariants]
contIsDupable (Select   OkToDup _ _ _ _) = True -- ...ditto...
contIsDupable (CoerceIt _ cont)          = contIsDupable cont
contIsDupable _                          = False

-------------------
contIsTrivial :: SimplCont -> Bool
contIsTrivial (Stop {})                   = True
contIsTrivial (ApplyTo _ (Type _) _ cont) = contIsTrivial cont
contIsTrivial (CoerceIt _ cont)           = contIsTrivial cont
contIsTrivial _                           = False

-------------------
contResultType :: SimplEnv -> OutType -> SimplCont -> OutType
contResultType env ty cont
  = go cont ty
  where
    subst_ty se ty = substTy (se `setInScope` env) ty

    go (Stop {})                      ty = ty
    go (CoerceIt co cont)             _  = go cont (snd (coercionKind co))
    go (StrictBind _ bs body se cont) _  = go cont (subst_ty se (exprType (mkLams bs body)))
    go (StrictArg ai _ cont)          _  = go cont (funResultTy (argInfoResultTy ai))
    go (Select _ _ alts se cont)      _  = go cont (subst_ty se (coreAltsType alts))
    go (ApplyTo _ arg se cont)        ty = go cont (apply_to_arg ty arg se)

    apply_to_arg ty (Type ty_arg) se = applyTy ty (subst_ty se ty_arg)
    apply_to_arg ty _             _  = funResultTy ty

argInfoResultTy :: ArgInfo -> OutType
argInfoResultTy (ArgInfo { ai_fun = fun, ai_args = args })
  = foldr (\arg fn_ty -> applyTypeToArg fn_ty arg) (idType fun) args

-------------------
countValArgs :: SimplCont -> Int
countValArgs (ApplyTo _ (Type _) _ cont) = countValArgs cont
countValArgs (ApplyTo _ _        _ cont) = 1 + countValArgs cont
countValArgs _                           = 0

countArgs :: SimplCont -> Int
countArgs (ApplyTo _ _ _ cont) = 1 + countArgs cont
countArgs _                    = 0

contArgs :: SimplCont -> (Bool, [ArgSummary], SimplCont)
-- Uses substitution to turn each arg into an OutExpr
contArgs cont@(ApplyTo {})
  = case go [] cont of { (args, cont') -> (False, args, cont') }
  where
    go args (ApplyTo _ arg se cont)
      | isTypeArg arg = go args                           cont
      | otherwise     = go (is_interesting arg se : args) cont
    go args cont      = (reverse args, cont)

    is_interesting arg se = interestingArg (substExpr (text "contArgs") se arg)
    		   -- Do *not* use short-cutting substitution here
		   -- because we want to get as much IdInfo as possible

contArgs cont = (True, [], cont)

pushSimplifiedArgs :: SimplEnv -> [CoreExpr] -> SimplCont -> SimplCont
pushSimplifiedArgs _env []         cont = cont
pushSimplifiedArgs env  (arg:args) cont = ApplyTo Simplified arg env (pushSimplifiedArgs env args cont)
		   -- The env has an empty SubstEnv

dropArgs :: Int -> SimplCont -> SimplCont
dropArgs 0 cont = cont
dropArgs n (ApplyTo _ _ _ cont) = dropArgs (n-1) cont
dropArgs n other		= pprPanic "dropArgs" (ppr n <+> ppr other)
\end{code}


Note [Interesting call context]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We want to avoid inlining an expression where there can't possibly be
any gain, such as in an argument position.  Hence, if the continuation
is interesting (eg. a case scrutinee, application etc.) then we
inline, otherwise we don't.  

Previously some_benefit used to return True only if the variable was
applied to some value arguments.  This didn't work:

	let x = _coerce_ (T Int) Int (I# 3) in
	case _coerce_ Int (T Int) x of
		I# y -> ....

we want to inline x, but can't see that it's a constructor in a case
scrutinee position, and some_benefit is False.

Another example:

dMonadST = _/\_ t -> :Monad (g1 _@_ t, g2 _@_ t, g3 _@_ t)

....  case dMonadST _@_ x0 of (a,b,c) -> ....

we'd really like to inline dMonadST here, but we *don't* want to
inline if the case expression is just

	case x of y { DEFAULT -> ... }

since we can just eliminate this case instead (x is in WHNF).  Similar
applies when x is bound to a lambda expression.  Hence
contIsInteresting looks for case expressions with just a single
default case.


\begin{code}
interestingCallContext :: SimplCont -> CallCtxt
-- See Note [Interesting call context]
interestingCallContext cont
  = interesting cont
  where
    interesting (Select _ bndr _ _ _)
	| isDeadBinder bndr = CaseCtxt
	| otherwise	    = ArgCtxt False	-- If the binder is used, this
						-- is like a strict let
						-- See Note [RHS of lets] in CoreUnfold
		
    interesting (ApplyTo _ arg _ cont)
	| isTypeArg arg = interesting cont
	| otherwise     = ValAppCtxt 	-- Can happen if we have (f Int |> co) y
					-- If f has an INLINE prag we need to give it some
					-- motivation to inline. See Note [Cast then apply]
					-- in CoreUnfold

    interesting (StrictArg _ cci _) = cci
    interesting (StrictBind {})	    = BoringCtxt
    interesting (Stop cci)   	    = cci
    interesting (CoerceIt _ cont)   = interesting cont
	-- If this call is the arg of a strict function, the context
	-- is a bit interesting.  If we inline here, we may get useful
	-- evaluation information to avoid repeated evals: e.g.
	--	x + (y * z)
	-- Here the contIsInteresting makes the '*' keener to inline,
	-- which in turn exposes a constructor which makes the '+' inline.
	-- Assuming that +,* aren't small enough to inline regardless.
	--
	-- It's also very important to inline in a strict context for things
	-- like
	--		foldr k z (f x)
	-- Here, the context of (f x) is strict, and if f's unfolding is
	-- a build it's *great* to inline it here.  So we must ensure that
	-- the context for (f x) is not totally uninteresting.


-------------------
mkArgInfo :: Id
	  -> [CoreRule]	-- Rules for function
	  -> Int	-- Number of value args
	  -> SimplCont	-- Context of the call
	  -> ArgInfo

mkArgInfo fun rules n_val_args call_cont
  | n_val_args < idArity fun		-- Note [Unsaturated functions]
  = ArgInfo { ai_fun = fun, ai_args = [], ai_rules = rules
            , ai_encl = False
	    , ai_strs = vanilla_stricts 
	    , ai_discs = vanilla_discounts }
  | otherwise
  = ArgInfo { ai_fun = fun, ai_args = [], ai_rules = rules
            , ai_encl = interestingArgContext rules call_cont
	    , ai_strs  = add_type_str (idType fun) arg_stricts
	    , ai_discs = arg_discounts }
  where
    vanilla_discounts, arg_discounts :: [Int]
    vanilla_discounts = repeat 0
    arg_discounts = case idUnfolding fun of
			CoreUnfolding {uf_guidance = UnfIfGoodArgs {ug_args = discounts}}
			      -> discounts ++ vanilla_discounts
			_     -> vanilla_discounts

    vanilla_stricts, arg_stricts :: [Bool]
    vanilla_stricts  = repeat False

    arg_stricts
      = case splitStrictSig (idStrictness fun) of
	  (demands, result_info)
		| not (demands `lengthExceeds` n_val_args)
		-> 	-- Enough args, use the strictness given.
			-- For bottoming functions we used to pretend that the arg
			-- is lazy, so that we don't treat the arg as an
			-- interesting context.  This avoids substituting
			-- top-level bindings for (say) strings into 
			-- calls to error.  But now we are more careful about
			-- inlining lone variables, so its ok (see SimplUtils.analyseCont)
		   if isBotRes result_info then
			map isStrictDmd demands		-- Finite => result is bottom
		   else
			map isStrictDmd demands ++ vanilla_stricts
	       | otherwise
	       -> WARN( True, text "More demands than arity" <+> ppr fun <+> ppr (idArity fun) 
				<+> ppr n_val_args <+> ppr demands ) 
		   vanilla_stricts	-- Not enough args, or no strictness

    add_type_str :: Type -> [Bool] -> [Bool]
    -- If the function arg types are strict, record that in the 'strictness bits'
    -- No need to instantiate because unboxed types (which dominate the strict
    -- types) can't instantiate type variables.
    -- add_type_str is done repeatedly (for each call); might be better 
    -- once-for-all in the function
    -- But beware primops/datacons with no strictness
    add_type_str _ [] = []
    add_type_str fun_ty strs		-- Look through foralls
	| Just (_, fun_ty') <- splitForAllTy_maybe fun_ty	-- Includes coercions
	= add_type_str fun_ty' strs
    add_type_str fun_ty (str:strs)	-- Add strict-type info
	| Just (arg_ty, fun_ty') <- splitFunTy_maybe fun_ty
	= (str || isStrictType arg_ty) : add_type_str fun_ty' strs
    add_type_str _ strs
	= strs

{- Note [Unsaturated functions]
  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider (test eyeball/inline4)
	x = a:as
	y = f x
where f has arity 2.  Then we do not want to inline 'x', because
it'll just be floated out again.  Even if f has lots of discounts
on its first argument -- it must be saturated for these to kick in
-}

interestingArgContext :: [CoreRule] -> SimplCont -> Bool
-- If the argument has form (f x y), where x,y are boring,
-- and f is marked INLINE, then we don't want to inline f.
-- But if the context of the argument is
--	g (f x y) 
-- where g has rules, then we *do* want to inline f, in case it
-- exposes a rule that might fire.  Similarly, if the context is
--	h (g (f x x))
-- where h has rules, then we do want to inline f; hence the
-- call_cont argument to interestingArgContext
--
-- The ai-rules flag makes this happen; if it's
-- set, the inliner gets just enough keener to inline f 
-- regardless of how boring f's arguments are, if it's marked INLINE
--
-- The alternative would be to *always* inline an INLINE function,
-- regardless of how boring its context is; but that seems overkill
-- For example, it'd mean that wrapper functions were always inlined
interestingArgContext rules call_cont
  = notNull rules || enclosing_fn_has_rules
  where
    enclosing_fn_has_rules = go call_cont

    go (Select {})	   = False
    go (ApplyTo {})	   = False
    go (StrictArg _ cci _) = interesting cci
    go (StrictBind {})	   = False	-- ??
    go (CoerceIt _ c)	   = go c
    go (Stop cci)          = interesting cci

    interesting (ArgCtxt rules) = rules
    interesting _               = False
\end{code}


%************************************************************************
%*									*
                  SimplifierMode
%*									*
%************************************************************************

The SimplifierMode controls several switches; see its definition in
CoreMonad
        sm_rules      :: Bool     -- Whether RULES are enabled
        sm_inline     :: Bool     -- Whether inlining is enabled
        sm_case_case  :: Bool     -- Whether case-of-case is enabled
        sm_eta_expand :: Bool     -- Whether eta-expansion is enabled

\begin{code}
simplEnvForGHCi :: DynFlags -> SimplEnv
simplEnvForGHCi dflags
  = mkSimplEnv $ SimplMode { sm_names = ["GHCi"]
                           , sm_phase = InitialPhase
                           , sm_rules = rules_on
                           , sm_inline = False
                           , sm_eta_expand = eta_expand_on
                           , sm_case_case = True }
  where
    rules_on      = dopt Opt_EnableRewriteRules   dflags
    eta_expand_on = dopt Opt_DoLambdaEtaExpansion dflags
   -- Do not do any inlining, in case we expose some unboxed
   -- tuple stuff that confuses the bytecode interpreter

updModeForInlineRules :: Activation -> SimplifierMode -> SimplifierMode
-- See Note [Simplifying inside InlineRules]
updModeForInlineRules inline_rule_act current_mode
  = current_mode { sm_phase = phaseFromActivation inline_rule_act
                 , sm_inline = True
                 , sm_eta_expand = False }
		 -- For sm_rules, just inherit; sm_rules might be "off"
		 -- becuase of -fno-enable-rewrite-rules
  where
    phaseFromActivation (ActiveAfter n) = Phase n
    phaseFromActivation _               = InitialPhase
\end{code}

Note [Inlining in gentle mode]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Something is inlined if 
   (i)   the sm_inline flag is on, AND
   (ii)  the thing has an INLINE pragma, AND
   (iii) the thing is inlinable in the earliest phase.  

Example of why (iii) is important:
  {-# INLINE [~1] g #-}
  g = ...
  
  {-# INLINE f #-}
  f x = g (g x)

If we were to inline g into f's inlining, then an importing module would
never be able to do
	f e --> g (g e) ---> RULE fires
because the InlineRule for f has had g inlined into it.

On the other hand, it is bad not to do ANY inlining into an
InlineRule, because then recursive knots in instance declarations
don't get unravelled.

However, *sometimes* SimplGently must do no call-site inlining at all
(hence sm_inline = False).  Before full laziness we must be careful
not to inline wrappers, because doing so inhibits floating
    e.g. ...(case f x of ...)...
    ==> ...(case (case x of I# x# -> fw x#) of ...)...
    ==> ...(case x of I# x# -> case fw x# of ...)...
and now the redex (f x) isn't floatable any more.

The no-inlining thing is also important for Template Haskell.  You might be 
compiling in one-shot mode with -O2; but when TH compiles a splice before
running it, we don't want to use -O2.  Indeed, we don't want to inline
anything, because the byte-code interpreter might get confused about 
unboxed tuples and suchlike.

Note [Simplifying inside InlineRules]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We must take care with simplification inside InlineRules (which come from
INLINE pragmas).  

First, consider the following example
     	let f = \pq -> BIG
     	in
     	let g = \y -> f y y
	    {-# INLINE g #-}
     	in ...g...g...g...g...g...
Now, if that's the ONLY occurrence of f, it might be inlined inside g,
and thence copied multiple times when g is inlined. HENCE we treat
any occurrence in an InlineRule as a multiple occurrence, not a single
one; see OccurAnal.addRuleUsage.

Second, we do want *do* to some modest rules/inlining stuff in InlineRules,
partly to eliminate senseless crap, and partly to break the recursive knots
generated by instance declarations.

However, suppose we have
	{-# INLINE <act> f #-}
	f = <rhs>
meaning "inline f in phases p where activation <act>(p) holds". 
Then what inlinings/rules can we apply to the copy of <rhs> captured in
f's InlineRule?  Our model is that literally <rhs> is substituted for
f when it is inlined.  So our conservative plan (implemented by 
updModeForInlineRules) is this:

  -------------------------------------------------------------
  When simplifying the RHS of an InlineRule, set the phase to the
  phase in which the InlineRule first becomes active
  -------------------------------------------------------------

That ensures that

  a) Rules/inlinings that *cease* being active before p will 
     not apply to the InlineRule rhs, consistent with it being
     inlined in its *original* form in phase p.

  b) Rules/inlinings that only become active *after* p will
     not apply to the InlineRule rhs, again to be consistent with
     inlining the *original* rhs in phase p.

For example, 
       	{-# INLINE f #-}
      	f x = ...g...

      	{-# NOINLINE [1] g #-}
      	g y = ...

      	{-# RULE h g = ... #-}
Here we must not inline g into f's RHS, even when we get to phase 0,
because when f is later inlined into some other module we want the
rule for h to fire.

Similarly, consider
 	{-# INLINE f #-}
	f x = ...g...

	g y = ...
and suppose that there are auto-generated specialisations and a strictness
wrapper for g.  The specialisations get activation AlwaysActive, and the
strictness wrapper get activation (ActiveAfter 0).  So the strictness
wrepper fails the test and won't be inlined into f's InlineRule. That
means f can inline, expose the specialised call to g, so the specialisation
rules can fire.

A note about wrappers
~~~~~~~~~~~~~~~~~~~~~
It's also important not to inline a worker back into a wrapper.
A wrapper looks like
	wraper = inline_me (\x -> ...worker... )
Normally, the inline_me prevents the worker getting inlined into
the wrapper (initially, the worker's only call site!).  But,
if the wrapper is sure to be called, the strictness analyser will
mark it 'demanded', so when the RHS is simplified, it'll get an ArgOf
continuation. 

\begin{code}
activeUnfolding :: SimplEnv -> Id -> Bool
activeUnfolding env
  | not (sm_inline mode) = active_unfolding_minimal
  | otherwise            = case sm_phase mode of
                             InitialPhase -> active_unfolding_gentle
                             Phase n      -> active_unfolding n
  where
    mode = getMode env

getUnfoldingInRuleMatch :: SimplEnv -> IdUnfoldingFun
-- When matching in RULE, we want to "look through" an unfolding
-- (to see a constructor) if *rules* are on, even if *inlinings* 
-- are not.  A notable example is DFuns, which really we want to 
-- match in rules like (op dfun) in gentle mode. Another example
-- is 'otherwise' which we want exprIsConApp_maybe to be able to
-- see very early on
getUnfoldingInRuleMatch env id
  | unf_is_active = idUnfolding id
  | otherwise     = NoUnfolding
  where
    mode = getMode env
    unf_is_active
     | not (sm_rules mode) = active_unfolding_minimal id
     | otherwise           = isActive (sm_phase mode) (idInlineActivation id)

active_unfolding_minimal :: Id -> Bool
-- Compuslory unfoldings only
-- Ignore SimplGently, because we want to inline regardless;
-- the Id has no top-level binding at all
--
-- NB: we used to have a second exception, for data con wrappers.
-- On the grounds that we use gentle mode for rule LHSs, and 
-- they match better when data con wrappers are inlined.
-- But that only really applies to the trivial wrappers (like (:)),
-- and they are now constructed as Compulsory unfoldings (in MkId)
-- so they'll happen anyway.
active_unfolding_minimal id = isCompulsoryUnfolding (realIdUnfolding id)

active_unfolding :: PhaseNum -> Id -> Bool
active_unfolding n id = isActiveIn n (idInlineActivation id)

active_unfolding_gentle :: Id -> Bool
-- Anything that is early-active
-- See Note [Gentle mode]
active_unfolding_gentle id
  =  isInlinePragma prag
  && isEarlyActive (inlinePragmaActivation prag)
       -- NB: wrappers are not early-active
  where
    prag = idInlinePragma id

----------------------
activeRule :: DynFlags -> SimplEnv -> Maybe (Activation -> Bool)
-- Nothing => No rules at all
activeRule _dflags env
  | not (sm_rules mode) = Nothing     -- Rewriting is off
  | otherwise           = Just (isActive (sm_phase mode))
  where
    mode = getMode env
\end{code}



%************************************************************************
%*									*
                  preInlineUnconditionally
%*									*
%************************************************************************

preInlineUnconditionally
~~~~~~~~~~~~~~~~~~~~~~~~
@preInlineUnconditionally@ examines a bndr to see if it is used just
once in a completely safe way, so that it is safe to discard the
binding inline its RHS at the (unique) usage site, REGARDLESS of how
big the RHS might be.  If this is the case we don't simplify the RHS
first, but just inline it un-simplified.

This is much better than first simplifying a perhaps-huge RHS and then
inlining and re-simplifying it.  Indeed, it can be at least quadratically
better.  Consider

	x1 = e1
	x2 = e2[x1]
	x3 = e3[x2]
	...etc...
	xN = eN[xN-1]

We may end up simplifying e1 N times, e2 N-1 times, e3 N-3 times etc.
This can happen with cascades of functions too:

	f1 = \x1.e1
	f2 = \xs.e2[f1]
	f3 = \xs.e3[f3]
	...etc...

THE MAIN INVARIANT is this:

	----  preInlineUnconditionally invariant -----
   IF preInlineUnconditionally chooses to inline x = <rhs>
   THEN doing the inlining should not change the occurrence
	info for the free vars of <rhs>
	----------------------------------------------

For example, it's tempting to look at trivial binding like
	x = y
and inline it unconditionally.  But suppose x is used many times,
but this is the unique occurrence of y.  Then inlining x would change
y's occurrence info, which breaks the invariant.  It matters: y
might have a BIG rhs, which will now be dup'd at every occurrenc of x.


Even RHSs labelled InlineMe aren't caught here, because there might be
no benefit from inlining at the call site.

[Sept 01] Don't unconditionally inline a top-level thing, because that
can simply make a static thing into something built dynamically.  E.g.
	x = (a,b)
	main = \s -> h x

[Remember that we treat \s as a one-shot lambda.]  No point in
inlining x unless there is something interesting about the call site.

But watch out: if you aren't careful, some useful foldr/build fusion
can be lost (most notably in spectral/hartel/parstof) because the
foldr didn't see the build.  Doing the dynamic allocation isn't a big
deal, in fact, but losing the fusion can be.  But the right thing here
seems to be to do a callSiteInline based on the fact that there is
something interesting about the call site (it's strict).  Hmm.  That
seems a bit fragile.

Conclusion: inline top level things gaily until Phase 0 (the last
phase), at which point don't.

Note [pre/postInlineUnconditionally in gentle mode]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Even in gentle mode we want to do preInlineUnconditionally.  The
reason is that too little clean-up happens if you don't inline
use-once things.  Also a bit of inlining is *good* for full laziness;
it can expose constant sub-expressions.  Example in
spectral/mandel/Mandel.hs, where the mandelset function gets a useful
let-float if you inline windowToViewport

However, as usual for Gentle mode, do not inline things that are
inactive in the intial stages.  See Note [Gentle mode].

Note [InlineRule and preInlineUnconditionally]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Surprisingly, do not pre-inline-unconditionally Ids with INLINE pragmas!
Example

   {-# INLINE f #-}
   f :: Eq a => a -> a
   f x = ...
   
   fInt :: Int -> Int
   fInt = f Int dEqInt

   ...fInt...fInt...fInt...

Here f occurs just once, in the RHS of f1. But if we inline it there
we'll lose the opportunity to inline at each of fInt's call sites.
The INLINE pragma will only inline when the application is saturated
for exactly this reason; and we don't want PreInlineUnconditionally
to second-guess it.  A live example is Trac #3736.
    c.f. Note [InlineRule and postInlineUnconditionally]

Note [Top-level botomming Ids]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Don't inline top-level Ids that are bottoming, even if they are used just
once, because FloatOut has gone to some trouble to extract them out.
Inlining them won't make the program run faster!

\begin{code}
preInlineUnconditionally :: SimplEnv -> TopLevelFlag -> InId -> InExpr -> Bool
preInlineUnconditionally env top_lvl bndr rhs
  | not active 		                     = False
  | isStableUnfolding (idUnfolding bndr)     = False    -- Note [InlineRule and preInlineUnconditionally]
  | isTopLevel top_lvl && isBottomingId bndr = False	-- Note [Top-level bottoming Ids]
  | opt_SimplNoPreInlining                   = False
  | otherwise = case idOccInfo bndr of
		  IAmDead	     	     -> True	-- Happens in ((\x.1) v)
	  	  OneOcc in_lam True int_cxt -> try_once in_lam int_cxt
		  _                          -> False
  where
    mode = getMode env
    active = isActive (sm_phase mode) act
             -- See Note [pre/postInlineUnconditionally in gentle mode]
    act = idInlineActivation bndr
    try_once in_lam int_cxt	-- There's one textual occurrence
	| not in_lam = isNotTopLevel top_lvl || early_phase
	| otherwise  = int_cxt && canInlineInLam rhs

-- Be very careful before inlining inside a lambda, because (a) we must not 
-- invalidate occurrence information, and (b) we want to avoid pushing a
-- single allocation (here) into multiple allocations (inside lambda).  
-- Inlining a *function* with a single *saturated* call would be ok, mind you.
--	|| (if is_cheap && not (canInlineInLam rhs) then pprTrace "preinline" (ppr bndr <+> ppr rhs) ok else ok)
--	where 
--	 	is_cheap = exprIsCheap rhs
--		ok = is_cheap && int_cxt

	-- 	int_cxt		The context isn't totally boring
	-- E.g. let f = \ab.BIG in \y. map f xs
	-- 	Don't want to substitute for f, because then we allocate
	--	its closure every time the \y is called
	-- But: let f = \ab.BIG in \y. map (f y) xs
	--	Now we do want to substitute for f, even though it's not 
	--	saturated, because we're going to allocate a closure for 
	--	(f y) every time round the loop anyhow.

	-- canInlineInLam => free vars of rhs are (Once in_lam) or Many,
	-- so substituting rhs inside a lambda doesn't change the occ info.
	-- Sadly, not quite the same as exprIsHNF.
    canInlineInLam (Lit _)		= True
    canInlineInLam (Lam b e)		= isRuntimeVar b || canInlineInLam e
    canInlineInLam (Note _ e)		= canInlineInLam e
    canInlineInLam _			= False

    early_phase = case sm_phase mode of
                    Phase 0 -> False
                    _       -> True
-- If we don't have this early_phase test, consider
--	x = length [1,2,3]
-- The full laziness pass carefully floats all the cons cells to
-- top level, and preInlineUnconditionally floats them all back in.
-- Result is (a) static allocation replaced by dynamic allocation
--	     (b) many simplifier iterations because this tickles
--		 a related problem; only one inlining per pass
-- 
-- On the other hand, I have seen cases where top-level fusion is
-- lost if we don't inline top level thing (e.g. string constants)
-- Hence the test for phase zero (which is the phase for all the final
-- simplifications).  Until phase zero we take no special notice of
-- top level things, but then we become more leery about inlining
-- them.  

\end{code}

%************************************************************************
%*									*
                  postInlineUnconditionally
%*									*
%************************************************************************

postInlineUnconditionally
~~~~~~~~~~~~~~~~~~~~~~~~~
@postInlineUnconditionally@ decides whether to unconditionally inline
a thing based on the form of its RHS; in particular if it has a
trivial RHS.  If so, we can inline and discard the binding altogether.

NB: a loop breaker has must_keep_binding = True and non-loop-breakers
only have *forward* references. Hence, it's safe to discard the binding
	
NOTE: This isn't our last opportunity to inline.  We're at the binding
site right now, and we'll get another opportunity when we get to the
ocurrence(s)

Note that we do this unconditional inlining only for trival RHSs.
Don't inline even WHNFs inside lambdas; doing so may simply increase
allocation when the function is called. This isn't the last chance; see
NOTE above.

NB: Even inline pragmas (e.g. IMustBeINLINEd) are ignored here Why?
Because we don't even want to inline them into the RHS of constructor
arguments. See NOTE above

NB: At one time even NOINLINE was ignored here: if the rhs is trivial
it's best to inline it anyway.  We often get a=E; b=a from desugaring,
with both a and b marked NOINLINE.  But that seems incompatible with
our new view that inlining is like a RULE, so I'm sticking to the 'active'
story for now.

\begin{code}
postInlineUnconditionally 
    :: SimplEnv -> TopLevelFlag
    -> OutId		-- The binder (an InId would be fine too)
    -> OccInfo 		-- From the InId
    -> OutExpr
    -> Unfolding
    -> Bool
postInlineUnconditionally env top_lvl bndr occ_info rhs unfolding
  | not active		        = False
  | isLoopBreaker occ_info      = False	-- If it's a loop-breaker of any kind, don't inline
					-- because it might be referred to "earlier"
  | isExportedId bndr           = False
  | isStableUnfolding unfolding = False	-- Note [InlineRule and postInlineUnconditionally]
  | isTopLevel top_lvl          = False	-- Note [Top level and postInlineUnconditionally]
  | exprIsTrivial rhs 	        = True
  | otherwise
  = case occ_info of
	-- The point of examining occ_info here is that for *non-values* 
	-- that occur outside a lambda, the call-site inliner won't have
	-- a chance (becuase it doesn't know that the thing
	-- only occurs once).   The pre-inliner won't have gotten
	-- it either, if the thing occurs in more than one branch
	-- So the main target is things like
	--	let x = f y in
	--	case v of
	--	   True  -> case x of ...
	--	   False -> case x of ...
	-- This is very important in practice; e.g. wheel-seive1 doubles 
	-- in allocation if you miss this out
      OneOcc in_lam _one_br int_cxt	-- OneOcc => no code-duplication issue
	->     smallEnoughToInline unfolding	-- Small enough to dup
			-- ToDo: consider discount on smallEnoughToInline if int_cxt is true
			--
		 	-- NB: Do NOT inline arbitrarily big things, even if one_br is True
			-- Reason: doing so risks exponential behaviour.  We simplify a big
			--	   expression, inline it, and simplify it again.  But if the
			--	   very same thing happens in the big expression, we get 
			--	   exponential cost!
			-- PRINCIPLE: when we've already simplified an expression once, 
			-- make sure that we only inline it if it's reasonably small.

           && (not in_lam || 
			-- Outside a lambda, we want to be reasonably aggressive
			-- about inlining into multiple branches of case
			-- e.g. let x = <non-value> 
			--	in case y of { C1 -> ..x..; C2 -> ..x..; C3 -> ... } 
			-- Inlining can be a big win if C3 is the hot-spot, even if
			-- the uses in C1, C2 are not 'interesting'
			-- An example that gets worse if you add int_cxt here is 'clausify'

		(isCheapUnfolding unfolding && int_cxt))
			-- isCheap => acceptable work duplication; in_lam may be true
			-- int_cxt to prevent us inlining inside a lambda without some 
			-- good reason.  See the notes on int_cxt in preInlineUnconditionally

      IAmDead -> True	-- This happens; for example, the case_bndr during case of
			-- known constructor:  case (a,b) of x { (p,q) -> ... }
			-- Here x isn't mentioned in the RHS, so we don't want to
			-- create the (dead) let-binding  let x = (a,b) in ...

      _ -> False

-- Here's an example that we don't handle well:
--	let f = if b then Left (\x.BIG) else Right (\y.BIG)
--	in \y. ....case f of {...} ....
-- Here f is used just once, and duplicating the case work is fine (exprIsCheap).
-- But
--  - We can't preInlineUnconditionally because that woud invalidate
--    the occ info for b.
--  - We can't postInlineUnconditionally because the RHS is big, and
--    that risks exponential behaviour
--  - We can't call-site inline, because the rhs is big
-- Alas!

  where
    active = isActive (sm_phase (getMode env)) (idInlineActivation bndr)
        -- See Note [pre/postInlineUnconditionally in gentle mode]
\end{code}

Note [Top level and postInlineUnconditionally]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We don't do postInlineUnconditionally for top-level things (even for
ones that are trivial):

  * Doing so will inline top-level error expressions that have been
    carefully floated out by FloatOut.  More generally, it might 
    replace static allocation with dynamic.

  * Even for trivial expressions there's a problem.  Consider
      {-# RULE "foo" forall (xs::[T]). reverse xs = ruggle xs #-}
      blah xs = reverse xs
      ruggle = sort
    In one simplifier pass we might fire the rule, getting 
      blah xs = ruggle xs
    but in *that* simplifier pass we must not do postInlineUnconditionally
    on 'ruggle' because then we'll have an unbound occurrence of 'ruggle'

    If the rhs is trivial it'll be inlined by callSiteInline, and then
    the binding will be dead and discarded by the next use of OccurAnal

  * There is less point, because the main goal is to get rid of local
    bindings used in multiple case branches.  
    

Note [InlineRule and postInlineUnconditionally]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Do not do postInlineUnconditionally if the Id has an InlineRule, otherwise
we lose the unfolding.  Example

     -- f has InlineRule with rhs (e |> co)
     --   where 'e' is big
     f = e |> co

Then there's a danger we'll optimise to

     f' = e
     f = f' |> co

and now postInlineUnconditionally, losing the InlineRule on f.  Now f'
won't inline because 'e' is too big.

    c.f. Note [InlineRule and preInlineUnconditionally]


%************************************************************************
%*									*
	Rebuilding a lambda
%*									*
%************************************************************************

\begin{code}
mkLam :: SimplEnv -> [OutBndr] -> OutExpr -> SimplM OutExpr
-- mkLam tries three things
--	a) eta reduction, if that gives a trivial expression
--	b) eta expansion [only if there are some value lambdas]

mkLam _b [] body 
  = return body
mkLam _env bndrs body
  = do	{ dflags <- getDOptsSmpl
	; mkLam' dflags bndrs body }
  where
    mkLam' :: DynFlags -> [OutBndr] -> OutExpr -> SimplM OutExpr
    mkLam' dflags bndrs (Cast body co)
      | not (any bad bndrs)
	-- Note [Casts and lambdas]
      = do { lam <- mkLam' dflags bndrs body
	   ; return (mkCoerce (mkPiTypes bndrs co) lam) }
      where
	co_vars  = tyVarsOfType co
	bad bndr = isCoVar bndr && bndr `elemVarSet` co_vars      

    mkLam' dflags bndrs body@(Lam {})
      = mkLam' dflags (bndrs ++ bndrs1) body1
      where
        (bndrs1, body1) = collectBinders body

    mkLam' dflags bndrs body
      | dopt Opt_DoEtaReduction dflags
      , Just etad_lam <- tryEtaReduce bndrs body
      = do { tick (EtaReduction (head bndrs))
	   ; return etad_lam }

      | otherwise 
      = return (mkLams bndrs body)
\end{code}


Note [Casts and lambdas]
~~~~~~~~~~~~~~~~~~~~~~~~
Consider 
	(\x. (\y. e) `cast` g1) `cast` g2
There is a danger here that the two lambdas look separated, and the 
full laziness pass might float an expression to between the two.

So this equation in mkLam' floats the g1 out, thus:
	(\x. e `cast` g1)  -->  (\x.e) `cast` (tx -> g1)
where x:tx.

In general, this floats casts outside lambdas, where (I hope) they
might meet and cancel with some other cast:
	\x. e `cast` co   ===>   (\x. e) `cast` (tx -> co)
	/\a. e `cast` co  ===>   (/\a. e) `cast` (/\a. co)
	/\g. e `cast` co  ===>   (/\g. e) `cast` (/\g. co)
  		  	  (if not (g `in` co))

Notice that it works regardless of 'e'.  Originally it worked only
if 'e' was itself a lambda, but in some cases that resulted in 
fruitless iteration in the simplifier.  A good example was when
compiling Text.ParserCombinators.ReadPrec, where we had a definition 
like	(\x. Get `cast` g)
where Get is a constructor with nonzero arity.  Then mkLam eta-expanded
the Get, and the next iteration eta-reduced it, and then eta-expanded 
it again.

Note also the side condition for the case of coercion binders.
It does not make sense to transform
	/\g. e `cast` g  ==>  (/\g.e) `cast` (/\g.g)
because the latter is not well-kinded.

%************************************************************************
%*									*
              Eta expansion									 
%*									*
%************************************************************************

When we meet a let-binding we try eta-expansion.  To find the 
arity of the RHS we use a little fixpoint analysis; see Note [Arity analysis]

\begin{code}
tryEtaExpand :: SimplEnv -> OutId -> OutExpr -> SimplM (Arity, OutExpr)
-- See Note [Eta-expanding at let bindings]
tryEtaExpand env bndr rhs
  = do { dflags <- getDOptsSmpl
       ; (new_arity, new_rhs) <- try_expand dflags

       ; WARN( new_arity < old_arity || new_arity < _dmd_arity, 
               (ptext (sLit "Arity decrease:") <+> (ppr bndr <+> ppr old_arity
		<+> ppr new_arity <+> ppr _dmd_arity) $$ ppr new_rhs) )
			-- Note [Arity decrease]
         return (new_arity, new_rhs) }
  where
    try_expand dflags
      | sm_eta_expand (getMode env)      -- Provided eta-expansion is on
      , not (exprIsTrivial rhs)
      , let dicts_cheap = dopt Opt_DictsCheap dflags
            new_arity   = findArity dicts_cheap bndr rhs old_arity
      , new_arity > rhs_arity
      = do { tick (EtaExpansion bndr)
           ; return (new_arity, etaExpand new_arity rhs) }
      | otherwise
      = return (rhs_arity, rhs)

    rhs_arity  = exprArity rhs
    old_arity  = idArity bndr
    _dmd_arity = length $ fst $ splitStrictSig $ idStrictness bndr

findArity :: Bool -> Id -> CoreExpr -> Arity -> Arity
-- This implements the fixpoint loop for arity analysis
-- See Note [Arity analysis]
findArity dicts_cheap bndr rhs old_arity
  = go (exprEtaExpandArity (mk_cheap_fn dicts_cheap init_cheap_app) rhs)
       -- We always call exprEtaExpandArity once, but usually 
       -- that produces a result equal to old_arity, and then
       -- we stop right away (since arities should not decrease)
       -- Result: the common case is that there is just one iteration
  where
    go :: Arity -> Arity
    go cur_arity
      | cur_arity <= old_arity = cur_arity	
      | new_arity == cur_arity = cur_arity
      | otherwise = ASSERT( new_arity < cur_arity )
                    pprTrace "Exciting arity" 
                       (vcat [ ppr bndr <+> ppr cur_arity <+> ppr new_arity
                             , ppr rhs])
                    go new_arity
      where
        new_arity = exprEtaExpandArity (mk_cheap_fn dicts_cheap cheap_app) rhs
      
        cheap_app :: CheapAppFun
        cheap_app fn n_val_args
          | fn == bndr = n_val_args < cur_arity
          | otherwise  = isCheapApp fn n_val_args

    init_cheap_app :: CheapAppFun
    init_cheap_app fn n_val_args
      | fn == bndr = True
      | otherwise  = isCheapApp fn n_val_args
 
mk_cheap_fn :: Bool -> CheapAppFun -> CheapFun
mk_cheap_fn dicts_cheap cheap_app
  | not dicts_cheap
  = \e _     -> exprIsCheap' cheap_app e
  | otherwise
  = \e mb_ty -> exprIsCheap' cheap_app e
             || case mb_ty of
                  Nothing -> False
                  Just ty -> isDictLikeTy ty
	-- If the experimental -fdicts-cheap flag is on, we eta-expand through
	-- dictionary bindings.  This improves arities. Thereby, it also
	-- means that full laziness is less prone to floating out the
	-- application of a function to its dictionary arguments, which
	-- can thereby lose opportunities for fusion.  Example:
	-- 	foo :: Ord a => a -> ...
	--	foo = /\a \(d:Ord a). let d' = ...d... in \(x:a). ....
	--		-- So foo has arity 1
	--
	--	f = \x. foo dInt $ bar x
	--
	-- The (foo DInt) is floated out, and makes ineffective a RULE 
	--	foo (bar x) = ...
	--
	-- One could go further and make exprIsCheap reply True to any
	-- dictionary-typed expression, but that's more work.
	-- 
	-- See Note [Dictionary-like types] in TcType.lhs for why we use
  	-- isDictLikeTy here rather than isDictTy
\end{code}

Note [Eta-expanding at let bindings]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We now eta expand at let-bindings, which is where the payoff 
comes. 

One useful consequence is this example:
   genMap :: C a => ...
   {-# INLINE genMap #-}
   genMap f xs = ...

   myMap :: D a => ...
   {-# INLINE myMap #-}
   myMap = genMap

Notice that 'genMap' should only inline if applied to two arguments.
In the InlineRule for myMap we'll have the unfolding 
    (\d -> genMap Int (..d..))  
We do not want to eta-expand to 
    (\d f xs -> genMap Int (..d..) f xs) 
because then 'genMap' will inline, and it really shouldn't: at least
as far as the programmer is concerned, it's not applied to two
arguments!

Note [Arity analysis]
~~~~~~~~~~~~~~~~~~~~~
The motivating example for arity analysis is this:
 
  f = \x. let g = f (x+1) 
          in \y. ...g...

What arity does f have?  Really it should have arity 2, but a naive
look at the RHS won't see that.  You need a fixpoint analysis which
says it has arity "infinity" the first time round.

This example happens a lot; it first showed up in Andy Gill's thesis,
fifteen years ago!  It also shows up in the code for 'rnf' on lists
in Trac #4138.

The analysis is easy to achieve because exprEtaExpandArity takes an
argument
     type CheapFun = CoreExpr -> Maybe Type -> Bool
used to decide if an expression is cheap enough to push inside a 
lambda.  And exprIsCheap' in turn takes an argument
     type CheapAppFun = Id -> Int -> Bool
which tells when an application is cheap. This makes it easy to
write the analysis loop.

The analysis is cheap-and-cheerful because it doesn't deal with
mutual recursion.  But the self-recursive case is the important one.


%************************************************************************
%*									*
\subsection{Floating lets out of big lambdas}
%*									*
%************************************************************************

Note [Floating and type abstraction]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider this:
	x = /\a. C e1 e2
We'd like to float this to 
	y1 = /\a. e1
	y2 = /\a. e2
	x  = /\a. C (y1 a) (y2 a)
for the usual reasons: we want to inline x rather vigorously.

You may think that this kind of thing is rare.  But in some programs it is
common.  For example, if you do closure conversion you might get:

	data a :-> b = forall e. (e -> a -> b) :$ e

	f_cc :: forall a. a :-> a
	f_cc = /\a. (\e. id a) :$ ()

Now we really want to inline that f_cc thing so that the
construction of the closure goes away. 

So I have elaborated simplLazyBind to understand right-hand sides that look
like
	/\ a1..an. body

and treat them specially. The real work is done in SimplUtils.abstractFloats,
but there is quite a bit of plumbing in simplLazyBind as well.

The same transformation is good when there are lets in the body:

	/\abc -> let(rec) x = e in b
   ==>
	let(rec) x' = /\abc -> let x = x' a b c in e
	in 
	/\abc -> let x = x' a b c in b

This is good because it can turn things like:

	let f = /\a -> letrec g = ... g ... in g
into
	letrec g' = /\a -> ... g' a ...
	in
	let f = /\ a -> g' a

which is better.  In effect, it means that big lambdas don't impede
let-floating.

This optimisation is CRUCIAL in eliminating the junk introduced by
desugaring mutually recursive definitions.  Don't eliminate it lightly!

[May 1999]  If we do this transformation *regardless* then we can
end up with some pretty silly stuff.  For example, 

	let 
	    st = /\ s -> let { x1=r1 ; x2=r2 } in ...
	in ..
becomes
	let y1 = /\s -> r1
	    y2 = /\s -> r2
	    st = /\s -> ...[y1 s/x1, y2 s/x2]
	in ..

Unless the "..." is a WHNF there is really no point in doing this.
Indeed it can make things worse.  Suppose x1 is used strictly,
and is of the form

	x1* = case f y of { (a,b) -> e }

If we abstract this wrt the tyvar we then can't do the case inline
as we would normally do.

That's why the whole transformation is part of the same process that
floats let-bindings and constructor arguments out of RHSs.  In particular,
it is guarded by the doFloatFromRhs call in simplLazyBind.


\begin{code}
abstractFloats :: [OutTyVar] -> SimplEnv -> OutExpr -> SimplM ([OutBind], OutExpr)
abstractFloats main_tvs body_env body
  = ASSERT( notNull body_floats )
    do	{ (subst, float_binds) <- mapAccumLM abstract empty_subst body_floats
	; return (float_binds, CoreSubst.substExpr (text "abstract_floats1") subst body) }
  where
    main_tv_set = mkVarSet main_tvs
    body_floats = getFloats body_env
    empty_subst = CoreSubst.mkEmptySubst (seInScope body_env)

    abstract :: CoreSubst.Subst -> OutBind -> SimplM (CoreSubst.Subst, OutBind)
    abstract subst (NonRec id rhs)
      = do { (poly_id, poly_app) <- mk_poly tvs_here id
	   ; let poly_rhs = mkLams tvs_here rhs'
		 subst'   = CoreSubst.extendIdSubst subst id poly_app
	   ; return (subst', (NonRec poly_id poly_rhs)) }
      where
	rhs' = CoreSubst.substExpr (text "abstract_floats2") subst rhs
	tvs_here | any isCoVar main_tvs = main_tvs	-- Note [Abstract over coercions]
		 | otherwise 
		 = varSetElems (main_tv_set `intersectVarSet` exprSomeFreeVars isTyCoVar rhs')
	
		-- Abstract only over the type variables free in the rhs
		-- wrt which the new binding is abstracted.  But the naive
		-- approach of abstract wrt the tyvars free in the Id's type
		-- fails. Consider:
		--	/\ a b -> let t :: (a,b) = (e1, e2)
		--		      x :: a     = fst t
		--		  in ...
		-- Here, b isn't free in x's type, but we must nevertheless
		-- abstract wrt b as well, because t's type mentions b.
		-- Since t is floated too, we'd end up with the bogus:
		--	poly_t = /\ a b -> (e1, e2)
		--	poly_x = /\ a   -> fst (poly_t a *b*)
		-- So for now we adopt the even more naive approach of
		-- abstracting wrt *all* the tyvars.  We'll see if that
		-- gives rise to problems.   SLPJ June 98

    abstract subst (Rec prs)
       = do { (poly_ids, poly_apps) <- mapAndUnzipM (mk_poly tvs_here) ids
	    ; let subst' = CoreSubst.extendSubstList subst (ids `zip` poly_apps)
		  poly_rhss = [mkLams tvs_here (CoreSubst.substExpr (text "abstract_floats3") subst' rhs) 
                              | rhs <- rhss]
	    ; return (subst', Rec (poly_ids `zip` poly_rhss)) }
       where
	 (ids,rhss) = unzip prs
	 	-- For a recursive group, it's a bit of a pain to work out the minimal
		-- set of tyvars over which to abstract:
		--	/\ a b c.  let x = ...a... in
		--	 	   letrec { p = ...x...q...
		--			    q = .....p...b... } in
		--		   ...
		-- Since 'x' is abstracted over 'a', the {p,q} group must be abstracted
		-- over 'a' (because x is replaced by (poly_x a)) as well as 'b'.  
		-- Since it's a pain, we just use the whole set, which is always safe
		-- 
		-- If you ever want to be more selective, remember this bizarre case too:
		--	x::a = x
		-- Here, we must abstract 'x' over 'a'.
	 tvs_here = main_tvs

    mk_poly tvs_here var
      = do { uniq <- getUniqueM
	   ; let  poly_name = setNameUnique (idName var) uniq		-- Keep same name
		  poly_ty   = mkForAllTys tvs_here (idType var)	-- But new type of course
		  poly_id   = transferPolyIdInfo var tvs_here $ -- Note [transferPolyIdInfo] in Id.lhs
			      mkLocalId poly_name poly_ty 
	   ; return (poly_id, mkTyApps (Var poly_id) (mkTyVarTys tvs_here)) }
		-- In the olden days, it was crucial to copy the occInfo of the original var, 
		-- because we were looking at occurrence-analysed but as yet unsimplified code!
		-- In particular, we mustn't lose the loop breakers.  BUT NOW we are looking
		-- at already simplified code, so it doesn't matter
		-- 
		-- It's even right to retain single-occurrence or dead-var info:
		-- Suppose we started with  /\a -> let x = E in B
		-- where x occurs once in B. Then we transform to:
		--	let x' = /\a -> E in /\a -> let x* = x' a in B
		-- where x* has an INLINE prag on it.  Now, once x* is inlined,
		-- the occurrences of x' will be just the occurrences originally
		-- pinned on x.
\end{code}

Note [Abstract over coercions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If a coercion variable (g :: a ~ Int) is free in the RHS, then so is the
type variable a.  Rather than sort this mess out, we simply bale out and abstract
wrt all the type variables if any of them are coercion variables.


Historical note: if you use let-bindings instead of a substitution, beware of this:

		-- Suppose we start with:
		--
		--	x = /\ a -> let g = G in E
		--
		-- Then we'll float to get
		--
		--	x = let poly_g = /\ a -> G
		--	    in /\ a -> let g = poly_g a in E
		--
		-- But now the occurrence analyser will see just one occurrence
		-- of poly_g, not inside a lambda, so the simplifier will
		-- PreInlineUnconditionally poly_g back into g!  Badk to square 1!
		-- (I used to think that the "don't inline lone occurrences" stuff
		--  would stop this happening, but since it's the *only* occurrence,
		--  PreInlineUnconditionally kicks in first!)
		--
		-- Solution: put an INLINE note on g's RHS, so that poly_g seems
		--	     to appear many times.  (NB: mkInlineMe eliminates
		--	     such notes on trivial RHSs, so do it manually.)

%************************************************************************
%*									*
		prepareAlts
%*									*
%************************************************************************

prepareAlts tries these things:

1.  Eliminate alternatives that cannot match, including the
    DEFAULT alternative.

2.  If the DEFAULT alternative can match only one possible constructor,
    then make that constructor explicit.
    e.g.
        case e of x { DEFAULT -> rhs }
     ===>
        case e of x { (a,b) -> rhs }
    where the type is a single constructor type.  This gives better code
    when rhs also scrutinises x or e.

3. Returns a list of the constructors that cannot holds in the
   DEFAULT alternative (if there is one)

Here "cannot match" includes knowledge from GADTs

It's a good idea do do this stuff before simplifying the alternatives, to
avoid simplifying alternatives we know can't happen, and to come up with
the list of constructors that are handled, to put into the IdInfo of the
case binder, for use when simplifying the alternatives.

Eliminating the default alternative in (1) isn't so obvious, but it can
happen:

data Colour = Red | Green | Blue

f x = case x of
        Red -> ..
        Green -> ..
        DEFAULT -> h x

h y = case y of
        Blue -> ..
        DEFAULT -> [ case y of ... ]

If we inline h into f, the default case of the inlined h can't happen.
If we don't notice this, we may end up filtering out *all* the cases
of the inner case y, which give us nowhere to go!

\begin{code}
prepareAlts :: OutExpr -> OutId -> [InAlt] -> SimplM ([AltCon], [InAlt])
prepareAlts scrut case_bndr' alts
  = do	{ let (alts_wo_default, maybe_deflt) = findDefault alts
	      alt_cons = [con | (con,_,_) <- alts_wo_default]
	      imposs_deflt_cons = nub (imposs_cons ++ alt_cons)
		-- "imposs_deflt_cons" are handled 
		--   EITHER by the context, 
		--   OR by a non-DEFAULT branch in this case expression.

	; default_alts <- prepareDefault case_bndr' mb_tc_app 
					 imposs_deflt_cons maybe_deflt

	; let trimmed_alts = filterOut impossible_alt alts_wo_default
	      merged_alts  = mergeAlts trimmed_alts default_alts
		-- We need the mergeAlts in case the new default_alt 
		-- has turned into a constructor alternative.
		-- The merge keeps the inner DEFAULT at the front, if there is one
		-- and interleaves the alternatives in the right order

	; return (imposs_deflt_cons, merged_alts) }
  where
    mb_tc_app = splitTyConApp_maybe (idType case_bndr')
    Just (_, inst_tys) = mb_tc_app 

    imposs_cons = case scrut of
		    Var v -> otherCons (idUnfolding v)
		    _     -> []

    impossible_alt :: CoreAlt -> Bool
    impossible_alt (con, _, _) | con `elem` imposs_cons = True
    impossible_alt (DataAlt con, _, _) = dataConCannotMatch inst_tys con
    impossible_alt _                   = False


prepareDefault :: OutId		-- Case binder; need just for its type. Note that as an
				--   OutId, it has maximum information; this is important.
				--   Test simpl013 is an example
	       -> Maybe (TyCon, [Type])	-- Type of scrutinee, decomposed
	       -> [AltCon]	-- These cons can't happen when matching the default
	       -> Maybe InExpr	-- Rhs
	       -> SimplM [InAlt]	-- Still unsimplified
					-- We use a list because it's what mergeAlts expects,

--------- Fill in known constructor -----------
prepareDefault case_bndr (Just (tycon, inst_tys)) imposs_cons (Just deflt_rhs)
  | 	-- This branch handles the case where we are 
	-- scrutinisng an algebraic data type
    isAlgTyCon tycon		-- It's a data type, tuple, or unboxed tuples.  
  , not (isNewTyCon tycon)	-- We can have a newtype, if we are just doing an eval:
				-- 	case x of { DEFAULT -> e }
				-- and we don't want to fill in a default for them!
  , Just all_cons <- tyConDataCons_maybe tycon
  , not (null all_cons)	
	-- This is a tricky corner case.  If the data type has no constructors,
	-- which GHC allows, then the case expression will have at most a default
	-- alternative.  We don't want to eliminate that alternative, because the
	-- invariant is that there's always one alternative.  It's more convenient
	-- to leave	
	--	case x of { DEFAULT -> e }     
	-- as it is, rather than transform it to
	--	error "case cant match"
	-- which would be quite legitmate.  But it's a really obscure corner, and
	-- not worth wasting code on.
  , let imposs_data_cons = [con | DataAlt con <- imposs_cons]	-- We now know it's a data type 
	impossible con   = con `elem` imposs_data_cons || dataConCannotMatch inst_tys con
  = case filterOut impossible all_cons of
	[]    -> return []	-- Eliminate the default alternative
				-- altogether if it can't match

	[con] -> 	-- It matches exactly one constructor, so fill it in
		 do { tick (FillInCaseDefault case_bndr)
                    ; us <- getUniquesM
                    ; let (ex_tvs, co_tvs, arg_ids) =
                              dataConRepInstPat us con inst_tys
                    ; return [(DataAlt con, ex_tvs ++ co_tvs ++ arg_ids, deflt_rhs)] }

	_ -> return [(DEFAULT, [], deflt_rhs)]

  | debugIsOn, isAlgTyCon tycon
  , null (tyConDataCons tycon)
  , not (isFamilyTyCon tycon || isAbstractTyCon tycon)
	-- Check for no data constructors
        -- This can legitimately happen for abstract types and type families,
        -- so don't report that
  = pprTrace "prepareDefault" (ppr case_bndr <+> ppr tycon)
        $ return [(DEFAULT, [], deflt_rhs)]

--------- Catch-all cases -----------
prepareDefault _case_bndr _bndr_ty _imposs_cons (Just deflt_rhs)
  = return [(DEFAULT, [], deflt_rhs)]

prepareDefault _case_bndr _bndr_ty _imposs_cons Nothing
  = return []	-- No default branch
\end{code}



%************************************************************************
%*									*
		mkCase
%*									*
%************************************************************************

mkCase tries these things

1.  Merge Nested Cases

       case e of b {             ==>   case e of b {
    	 p1 -> rhs1	                 p1 -> rhs1
    	 ...	                         ...
    	 pm -> rhsm                      pm -> rhsm
    	 _  -> case b of b' {            pn -> let b'=b in rhsn
 		     pn -> rhsn          ...
 		     ...                 po -> let b'=b in rhso
 		     po -> rhso          _  -> let b'=b in rhsd
 		     _  -> rhsd
       }  
    
    which merges two cases in one case when -- the default alternative of
    the outer case scrutises the same variable as the outer case. This
    transformation is called Case Merging.  It avoids that the same
    variable is scrutinised multiple times.

2.  Eliminate Identity Case

	case e of 		===> e
		True  -> True;
		False -> False

    and similar friends.

3.  Merge identical alternatives.
    If several alternatives are identical, merge them into
    a single DEFAULT alternative.  I've occasionally seen this 
    making a big difference:

	case e of		=====>     case e of
	  C _ -> f x			     D v -> ....v....
	  D v -> ....v....		     DEFAULT -> f x
	  DEFAULT -> f x

   The point is that we merge common RHSs, at least for the DEFAULT case.
   [One could do something more elaborate but I've never seen it needed.]
   To avoid an expensive test, we just merge branches equal to the *first*
   alternative; this picks up the common cases
	a) all branches equal
	b) some branches equal to the DEFAULT (which occurs first)

The case where Merge Identical Alternatives transformation showed up
was like this (base/Foreign/C/Err/Error.lhs):

	x | p `is` 1 -> e1
	  | p `is` 2 -> e2
	...etc...

where @is@ was something like
	
	p `is` n = p /= (-1) && p == n

This gave rise to a horrible sequence of cases

	case p of
	  (-1) -> $j p
	  1    -> e1
	  DEFAULT -> $j p

and similarly in cascade for all the join points!


\begin{code}
mkCase, mkCase1, mkCase2 
   :: DynFlags 
   -> OutExpr -> OutId
   -> [OutAlt]		-- Alternatives in standard (increasing) order
   -> SimplM OutExpr

--------------------------------------------------
--	1. Merge Nested Cases
--------------------------------------------------

mkCase dflags scrut outer_bndr ((DEFAULT, _, deflt_rhs) : outer_alts)
  | dopt Opt_CaseMerge dflags
  , Case (Var inner_scrut_var) inner_bndr _ inner_alts <- deflt_rhs
  , inner_scrut_var == outer_bndr
  = do	{ tick (CaseMerge outer_bndr)

	; let wrap_alt (con, args, rhs) = ASSERT( outer_bndr `notElem` args )
                                          (con, args, wrap_rhs rhs)
		-- Simplifier's no-shadowing invariant should ensure
		-- that outer_bndr is not shadowed by the inner patterns
              wrap_rhs rhs = Let (NonRec inner_bndr (Var outer_bndr)) rhs
		-- The let is OK even for unboxed binders, 

	      wrapped_alts | isDeadBinder inner_bndr = inner_alts
                           | otherwise               = map wrap_alt inner_alts

	      merged_alts = mergeAlts outer_alts wrapped_alts
		-- NB: mergeAlts gives priority to the left
		--	case x of 
		--	  A -> e1
		--	  DEFAULT -> case x of 
		--			A -> e2
		--			B -> e3
		-- When we merge, we must ensure that e1 takes 
		-- precedence over e2 as the value for A!  

	; mkCase1 dflags scrut outer_bndr merged_alts
	}
    	-- Warning: don't call mkCase recursively!
    	-- Firstly, there's no point, because inner alts have already had
    	-- mkCase applied to them, so they won't have a case in their default
    	-- Secondly, if you do, you get an infinite loop, because the bindCaseBndr
    	-- in munge_rhs may put a case into the DEFAULT branch!

mkCase dflags scrut bndr alts = mkCase1 dflags scrut bndr alts

--------------------------------------------------
--	2. Eliminate Identity Case
--------------------------------------------------

mkCase1 _dflags scrut case_bndr alts	-- Identity case
  | all identity_alt alts
  = do { tick (CaseIdentity case_bndr)
       ; return (re_cast scrut) }
  where
    identity_alt (con, args, rhs) = check_eq con args (de_cast rhs)

    check_eq DEFAULT       _    (Var v)   = v == case_bndr
    check_eq (LitAlt lit') _    (Lit lit) = lit == lit'
    check_eq (DataAlt con) args rhs       = rhs `cheapEqExpr` mkConApp con (arg_tys ++ varsToCoreExprs args)
					 || rhs `cheapEqExpr` Var case_bndr
    check_eq _ _ _ = False

    arg_tys = map Type (tyConAppArgs (idType case_bndr))

	-- We've seen this:
	--	case e of x { _ -> x `cast` c }
	-- And we definitely want to eliminate this case, to give
	--	e `cast` c
	-- So we throw away the cast from the RHS, and reconstruct
	-- it at the other end.  All the RHS casts must be the same
	-- if (all identity_alt alts) holds.
	-- 
	-- Don't worry about nested casts, because the simplifier combines them
    de_cast (Cast e _) = e
    de_cast e	       = e

    re_cast scrut = case head alts of
			(_,_,Cast _ co) -> Cast scrut co
			_    	        -> scrut

--------------------------------------------------
--	3. Merge Identical Alternatives
--------------------------------------------------
mkCase1 dflags scrut case_bndr ((_con1,bndrs1,rhs1) : con_alts)
  | all isDeadBinder bndrs1			-- Remember the default 
  , length filtered_alts < length con_alts	-- alternative comes first
	-- Also Note [Dead binders]
  = do	{ tick (AltMerge case_bndr)
	; mkCase2 dflags scrut case_bndr alts' }
  where
    alts' = (DEFAULT, [], rhs1) : filtered_alts
    filtered_alts	  = filter keep con_alts
    keep (_con,bndrs,rhs) = not (all isDeadBinder bndrs && rhs `cheapEqExpr` rhs1)

mkCase1 dflags scrut bndr alts = mkCase2 dflags scrut bndr alts

--------------------------------------------------
--	Catch-all
--------------------------------------------------
mkCase2 _dflags scrut bndr alts 
  = return (Case scrut bndr (coreAltsType alts) alts)
\end{code}

Note [Dead binders]
~~~~~~~~~~~~~~~~~~~~
Note that dead-ness is maintained by the simplifier, so that it is
accurate after simplification as well as before.


Note [Cascading case merge]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
Case merging should cascade in one sweep, because it
happens bottom-up

      case e of a {
        DEFAULT -> case a of b 
                      DEFAULT -> case b of c {
                                     DEFAULT -> e
                                     A -> ea
                      B -> eb
        C -> ec
==>
      case e of a {
        DEFAULT -> case a of b 
                      DEFAULT -> let c = b in e
                      A -> let c = b in ea
                      B -> eb
        C -> ec
==>
      case e of a {
        DEFAULT -> let b = a in let c = b in e
        A -> let b = a in let c = b in ea
        B -> let b = a in eb
        C -> ec


However here's a tricky case that we still don't catch, and I don't
see how to catch it in one pass:

  case x of c1 { I# a1 ->
  case a1 of c2 ->
    0 -> ...
    DEFAULT -> case x of c3 { I# a2 ->
               case a2 of ...

After occurrence analysis (and its binder-swap) we get this
 
  case x of c1 { I# a1 -> 
  let x = c1 in		-- Binder-swap addition
  case a1 of c2 -> 
    0 -> ...
    DEFAULT -> case x of c3 { I# a2 ->
               case a2 of ...

When we simplify the inner case x, we'll see that
x=c1=I# a1.  So we'll bind a2 to a1, and get

  case x of c1 { I# a1 -> 
  case a1 of c2 -> 
    0 -> ...
    DEFAULT -> case a1 of ...

This is corect, but we can't do a case merge in this sweep
because c2 /= a1.  Reason: the binding c1=I# a1 went inwards
without getting changed to c1=I# c2.  

I don't think this is worth fixing, even if I knew how. It'll
all come out in the next pass anyway.

  