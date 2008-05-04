{-# LANGUAGE MultiParamTypeClasses, ScopedTypeVariables #-}
{-# OPTIONS -fno-allow-overlapping-instances -fglasgow-exts #-}
-- -fglagow-exts for kind signatures

module ZipDataflow
    ( zdfSolveFrom, zdfRewriteFrom
    , ForwardTransfers(..), BackwardTransfers(..)
    , ForwardRewrites(..),  BackwardRewrites(..) 
    , ForwardFixedPoint, BackwardFixedPoint
    , zdfFpFacts
    , zdfFpOutputFact
    , zdfGraphChanged
    , zdfDecoratedGraph -- not yet implemented
    , zdfFpContents
    , zdfFpLastOuts
    )
where

import CmmTx
import DFMonad
import MkZipCfg
import ZipCfg
import qualified ZipCfg as G

import Maybes
import Outputable
import Panic
import UniqFM
import UniqSupply

import Control.Monad
import Maybe


type PassName = String
type Fuel = OptimizationFuel

data RewritingDepth = RewriteShallow | RewriteDeep
-- When a transformation proposes to rewrite a node, 
-- you can either ask the system to
--  * "shallow": accept the new graph, analyse it without further rewriting
--  * "deep": recursively analyse-and-rewrite the new graph

-----------------------------
-- zdfSolveFrom is a pure analysis with no rewriting

class DataflowSolverDirection transfers fixedpt where
  zdfSolveFrom   :: (DebugNodes m l, Outputable a)
                 => BlockEnv a        -- Initial facts (unbound == bottom)
                 -> PassName
                 -> DataflowLattice a -- Lattice
                 -> transfers m l a   -- Dataflow transfer functions
                 -> a                 -- Fact flowing in (at entry or exit)
                 -> Graph m l         -- Graph to be analyzed
                 -> fixedpt m l a ()  -- Answers

-- There are exactly two instances: forward and backward
instance DataflowSolverDirection ForwardTransfers ForwardFixedPoint
  where zdfSolveFrom = solve_f

instance DataflowSolverDirection BackwardTransfers BackwardFixedPoint
  where zdfSolveFrom = solve_b

data ForwardTransfers middle last a = ForwardTransfers
    { ft_first_out  :: a -> BlockId -> a
    , ft_middle_out :: a -> middle  -> a
    , ft_last_outs  :: a -> last    -> LastOutFacts a
    , ft_exit_out   :: a            -> a
    } 

newtype LastOutFacts a = LastOutFacts [(BlockId, a)] 
  -- ^ These are facts flowing out of a last node to the node's successors.
  -- They are either to be set (if they pertain to the graph currently
  -- under analysis) or propagated out of a sub-analysis

data BackwardTransfers middle last a = BackwardTransfers
    { bt_first_in  :: a              -> BlockId -> a
    , bt_middle_in :: a              -> middle  -> a
    , bt_last_in   :: (BlockId -> a) -> last    -> a
    } 

data CommonFixedPoint m l fact a = FP
    { fp_facts     :: BlockEnv fact
    , fp_out       :: fact  -- entry for backward; exit for forward
    , fp_changed   :: ChangeFlag
    , fp_dec_graph :: Graph (fact, m) (fact, l)
    , fp_contents  :: a
    }

type BackwardFixedPoint = CommonFixedPoint

data ForwardFixedPoint m l fact a = FFP
    { ffp_common    :: CommonFixedPoint m l fact a
    , zdfFpLastOuts :: LastOutFacts fact
    }

-----------------------------
-- zdfRewriteFrom is an interleaved analysis and transformation

class DataflowSolverDirection transfers fixedpt =>
      DataflowDirection transfers fixedpt rewrites 
			(graph :: * -> * -> *) where
  zdfRewriteFrom :: (DebugNodes m l, Outputable a)
                 => RewritingDepth
                 -> BlockEnv a
                 -> PassName
                 -> DataflowLattice a
                 -> transfers m l a
                 -> rewrites m l a graph
                 -> a                 -- fact flowing in (at entry or exit)
                 -> Graph m l
                 -> UniqSupply
                 -> FuelMonad (fixedpt m l a (Graph m l))

-- There are currently four instances, but there could be more
--	forward, backward (instantiates transfers, fixedpt, rewrites)
--	Graph, AGraph     (instantiates graph)

instance DataflowDirection ForwardTransfers ForwardFixedPoint ForwardRewrites Graph
  where zdfRewriteFrom = rewrite_f_graph

instance DataflowDirection ForwardTransfers ForwardFixedPoint ForwardRewrites AGraph
  where zdfRewriteFrom = rewrite_f_agraph

instance DataflowDirection BackwardTransfers BackwardFixedPoint BackwardRewrites Graph
  where zdfRewriteFrom = rewrite_b_graph

instance DataflowDirection BackwardTransfers BackwardFixedPoint BackwardRewrites AGraph
  where zdfRewriteFrom = rewrite_b_agraph

data ForwardRewrites middle last a g = ForwardRewrites
    { fr_first  :: a -> BlockId -> Maybe (g middle last)
    , fr_middle :: a -> middle  -> Maybe (g middle last)
    , fr_last   :: a -> last    -> Maybe (g middle last)
    , fr_exit   :: a            -> Maybe (g middle last)
    } 

data BackwardRewrites middle last a g = BackwardRewrites
    { br_first  :: a              -> BlockId -> Maybe (g middle last)
    , br_middle :: a              -> middle  -> Maybe (g middle last)
    , br_last   :: (BlockId -> a) -> last    -> Maybe (g middle last)
    , br_exit   ::                              Maybe (g middle last)
    } 

class FixedPoint fp where
    zdfFpFacts        :: fp m l fact a -> BlockEnv fact
    zdfFpOutputFact   :: fp m l fact a -> fact  -- entry for backward; exit for forward
    zdfGraphChanged   :: fp m l fact a -> ChangeFlag
    zdfDecoratedGraph :: fp m l fact a -> Graph (fact, m) (fact, l)
    zdfFpContents     :: fp m l fact a -> a
    zdfFpMap          :: (a -> b) -> (fp m l fact a -> fp m l fact b)



-----------------------------------------------------------
--	solve_f: forward, pure 

solve_f         :: (DebugNodes m l, Outputable a)
                => BlockEnv a        -- initial facts (unbound == bottom)
                -> PassName
                -> DataflowLattice a -- lattice
                -> ForwardTransfers m l a   -- dataflow transfer functions
                -> a
                -> Graph m l         -- graph to be analyzed
                -> ForwardFixedPoint m l a ()  -- answers
solve_f env name lattice transfers in_fact g =
   runWithInfiniteFuel $ runDFM panic_us lattice $
                         fwd_pure_anal name env transfers in_fact g
 where panic_us = panic "pure analysis pulled on a UniqSupply"
    
rewrite_f_graph  :: (DebugNodes m l, Outputable a)
                 => RewritingDepth
                 -> BlockEnv a
                 -> PassName
                 -> DataflowLattice a
                 -> ForwardTransfers m l a
                 -> ForwardRewrites m l a Graph
                 -> a                 -- fact flowing in (at entry or exit)
                 -> Graph m l
                 -> UniqSupply
                 -> FuelMonad (ForwardFixedPoint m l a (Graph m l))
rewrite_f_graph depth start_facts name lattice transfers rewrites in_fact g u =
    runDFM u lattice $
    do fuel <- fuelRemaining
       (fp, fuel') <- forward_rew maybeRewriteWithFuel return depth start_facts name
                      transfers rewrites in_fact g fuel
       fuelDecrement name fuel fuel'
       return fp

rewrite_f_agraph :: (DebugNodes m l, Outputable a)
                 => RewritingDepth
                 -> BlockEnv a
                 -> PassName
                 -> DataflowLattice a
                 -> ForwardTransfers m l a
                 -> ForwardRewrites m l a AGraph
                 -> a                 -- fact flowing in (at entry or exit)
                 -> Graph m l
                 -> UniqSupply
                 -> FuelMonad (ForwardFixedPoint m l a (Graph m l))
rewrite_f_agraph depth start_facts name lattice transfers rewrites in_fact g u =
    runDFM u lattice $
    do fuel <- fuelRemaining
       (fp, fuel') <- forward_rew maybeRewriteWithFuel areturn depth start_facts name
                      transfers rewrites in_fact g fuel
       fuelDecrement name fuel fuel'
       return fp

areturn :: AGraph m l -> DFM a (Graph m l)
areturn g = liftUSM $ graphOfAGraph g


{-
graphToLGraph :: LastNode l => Graph m l -> DFM a (LGraph m l)
graphToLGraph (Graph (ZLast (LastOther l)) blockenv)
    | isBranchNode l = return $ LGraph (branchNodeTarget l) blockenv
graphToLGraph (Graph tail blockenv) =
    do id <- freshBlockId "temporary entry label"
       return $ LGraph id $ insertBlock (Block id tail) blockenv
-}

-- | Here we prefer not simply to slap on 'goto eid' because this
-- introduces an unnecessary basic block at each rewrite, and we don't
-- want to stress out the finite map more than necessary
lgraphToGraph :: LastNode l => LGraph m l -> Graph m l
lgraphToGraph (LGraph eid blocks) =
    if flip any (eltsUFM blocks) $ \block -> any (== eid) (succs block) then
        Graph (ZLast (mkBranchNode eid)) blocks
    else -- common case: entry is not a branch target
        let Block _ entry = lookupBlockEnv blocks eid `orElse` panic "missing entry!"
        in  Graph entry (delFromUFM blocks eid)
    

class (Outputable m, Outputable l, LastNode l, Outputable (LGraph m l)) => DebugNodes m l

fwd_pure_anal :: (DebugNodes m l, Outputable a)
             => PassName
             -> BlockEnv a
             -> ForwardTransfers m l a
             -> a
             -> Graph m l
             -> DFM a (ForwardFixedPoint m l a ())

fwd_pure_anal name env transfers in_fact g =
    do (fp, _) <- anal_f name env transfers panic_rewrites in_fact g panic_fuel
       return fp
  where -- definitiely a case of "I love lazy evaluation"
    anal_f = forward_sol (\_ _ -> Nothing) panic_return panic_depth
    panic_rewrites = panic "pure analysis asked for a rewrite function"
    panic_fuel     = panic "pure analysis asked for fuel"
    panic_return   = panic "pure analysis tried to return a rewritten graph"
    panic_depth    = panic "pure analysis asked for a rewrite depth"

-----------------------------------------------------------------------
--
--	Here beginneth the super-general functions
--
--  Think of them as (typechecked) macros
--   *  They are not exported
--
--   *  They are called by the specialised wrappers
--	above, and always inlined into their callers
--
-- There are four functions, one for each combination of:
--	Forward, Backward
--	Solver, Rewriter
--
-- A "solver" produces a (DFM f (f, Fuel)), 
--	where f is the fact at entry(Bwd)/exit(Fwd)
--	and from the DFM you can extract 
--		the BlockId->f
--		the change-flag
--		and more besides
--
-- A "rewriter" produces a rewritten *Graph* as well
--
-- Both constrain their rewrites by 
--	a) Fuel
--	b) RewritingDepth: shallow/deep

-----------------------------------------------------------------------


{-# INLINE forward_sol #-}
forward_sol
        :: forall m l g a . 
           (DebugNodes m l, LastNode l, Outputable a)
        => (forall a . Fuel -> Maybe a -> Maybe a)
		-- Squashes proposed rewrites if there is
		-- no more fuel; OR if we are doing a pure
		-- analysis, so totally ignore the rewrite
		-- ie. For pure-analysis the fn is (\_ _ -> Nothing)
        -> (g m l -> DFM a (Graph m l))  
		-- Transforms the kind of graph 'g' wanted by the
		-- client (in ForwardRewrites) to the kind forward_sol likes
        -> RewritingDepth	-- Shallow/deep
        -> PassName
        -> BlockEnv a		-- Initial set of facts
        -> ForwardTransfers m l a
        -> ForwardRewrites m l a g
        -> a			-- Entry fact
        -> Graph m l
        -> Fuel
        -> DFM a (ForwardFixedPoint m l a (), Fuel)
forward_sol check_maybe return_graph = forw
 where
  forw :: RewritingDepth
       -> PassName
       -> BlockEnv a
       -> ForwardTransfers m l a
       -> ForwardRewrites m l a g
       -> a
       -> Graph m l
       -> Fuel
       -> DFM a (ForwardFixedPoint m l a (), Fuel)
  forw rewrite name start_facts transfers rewrites =
   let anal_f :: DFM a b -> a -> Graph m l -> DFM a b
       anal_f finish in' g =
           do { fwd_pure_anal name emptyBlockEnv transfers in' g; finish }

       solve :: DFM a b -> a -> Graph m l -> Fuel -> DFM a (b, Fuel)
       solve finish in_fact (Graph entry blockenv) fuel =
         let blocks = G.postorder_dfs_from blockenv entry
             set_or_save = mk_set_or_save (isJust . lookupBlockEnv blockenv)
             set_successor_facts (Block id tail) fuel =
               do { idfact <- getFact id
                  ; (last_outs, fuel) <-
                      case check_maybe fuel $ fr_first rewrites idfact id of
                        Nothing -> solve_tail idfact tail fuel
                        Just g ->
                          do g <- return_graph g
                             (a, fuel) <- subAnalysis' $
                               case rewrite of
                                 RewriteDeep -> solve getExitFact idfact g (oneLessFuel fuel)
                                 RewriteShallow ->
                                     do { a <- anal_f getExitFact idfact g
                                        ; return (a, oneLessFuel fuel) }
                             solve_tail a tail fuel
                  ; set_or_save last_outs
                  ; return fuel }

         in do { (last_outs, fuel) <- solve_tail in_fact entry fuel
               ; set_or_save last_outs                                    
               ; fuel <- run "forward" name set_successor_facts blocks fuel
               ; b <- finish
               ; return (b, fuel)
               }

       solve_tail in' (G.ZTail m t) fuel =
         case check_maybe fuel $ fr_middle rewrites in' m of
           Nothing -> solve_tail (ft_middle_out transfers in' m) t fuel
           Just g ->
             do { g <- return_graph g
                ; (a, fuel) <- subAnalysis' $
                     case rewrite of
                       RewriteDeep -> solve getExitFact in' g (oneLessFuel fuel)
                       RewriteShallow -> do { a <- anal_f getExitFact in' g
                                            ; return (a, oneLessFuel fuel) }
                ; solve_tail a t fuel
                }
       solve_tail in' (G.ZLast l) fuel = 
         case check_maybe fuel $ either_last rewrites in' l of
           Nothing ->
               case l of LastOther l -> return (ft_last_outs transfers in' l, fuel)
                         LastExit -> do { setExitFact (ft_exit_out transfers in')
                                        ; return (LastOutFacts [], fuel) }
           Just g ->
             do { g <- return_graph g
                ; (last_outs :: LastOutFacts a, fuel) <- subAnalysis' $
                    case rewrite of
                      RewriteDeep -> solve lastOutFacts in' g (oneLessFuel fuel)
                      RewriteShallow -> do { los <- anal_f lastOutFacts in' g
                                           ; return (los, fuel) }
                ; return (last_outs, fuel)
                } 

       fixed_point in_fact g fuel =
         do { setAllFacts start_facts
            ; (a, fuel) <- solve getExitFact in_fact g fuel
            ; facts <- getAllFacts
            ; last_outs <- lastOutFacts
            ; let cfp = FP facts a NoChange (panic "no decoration?!") ()
            ; let fp = FFP cfp last_outs
            ; return (fp, fuel)
            }

       either_last rewrites in' (LastExit) = fr_exit rewrites in'
       either_last rewrites in' (LastOther l) = fr_last rewrites in' l

   in fixed_point




mk_set_or_save :: (DataflowAnalysis df, Monad (df a), Outputable a) =>
                  (BlockId -> Bool) -> LastOutFacts a -> df a ()
mk_set_or_save is_local (LastOutFacts l) = mapM_ set_or_save_one l
    where set_or_save_one (id, a) =
              if is_local id then setFact id a else addLastOutFact (id, a)




{-# INLINE forward_rew #-}
forward_rew
        :: forall m l g a . 
           (DebugNodes m l, LastNode l, Outputable a)
        => (forall a . Fuel -> Maybe a -> Maybe a)
        -> (g m l -> DFM a (Graph m l))  -- option on what to rewrite
        -> RewritingDepth
        -> BlockEnv a
        -> PassName
        -> ForwardTransfers m l a
        -> ForwardRewrites m l a g
        -> a
        -> Graph m l
        -> Fuel
        -> DFM a (ForwardFixedPoint m l a (Graph m l), Fuel)
forward_rew check_maybe return_graph = forw
  where
    solve = forward_sol check_maybe return_graph
    forw :: RewritingDepth
         -> BlockEnv a
         -> PassName
         -> ForwardTransfers m l a
         -> ForwardRewrites m l a g
         -> a
         -> Graph m l
         -> Fuel
         -> DFM a (ForwardFixedPoint m l a (Graph m l), Fuel)
    forw depth xstart_facts name transfers rewrites in_factx gx fuelx =
      let rewrite :: BlockEnv a -> DFM a b
                  -> a -> Graph m l -> Fuel
                  -> DFM a (b, Graph m l, Fuel)
          rewrite start finish in_fact g fuel =
            let Graph entry blockenv = g
                blocks = G.postorder_dfs_from blockenv entry
            in do { solve depth name start transfers rewrites in_fact g fuel
                  ; eid <- freshBlockId "temporary entry id"
                  ; (rewritten, fuel) <-
                      rew_tail (ZFirst eid) in_fact entry emptyBlockEnv fuel
                  ; (rewritten, fuel) <- rewrite_blocks blocks rewritten fuel
                  ; a <- finish
                  ; return (a, lgraphToGraph (LGraph eid rewritten), fuel)
                  }
          don't_rewrite finish in_fact g fuel =
              do  { solve depth name emptyBlockEnv transfers rewrites in_fact g fuel
                  ; a <- finish
                  ; return (a, g, fuel)
                  }
          inner_rew = case depth of RewriteShallow -> don't_rewrite
                                    RewriteDeep -> rewrite emptyBlockEnv
          fixed_pt_and_fuel =
              do { (a, g, fuel) <- rewrite xstart_facts getExitFact in_factx gx fuelx
                 ; facts <- getAllFacts
                 ; changed <- graphWasRewritten
                 ; last_outs <- lastOutFacts
                 ; let cfp = FP facts a changed (panic "no decoration?!") g
                 ; let fp = FFP cfp last_outs
                 ; return (fp, fuel)
                 }
          rewrite_blocks :: [Block m l] -> (BlockEnv (Block m l))
                         -> Fuel -> DFM a (BlockEnv (Block m l), Fuel)
          rewrite_blocks [] rewritten fuel = return (rewritten, fuel)
          rewrite_blocks (G.Block id t : bs) rewritten fuel =
            do let h = ZFirst id
               a <- getFact id
               case check_maybe fuel $ fr_first rewrites a id of
                 Nothing -> do { (rewritten, fuel) <- rew_tail h a t rewritten fuel
                               ; rewrite_blocks bs rewritten fuel }
                 Just g  -> do { markGraphRewritten
                               ; g <- return_graph g
                               ; (outfact, g, fuel) <- inner_rew getExitFact a g fuel
                               ; let (blocks, h) = splice_head' (ZFirst id) g
                               ; (rewritten, fuel) <-
                                 rew_tail h outfact t (blocks `plusUFM` rewritten) fuel
                               ; rewrite_blocks bs rewritten fuel }

          rew_tail head in' (G.ZTail m t) rewritten fuel =
            my_trace "Rewriting middle node" (ppr m) $
            case check_maybe fuel $ fr_middle rewrites in' m of
              Nothing -> rew_tail (G.ZHead head m) (ft_middle_out transfers in' m) t
                         rewritten fuel
              Just g -> do { markGraphRewritten
                           ; g <- return_graph g
                           ; (a, g, fuel) <- inner_rew getExitFact in' g fuel
                           ; let (blocks, h) = G.splice_head' head g
                           ; rew_tail h a t (blocks `plusUFM` rewritten) fuel
                           }
          rew_tail h in' (G.ZLast l) rewritten fuel = 
            my_trace "Rewriting last node" (ppr l) $
            case check_maybe fuel $ either_last rewrites in' l of
              Nothing -> -- can throw away facts because this is the rewriting phase
                         return (insertBlock (zipht h (G.ZLast l)) rewritten, fuel)
              Just g -> do { markGraphRewritten
                           ; g <- return_graph g
                           ; ((), g, fuel) <- inner_rew (return ()) in' g fuel
                           ; let g' = G.splice_head_only' h g
                           ; return (G.lg_blocks g' `plusUFM` rewritten, fuel)
                           }
          either_last rewrites in' (LastExit) = fr_exit rewrites in'
          either_last rewrites in' (LastOther l) = fr_last rewrites in' l
      in  fixed_pt_and_fuel

--lastOutFacts :: (DataflowAnalysis m, Monad (m f)) => m f (LastOutFacts f)
lastOutFacts :: DFM f (LastOutFacts f)
lastOutFacts = bareLastOutFacts >>= return . LastOutFacts

{- ================================================================ -}

solve_b         :: (DebugNodes m l, Outputable a)
                => BlockEnv a        -- initial facts (unbound == bottom)
                -> PassName
                -> DataflowLattice a -- lattice
                -> BackwardTransfers m l a   -- dataflow transfer functions
                -> a                 -- exit fact
                -> Graph m l         -- graph to be analyzed
                -> BackwardFixedPoint m l a ()  -- answers
solve_b env name lattice transfers exit_fact g =
   runWithInfiniteFuel $ runDFM panic_us lattice $
                         bwd_pure_anal name env transfers g exit_fact
 where panic_us = panic "pure analysis pulled on a UniqSupply"
    

rewrite_b_graph  :: (DebugNodes m l, Outputable a)
                 => RewritingDepth
                 -> BlockEnv a
                 -> PassName
                 -> DataflowLattice a
                 -> BackwardTransfers m l a
                 -> BackwardRewrites m l a Graph
                 -> a                 -- fact flowing in at exit
                 -> Graph m l
                 -> UniqSupply
                 -> FuelMonad (BackwardFixedPoint m l a (Graph m l))
rewrite_b_graph depth start_facts name lattice transfers rewrites exit_fact g u =
    runDFM u lattice $
    do fuel <- fuelRemaining
       (fp, fuel') <- backward_rew maybeRewriteWithFuel return depth start_facts name
                      transfers rewrites g exit_fact fuel
       fuelDecrement name fuel fuel'
       return fp

rewrite_b_agraph :: (DebugNodes m l, Outputable a)
                 => RewritingDepth
                 -> BlockEnv a
                 -> PassName
                 -> DataflowLattice a
                 -> BackwardTransfers m l a
                 -> BackwardRewrites m l a AGraph
                 -> a                 -- fact flowing in at exit
                 -> Graph m l
                 -> UniqSupply
                 -> FuelMonad (BackwardFixedPoint m l a (Graph m l))
rewrite_b_agraph depth start_facts name lattice transfers rewrites exit_fact g u =
    runDFM u lattice $
    do fuel <- fuelRemaining
       (fp, fuel') <- backward_rew maybeRewriteWithFuel areturn depth start_facts name
                      transfers rewrites g exit_fact fuel
       fuelDecrement name fuel fuel'
       return fp



{-# INLINE backward_sol #-}
backward_sol
        :: forall m l g a . 
           (DebugNodes m l, LastNode l, Outputable a)
        => (forall a . Fuel -> Maybe a -> Maybe a)
        -> (g m l -> DFM a (Graph m l))  -- option on what to rewrite
        -> RewritingDepth
        -> PassName
        -> BlockEnv a
        -> BackwardTransfers m l a
        -> BackwardRewrites m l a g
        -> Graph m l
        -> a
        -> Fuel
        -> DFM a (BackwardFixedPoint m l a (), Fuel)
backward_sol check_maybe return_graph = back
 where
  back :: RewritingDepth
       -> PassName
       -> BlockEnv a
       -> BackwardTransfers m l a
       -> BackwardRewrites m l a g
       -> Graph m l
       -> a
       -> Fuel
       -> DFM a (BackwardFixedPoint m l a (), Fuel)
  back rewrite name start_facts transfers rewrites =
   let anal_b :: Graph m l -> a -> DFM a a
       anal_b g out =
           do { fp <- bwd_pure_anal name emptyBlockEnv transfers g out
              ; return $ zdfFpOutputFact fp }

       subsolve :: g m l -> a -> Fuel -> DFM a (a, Fuel)
       subsolve =
         case rewrite of
           RewriteDeep    -> \g a fuel ->
               subAnalysis' $ do { g <- return_graph g; solve g a (oneLessFuel fuel) }
           RewriteShallow -> \g a fuel ->
               subAnalysis' $ do { g <- return_graph g; a <- anal_b g a
                                 ; return (a, oneLessFuel fuel) }

       solve :: Graph m l -> a -> Fuel -> DFM a (a, Fuel)
       solve (Graph entry blockenv) exit_fact fuel =
         let blocks = reverse $ G.postorder_dfs_from blockenv entry
             last_in  _env (LastExit)    = exit_fact
             last_in   env (LastOther l) = bt_last_in transfers env l
             last_rew _env (LastExit)    = br_exit rewrites 
             last_rew  env (LastOther l) = br_last rewrites env l
             set_block_fact block fuel =
                 let (h, l) = G.goto_end (G.unzip block) in
                 do { env <- factsEnv
                    ; (a, fuel) <-
                      case check_maybe fuel $ last_rew env l of
                        Nothing -> return (last_in env l, fuel)
                        Just g -> subsolve g exit_fact fuel
                    ; set_head_fact h a fuel
                    ; return fuel }

         in do { fuel <- run "backward" name set_block_fact blocks fuel
               ; eid <- freshBlockId "temporary entry id"
               ; fuel <- set_block_fact (Block eid entry) fuel
               ; a <- getFact eid
               ; forgetFact eid
               ; return (a, fuel)
               }

       set_head_fact (G.ZFirst id) a fuel =
         case check_maybe fuel $ br_first rewrites a id of
           Nothing -> do { setFact id a; return fuel }
           Just g  -> do { (a, fuel) <- subsolve g a fuel
                         ; setFact id a
                         ; return fuel
                         }
       set_head_fact (G.ZHead h m) a fuel =
         case check_maybe fuel $ br_middle rewrites a m of
           Nothing -> set_head_fact h (bt_middle_in transfers a m) fuel
           Just g -> do { (a, fuel) <- subsolve g a fuel
                        ; set_head_fact h a fuel }

       fixed_point g exit_fact fuel =
         do { setAllFacts start_facts
            ; (a, fuel) <- solve g exit_fact fuel
            ; facts <- getAllFacts
            ; let cfp = FP facts a NoChange (panic "no decoration?!") ()
            ; return (cfp, fuel)
            }
   in fixed_point

bwd_pure_anal :: (DebugNodes m l, Outputable a)
             => PassName
             -> BlockEnv a
             -> BackwardTransfers m l a
             -> Graph m l
             -> a
             -> DFM a (BackwardFixedPoint m l a ())

bwd_pure_anal name env transfers g exit_fact =
    do (fp, _) <- anal_b name env transfers panic_rewrites g exit_fact panic_fuel
       return fp
  where -- another case of "I love lazy evaluation"
    anal_b = backward_sol (\_ _ -> Nothing) panic_return panic_depth
    panic_rewrites = panic "pure analysis asked for a rewrite function"
    panic_fuel     = panic "pure analysis asked for fuel"
    panic_return   = panic "pure analysis tried to return a rewritten graph"
    panic_depth    = panic "pure analysis asked for a rewrite depth"


{- ================================================================ -}

{-# INLINE backward_rew #-}
backward_rew
        :: forall m l g a . 
           (DebugNodes m l, LastNode l, Outputable a)
        => (forall a . Fuel -> Maybe a -> Maybe a)
        -> (g m l -> DFM a (Graph m l))  -- option on what to rewrite
        -> RewritingDepth
        -> BlockEnv a
        -> PassName
        -> BackwardTransfers m l a
        -> BackwardRewrites m l a g
        -> Graph m l
        -> a
        -> Fuel
        -> DFM a (BackwardFixedPoint m l a (Graph m l), Fuel)
backward_rew check_maybe return_graph = back
  where
    solve = backward_sol check_maybe return_graph
    back :: RewritingDepth
         -> BlockEnv a
         -> PassName
         -> BackwardTransfers m l a
         -> BackwardRewrites m l a g
         -> Graph m l
         -> a
         -> Fuel
         -> DFM a (BackwardFixedPoint m l a (Graph m l), Fuel)
    back depth xstart_facts name transfers rewrites gx exit_fact fuelx =
      let rewrite :: BlockEnv a
                  -> Graph m l -> a -> Fuel
                  -> DFM a (a, Graph m l, Fuel)
          rewrite start g exit_fact fuel =
           let Graph entry blockenv = g
               blocks = reverse $ G.postorder_dfs_from blockenv entry
           in do { solve depth name start transfers rewrites g exit_fact fuel
                 ; eid <- freshBlockId "temporary entry id"
                 ; (rewritten, fuel) <- rewrite_blocks blocks emptyBlockEnv fuel
                 ; (rewritten, fuel) <- rewrite_blocks [Block eid entry] rewritten fuel
                 ; a <- getFact eid
                 ; return (a, lgraphToGraph (LGraph eid rewritten), fuel)
                 }
          don't_rewrite g exit_fact fuel =
            do { (fp, _) <-
                     solve depth name emptyBlockEnv transfers rewrites g exit_fact fuel
               ; return (zdfFpOutputFact fp, g, fuel) }
          inner_rew = case depth of RewriteShallow -> don't_rewrite
                                    RewriteDeep    -> rewrite emptyBlockEnv
          inner_rew :: Graph m l -> a -> Fuel -> DFM a (a, Graph m l, Fuel)
          fixed_pt_and_fuel =
              do { (a, g, fuel) <- rewrite xstart_facts gx exit_fact fuelx
                 ; facts <- getAllFacts
                 ; changed <- graphWasRewritten
                 ; let fp = FP facts a changed (panic "no decoration?!") g
                 ; return (fp, fuel)
                 }
          rewrite_blocks :: [Block m l] -> (BlockEnv (Block m l))
                         -> Fuel -> DFM a (BlockEnv (Block m l), Fuel)
          rewrite_blocks bs rewritten fuel =
              do { env <- factsEnv
                 ; let rew [] r f = return (r, f)
                       rew (b : bs) r f =
                           do { (r, f) <- rewrite_block env b r f; rew bs r f }
                 ; rew bs rewritten fuel }
          rewrite_block env b rewritten fuel =
            let (h, l) = G.goto_end (G.unzip b) in
            case maybeRewriteWithFuel fuel $ either_last env l of
              Nothing -> propagate fuel h (last_in env l) (ZLast l) rewritten
              Just g ->
                do { markGraphRewritten
                   ; g <- return_graph g
                   ; (a, g, fuel) <- inner_rew g exit_fact fuel
                   ; let G.Graph t new_blocks = g
                   ; let rewritten' = new_blocks `plusUFM` rewritten
                   ; propagate fuel h a t rewritten' -- continue at entry of g
                   } 
          either_last _env (LastExit)    = br_exit rewrites 
          either_last  env (LastOther l) = br_last rewrites env l
          last_in _env (LastExit)    = exit_fact
          last_in  env (LastOther l) = bt_last_in transfers env l
          propagate fuel (ZHead h m) a tail rewritten =
            case maybeRewriteWithFuel fuel $ br_middle rewrites a m of
              Nothing ->
                propagate fuel h (bt_middle_in transfers a m) (ZTail m tail) rewritten
              Just g  ->
                do { markGraphRewritten
                   ; g <- return_graph g
                   ; my_trace "Rewrote middle node"
                                             (f4sep [ppr m, text "to", pprGraph g]) $
                     return ()
                   ; (a, g, fuel) <- inner_rew g a fuel
                   ; let Graph t newblocks = G.splice_tail g tail
                   ; propagate fuel h a t (newblocks `plusUFM` rewritten) }
          propagate fuel (ZFirst id) a tail rewritten =
            case maybeRewriteWithFuel fuel $ br_first rewrites a id of
              Nothing -> do { checkFactMatch id a
                            ; return (insertBlock (Block id tail) rewritten, fuel) }
              Just g ->
                do { markGraphRewritten
                   ; g <- return_graph g
                   ; my_trace "Rewrote first node"
                     (f4sep [ppr id <> colon, text "to", pprGraph g]) $ return ()
                   ; (a, g, fuel) <- inner_rew g a fuel
                   ; checkFactMatch id a
                   ; let Graph t newblocks = G.splice_tail g tail
                   ; let r = insertBlock (Block id t) (newblocks `plusUFM` rewritten)
                   ; return (r, fuel) }
      in  fixed_pt_and_fuel

{- ================================================================ -}

instance FixedPoint CommonFixedPoint where
    zdfFpFacts        = fp_facts
    zdfFpOutputFact   = fp_out
    zdfGraphChanged   = fp_changed
    zdfDecoratedGraph = fp_dec_graph
    zdfFpContents     = fp_contents
    zdfFpMap f (FP fs out ch dg a) = FP fs out ch dg (f a)

instance FixedPoint ForwardFixedPoint where
    zdfFpFacts        = fp_facts     . ffp_common
    zdfFpOutputFact   = fp_out       . ffp_common
    zdfGraphChanged   = fp_changed   . ffp_common
    zdfDecoratedGraph = fp_dec_graph . ffp_common
    zdfFpContents     = fp_contents  . ffp_common
    zdfFpMap f (FFP fp los) = FFP (zdfFpMap f fp) los


dump_things :: Bool
dump_things = True

my_trace :: String -> SDoc -> a -> a
my_trace = if dump_things then pprTrace else \_ _ a -> a


-- | Here's a function to run an action on blocks until we reach a fixed point.
run :: (Outputable a, DebugNodes m l) =>
       String -> String -> (Block m l -> b -> DFM a b) -> [Block m l] -> b -> DFM a b
run dir name do_block blocks b =
   do { show_blocks $ iterate (1::Int) }
   where
     -- N.B. Each iteration starts with the same transaction limit;
     -- only the rewrites in the final iteration actually count
     trace_block b block =
         my_trace "about to do" (text name <+> text "on" <+> ppr (blockId block)) $
         do_block block b
     iterate n = 
         do { markFactsUnchanged
            ; b <- foldM trace_block b blocks
            ; changed <- factsStatus
            ; facts <- getAllFacts
            ; let depth = 0 -- was nesting depth
            ; ppIter depth n $
              case changed of
                NoChange -> unchanged depth $ return b
                SomeChange ->
                    pprFacts depth n facts $ 
                    if n < 1000 then iterate (n+1)
                    else panic $ msg n
            }
     msg n = concat [name, " didn't converge in ", show n, " " , dir,
                     " iterations"]
     my_nest depth sdoc = my_trace "" $ nest (3*depth) sdoc
     ppIter depth n = my_nest depth (empty $$ text "*************** iteration" <+> pp_i n)
     pp_i n = int n <+> text "of" <+> text name <+> text "on" <+> graphId
     unchanged depth = my_nest depth (text "facts are unchanged")

     pprFacts depth n env =
         my_nest depth (text "facts for iteration" <+> pp_i n <+> text "are:" $$
                        (nest 2 $ vcat $ map pprFact $ ufmToList env))
     pprFact (id, a) = hang (ppr id <> colon) 4 (ppr a)
     graphId = case blocks of { Block id _ : _ -> ppr id ; [] -> text "<empty>" }
     show_blocks = my_trace "Blocks:" (vcat (map pprBlock blocks))
     pprBlock (Block id t) = nest 2 (pprFact (id, t))


f4sep :: [SDoc] -> SDoc
f4sep [] = fsep []
f4sep (d:ds) = fsep (d : map (nest 4) ds)


subAnalysis' :: (Monad (m f), DataflowAnalysis m, Outputable f) =>
                m f a -> m f a
subAnalysis' m =
    do { a <- subAnalysis $
               do { a <- m; facts <- getAllFacts
                  ; my_trace "after sub-analysis facts are" (pprFacts facts) $
                    return a }
       ; facts <- getAllFacts
       ; my_trace "in parent analysis facts are" (pprFacts facts) $
         return a }
  where pprFacts env = nest 2 $ vcat $ map pprFact $ ufmToList env
        pprFact (id, a) = hang (ppr id <> colon) 4 (ppr a)