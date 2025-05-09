-- MODULE:
--   Risc2cpp.Simplifier
--
-- PURPOSE:
--   The Simplifier's job is to optimize the Intermediate representation
--   by doing a few Intermediate-to-Intermediate transformation passes.
--
--   The hope is that the transformed Intermediate code will produce 
--   a better C++ program than the original.
--
--   Whilst one might think that the Simplifier is pointless because
--   the C++ compiler should be doing all the optimization, it turns
--   out that using the Simplifier does actually produce slight
--   improvements in the final executable's runtime and code size, so
--   it is worth doing.
--
-- AUTHOR:
--   Stephen Thompson <stephen@solarflare.org.uk>
--
-- CREATED:
--   27-Dec-2010
--
-- COPYRIGHT:
--   Copyright (C) Stephen Thompson, 2010 - 2011, 2025.
--
--   This file is part of Risc2cpp. Risc2cpp is distributed under the terms
--   of the Boost Software License, Version 1.0, the text of which
--   appears below.
--
--   Boost Software License - Version 1.0 - August 17th, 2003
--   
--   Permission is hereby granted, free of charge, to any person or organization
--   obtaining a copy of the software and accompanying documentation covered by
--   this license (the "Software") to use, reproduce, display, distribute,
--   execute, and transmit the Software, and to prepare derivative works of the
--   Software, and to permit third-parties to whom the Software is furnished to
--   do so, all subject to the following:
--
--   The copyright notices in the Software and this entire statement, including
--   the above license grant, this restriction and the following disclaimer,
--   must be included in all copies of the Software, in whole or in part, and
--   all derivative works of the Software, unless such copies or derivative
--   works are solely in the form of machine-executable object code generated by
--   a source language processor.
--
--   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--   FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
--   SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
--   FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
--   ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
--   DEALINGS IN THE SOFTWARE.


module Risc2cpp.Simplifier
    ( simplify     -- Int -> [Addr] -> Map Addr [Statement] -> Map Addr [Statement]
    )

where

import Risc2cpp.Intermediate

import Data.Bits ((.&.), (.|.), complement)  -- for optimized Region handling
import Data.Int
import Data.List
import qualified Data.Map as Map
import Data.Map (Map)
import Data.Maybe
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Word  -- for optimized Region handling

-- Recursively apply an optimization pass until it converges
recursively :: (Show a, Eq a) => (a -> a) -> a -> a
recursively func original = 
    let optimized = func original
    in if optimized == original then optimized  -- no change; stop
       else recursively func optimized     -- made progress; have another go.



-- Optimization pass: Constant Folding (for Exprs).
-- Needs to be applied recursively.

-- Here we evaluate constant expressions at compile time, e.g. 1 + 2 is transformed into 3.
-- We also apply identities such as 0 + x = x and 0 * x = 0.

-- We also make some "normalization" transformations, e.g. a + c -> c + a for commutative operators,
-- a + (b + c) -> (a + b) + c for associative. This is useful because it may expose more constant folding
-- opportunities.


commute :: Expr -> Expr
commute x@(LitExpr _) = x
commute x@(VarExpr _) = x
commute x@(UnExpr _ _) = x
commute (BinExpr op a (LitExpr c)) | isCommutative op
    = BinExpr op (LitExpr c) (commute a)
commute (BinExpr op a b) = BinExpr op (commute a) (commute b)
commute (LoadMemExpr op e) = LoadMemExpr op (commute e)
commute x@(LoadRegExpr _) = x

associate :: Expr -> Expr
associate x@(LitExpr _) = x
associate x@(VarExpr _) = x
associate x@(UnExpr _ _) = x
associate (BinExpr op1 a (BinExpr op2 b c)) | op1 == op2 && isAssociative op1 
    = BinExpr op1 (BinExpr op1 a b) c
associate (BinExpr op a b) = BinExpr op (associate a) (associate b)
associate (LoadMemExpr op e) = LoadMemExpr op (associate e)
associate x@(LoadRegExpr _) = x

constFold :: Expr -> Expr
constFold x@(LitExpr _) = x
constFold x@(VarExpr _) = x

constFold (UnExpr op (LitExpr c)) = LitExpr (applyUnOp op c)    -- apply unary operators to constants
constFold (UnExpr Negate (UnExpr Negate x)) = constFold x       -- (-(-x)) = x
constFold (UnExpr Not (UnExpr Not x)) = constFold x     -- (~(~x)) = x
constFold (UnExpr op a) = UnExpr op (constFold a)               -- recursively const fold under a unary operator

constFold (BinExpr op (LitExpr c1) (LitExpr c2)) = LitExpr (applyBinOp op c1 c2)  -- c1 # c2 -> c3

constFold (BinExpr Add (LitExpr 0) x) = constFold x         -- 0 + x -> x
constFold (BinExpr Add x (UnExpr Negate y)) = BinExpr Sub (constFold x) (constFold y)  -- x + (-y) -> x - y
constFold (BinExpr Add (UnExpr Negate x) y) = BinExpr Sub (constFold y) (constFold x)  -- (-x) + y -> y - x

constFold (BinExpr Sub x (LitExpr 0)) = constFold x         -- x - 0 -> x
constFold (BinExpr Sub (LitExpr 0) x) = UnExpr Negate (constFold x)   -- 0 - x -> (-x)
constFold (BinExpr Sub x y) | x == y = LitExpr 0            -- x - x -> 0
constFold (BinExpr Sub x (UnExpr Negate y)) = BinExpr Add (constFold x) (constFold y)   -- x - (-y) -> x + y

constFold (BinExpr Mult (LitExpr 1) x) = constFold x        -- 1 * x -> x
constFold (BinExpr Mult (LitExpr 0) x) = LitExpr 0          -- 0 * x -> 0
constFold (BinExpr Mult (LitExpr (-1)) x) = UnExpr Negate (constFold x)     -- (-1) * x -> (-x)
constFold (BinExpr MultHi (LitExpr 0) x) = LitExpr 0        -- 0 * x -> 0
constFold (BinExpr MultHiU (LitExpr 1) x) = LitExpr 0       -- 1 * x -> x, hi word is therefore zero, when unsigned
constFold (BinExpr MultHiU (LitExpr 0) x) = LitExpr 0       -- 0 * x -> 0

constFold (BinExpr Quot x (LitExpr 1)) = constFold x        -- x / 1 -> x
constFold (BinExpr QuotU x (LitExpr 1)) = constFold x       -- x / 1 -> x

constFold (BinExpr Rem x (LitExpr 1)) = LitExpr 0           -- x % 1 -> 0
constFold (BinExpr Rem x (LitExpr (-1))) = LitExpr 0        -- x % (-1) -> 0
constFold (BinExpr RemU x (LitExpr 1)) = LitExpr 0          -- x % 1 -> 0

constFold (BinExpr And (LitExpr (-1)) x) = constFold x      -- (-1) & x -> x
constFold (BinExpr And (LitExpr 0) x) = LitExpr 0           -- 0 & x -> 0

constFold (BinExpr Or (LitExpr (-1)) x) = LitExpr (-1)      -- (-1) | x -> (-1)
constFold (BinExpr Or (LitExpr 0) x) = constFold x          -- 0 | x -> x

constFold (BinExpr Xor (LitExpr (-1)) x) = UnExpr Not (constFold x)  -- (-1) ^ x -> (~x)
constFold (BinExpr Xor (LitExpr 0) x) = constFold x         -- 0 ^ x -> x

constFold (BinExpr LogicalShiftLeft x (LitExpr 0)) = constFold x    -- x << 0 -> x
constFold (BinExpr LogicalShiftRight x (LitExpr 0)) = constFold x   -- x >> 0 -> x
constFold (BinExpr ArithShiftRight x (LitExpr 0)) = constFold x     -- x >> 0 -> x

constFold (BinExpr SetIfLess x y) | x == y = LitExpr 0      -- x < x -> 0
constFold (BinExpr SetIfLessU x y) | x == y = LitExpr 0     -- x < x -> 0
constFold (BinExpr SetIfLessU _ (LitExpr 0)) = LitExpr 0    -- Nothing can be less than 0 (unsigned)

constFold (BinExpr op a b) = BinExpr op (constFold a) (constFold b)
constFold (LoadMemExpr op a) = LoadMemExpr op (constFold a)
constFold x@(LoadRegExpr _) = x


runConstFold :: Expr -> Expr
runConstFold = recursively (constFold . associate . commute)


-- Optimization Pass: Constant Folding for CondExprs.
-- Needs to be applied recursively.
constFoldC :: CondExpr -> CondExpr
constFoldC (BinCond op (LitExpr c1) (LitExpr c2)) = LitCond (applyCond op c1 c2)  -- Evaluate when both sides are constants
constFoldC (BinCond Equal e1 e2) | e1 == e2 = (LitCond True)   -- a == a is always true
constFoldC (BinCond NotEqual (BinExpr SetIfLessU e1 e2) (LitExpr 0)) = BinCond LessThanU e1 e2  -- Sometimes happens with SLTU, SLTIU
constFoldC (BinCond Equal (BinExpr SetIfLessU e1 e2) (LitExpr 0)) = BinCond GtrEqualU e1 e2  -- Ditto
constFoldC (BinCond NotEqual (BinExpr SetIfLess e1 e2) (LitExpr 0)) = BinCond LessThan e1 e2    -- Sometimes happens with SLT, SLTI
constFoldC (BinCond Equal (BinExpr SetIfLess e1 e2) (LitExpr 0)) = BinCond GtrEqual e1 e2    -- Ditto
constFoldC (BinCond LessThanU _ (LitExpr 0)) = LitCond False    -- Nothing can be less than 0 (unsigned)
constFoldC (BinCond GtrEqualU _ (LitExpr 0)) = LitCond True     -- Everything is >= 0 (unsigned)
constFoldC (BinCond op e1 e2) = BinCond op (runConstFold e1) (runConstFold e2)  -- Apply regular constant folding to sub-expressions
constFoldC c@(LitCond _) = c

runConstFoldC = recursively constFoldC


-- Optimization pass: Substitution
--
-- The idea of this is to get rid of Lets wherever possible, e.g.
--    Let x2 = x0 + x1
--    Let x3 = x2 + 5
-- should be transformed into
--    Let x3 = x0 + x1 + 5.
--
-- The thinking behind this is that the C# compiler tends to produce more compact
-- bytecode for
--    int x3 = x0 + x1 + 5;
-- as opposed to 
--    int x2 = x0 + x1;
--    int x3 = x2 + 5;
-- (The latter case tends to create redundant load/store instructions in the IL.
-- No doubt the JIT will remove these, but it still inflates the size of the 
-- executable...)

substitute :: [Statement] -> [Statement]
substitute [] = []
substitute ((Let var rhs):stmts)
    | canSubstitute var rhs stmts =
        -- We can get rid of this Let and substitute it directly into the following stmts.
        let newStmts = map (mapOverExprs (substVarInExpr (var,rhs))) stmts
        in substitute newStmts
substitute (stmt:stmts) =
    -- We cannot get rid of this statement, we just have to include it unmodified in the output,
    -- then continue trying to substitute the following statements.
    stmt : substitute stmts

--- Function to substitute for variables in an expression.
substVarInExpr :: (VarName,Expr) -> Expr -> Expr
substVarInExpr _ e@(LitExpr _) = e
substVarInExpr (varName,target) e@(VarExpr n) | n == varName = target
                                              | otherwise    = e
substVarInExpr subs (UnExpr op e) = UnExpr op (substVarInExpr subs e)
substVarInExpr subs (BinExpr op e1 e2) = BinExpr op (substVarInExpr subs e1) (substVarInExpr subs e2)
substVarInExpr subs (LoadMemExpr op e) = LoadMemExpr op (substVarInExpr subs e)
substVarInExpr _ e@(LoadRegExpr _) = e

substVarInCondExpr :: (VarName,Expr) -> CondExpr -> CondExpr
substVarInCondExpr sub (BinCond op e1 e2) = BinCond op (substVarInExpr sub e1) (substVarInExpr sub e2)
substVarInCondExpr _ x@(LitCond _) = x


-- Determine whether we want to substitute for a particular variable (True),
-- or just leave it as a Let (False).
canSubstitute :: VarName -> Expr -> [Statement] -> Bool
canSubstitute varName rhs stmts =
    let hazard = dataHazard varName rhs stmts
        varRefs = concatMap (findRefsToVarS varName) stmts
        zeroOrOneVarRefs = case varRefs of 
                              (x:y:_) -> False
                              _ -> True
        isSimple = case rhs of
                       LitExpr _ -> True
                       VarExpr _ -> True
                       LoadRegExpr _ -> True
                       _ -> False
    in (not hazard) && (isSimple || zeroOrOneVarRefs)


-- Determines if there is a data hazard, i.e. a sequence of statements
-- containing something like the following:
--   * Let x = ReadReg(foo)
--   * WriteReg foo
--   * Let y = x
-- Substituting x would be invalid because you are then reading register foo
-- after it has been written.
dataHazard :: VarName -> Expr -> [Statement] -> Bool
dataHazard varName expr stmts =
    let readRegion = getReadRegionE expr
    in case findWriteToRegion readRegion stmts of
         Nothing -> False   -- That region is never written, so there can't be a data hazard
         Just newStmts ->
             -- If there is any reference to varName in newStmts, we have a hazard.
             not $ null $ concatMap (findRefsToVarS varName) newStmts


-- Find references to a given variable.
findRefsToVarS :: VarName -> Statement -> [()]
findRefsToVarS varName (Let _ e)          = findRefsToVarE varName e
findRefsToVarS varName (StoreMem _ e1 e2) = findRefsToVarE varName e1 ++ findRefsToVarE varName e2
findRefsToVarS varName (StoreReg _ e)     = findRefsToVarE varName e
findRefsToVarS varName (Jump c _ _)       = findRefsToVarC varName c
findRefsToVarS varName (IndirectJump e)   = findRefsToVarE varName e
findRefsToVarS _ (Syscall _) = []
findRefsToVarS _ Break = []

findRefsToVarE :: RegName -> Expr -> [()]
findRefsToVarE v (LitExpr _) = []
findRefsToVarE v (VarExpr v2) | v == v2 = [()]
                              | otherwise = []
findRefsToVarE v (UnExpr _ e) = findRefsToVarE v e
findRefsToVarE v (BinExpr _ e1 e2) = findRefsToVarE v e1 ++ findRefsToVarE v e2
findRefsToVarE v (LoadMemExpr _ e) = findRefsToVarE v e
findRefsToVarE v (LoadRegExpr _) = []

findRefsToVarC :: RegName -> CondExpr -> [()]
findRefsToVarC v (BinCond _ e1 e2) = findRefsToVarE v e1 ++ findRefsToVarE v e2
findRefsToVarC v (LitCond _) = []



-- Optimization pass: Constant propagation
-- If there is a StoreReg r (LitExpr n), then replace any later
-- (LoadReg r), where r wasn't overwritten yet, with (LitExpr n).
-- This can sometimes expose further opportunities for constant folding.
constantPropagation :: [Statement] -> [Statement]
constantPropagation = snd . mapAccumL constPropFunc Map.empty

constPropFunc :: Map RegName Int32 -> Statement -> (Map RegName Int32, Statement)
constPropFunc env stmt@(StoreReg r (LitExpr i)) = 
    let newEnv = Map.insert r i env
    in (newEnv, stmt)
constPropFunc env (StoreReg r e) =
    let newEnv = Map.delete r env
    in (newEnv, StoreReg r (substRegs env e))
constPropFunc env stmt = (env, mapOverExprs (substRegs env) stmt)

substRegs :: Map RegName Int32 -> Expr -> Expr
substRegs env e@(LitExpr _) = e
substRegs env e@(VarExpr _) = e
substRegs env (UnExpr op e) = UnExpr op (substRegs env e)
substRegs env (BinExpr op e1 e2) = BinExpr op (substRegs env e1) (substRegs env e2)
substRegs env (LoadMemExpr op e) = LoadMemExpr op (substRegs env e)
substRegs env (LoadRegExpr r) =
    case Map.lookup r env of
      Just val -> LitExpr val
      Nothing -> LoadRegExpr r  -- not a known constant


-- A "region" is a set of storage locations that are read from or written to by a statement or expression.
-- "Storage locations" here include registers and memory.
-- (We don't attempt to divide up memory into individual addresses, but we do track the registers individually.)

-- Current implementation uses bitwise operations for speed.

type Region = Word64
type RegionNames = Map RegName Region

allRegion :: Region
allRegion = maxBound :: Region

rgnUnion :: Region -> Region -> Region
rgnUnion = (.|.)

rgnDifference :: Region -> Region -> Region
rgnDifference a b = a .&. (complement b)

rgnEmpty = 0

-- Bit 0 of the region mask refers to memory
rgnMemory = 1

-- Bits 1 and above refer to registers.
-- (Note: RISC-V dependent code.)
regNameToRegion :: RegName -> Region
regNameToRegion "ra" = 0x2
regNameToRegion "sp" = 0x4
regNameToRegion "gp" = 0x8
regNameToRegion "tp" = 0x10
regNameToRegion "t0" = 0x20
regNameToRegion "t1" = 0x40
regNameToRegion "t2" = 0x80
regNameToRegion "s0" = 0x100
regNameToRegion "s1" = 0x200
regNameToRegion "a0" = 0x400
regNameToRegion "a1" = 0x800
regNameToRegion "a2" = 0x1000
regNameToRegion "a3" = 0x2000
regNameToRegion "a4" = 0x4000
regNameToRegion "a5" = 0x8000
regNameToRegion "a6" = 0x10000
regNameToRegion "a7" = 0x20000
regNameToRegion "s2" = 0x40000
regNameToRegion "s3" = 0x80000
regNameToRegion "s4" = 0x100000
regNameToRegion "s5" = 0x200000
regNameToRegion "s6" = 0x400000
regNameToRegion "s7" = 0x800000
regNameToRegion "s8" = 0x1000000
regNameToRegion "s9" = 0x2000000
regNameToRegion "s10" = 0x4000000
regNameToRegion "s11" = 0x8000000
regNameToRegion "t3" = 0x10000000
regNameToRegion "t4" = 0x20000000
regNameToRegion "t5" = 0x40000000
regNameToRegion "t6" = 0x80000000


regionsOverlap :: Region -> Region -> Bool
regionsOverlap r1 r2 = (r1 .&. r2) /= 0

getReadRegionE :: Expr -> Region
getReadRegionE (LitExpr _) = rgnEmpty
getReadRegionE (VarExpr _) = rgnEmpty
getReadRegionE (UnExpr _ e) = getReadRegionE e
getReadRegionE (BinExpr _ e1 e2) = rgnUnion (getReadRegionE e1) (getReadRegionE e2)
getReadRegionE (LoadMemExpr _ e) = rgnUnion rgnMemory (getReadRegionE e)
getReadRegionE (LoadRegExpr r) = regNameToRegion r

getReadRegionC :: CondExpr -> Region
getReadRegionC (BinCond _ e1 e2) = rgnUnion (getReadRegionE e1) (getReadRegionE e2)
getReadRegionC (LitCond _) = rgnEmpty

getReadRegionS :: Statement -> Region
getReadRegionS (Let _ rhs) = getReadRegionE rhs
getReadRegionS (StoreMem _ addr val) = rgnUnion (getReadRegionE addr) (getReadRegionE val)
getReadRegionS (StoreReg _ val) = getReadRegionE val
getReadRegionS (Jump c _ _) = getReadRegionC c
getReadRegionS (IndirectJump e) = getReadRegionE e
getReadRegionS (Syscall _) = maxBound   -- assume a syscall could read anything
getReadRegionS Break = rgnEmpty   -- a break terminates execution (without reading anything)

getWriteRegionS :: Statement -> Region
getWriteRegionS (Let _ _) = rgnEmpty
getWriteRegionS (StoreMem _ _ _) = rgnMemory
getWriteRegionS (StoreReg r _) = regNameToRegion r
getWriteRegionS (Jump _ _ _) = rgnEmpty
getWriteRegionS (IndirectJump _) = rgnEmpty
getWriteRegionS (Syscall _) = maxBound  -- assume a syscall could write anything
getWriteRegionS Break = rgnEmpty  -- a break terminates execution (without writing anything)


-- findWriteToRegion
-- Returns:
--  (Nothing) if there is no statement that writes to the given region
--  (Just tail) if there IS a write to that region; (tail) contains all statements
--   AFTER the offending write statement.
findWriteToRegion :: Region -> [Statement] -> Maybe [Statement]
findWriteToRegion readRegion [] = Nothing
findWriteToRegion readRegion (stmt:rest) =
    let writeRegion = getWriteRegionS stmt
    in if regionsOverlap readRegion writeRegion then Just rest
       else findWriteToRegion readRegion rest



-- Liveness analysis.

data JumpTarget = Direct Addr | Indirect   deriving (Show)

-- Analyse a basic block to find the GEN and KILL sets
-- GEN = vars that are read before being written
-- KILL = vars that are written
-- Return value is (gen, kill).
findGenAndKill :: [Statement] -> (Region, Region)
findGenAndKill stmts =
    foldr f (rgnEmpty, rgnEmpty) stmts
        where f stmt (gen, kill)
                  = let rd = getReadRegionS stmt
                        wr = getWriteRegionS stmt
                    in (rgnUnion (rgnDifference gen wr) rd,
                        rgnUnion kill wr)

-- Find all possible successors from a Jump, IndirectJump, Syscall or Break statement
findSuccessors :: Statement -> [JumpTarget]
findSuccessors (Jump (LitCond True)  a _) = [Direct a]
findSuccessors (Jump (LitCond False) _ a) = [Direct a]
findSuccessors (Jump _ a b)               = [Direct a, Direct b]
findSuccessors (IndirectJump e)           = [Indirect]
findSuccessors (Syscall a)                = [Direct a, Indirect]  -- Assume PC could be changed by the syscall handler (hence Indirect target needed)
findSuccessors Break                      = []
findSuccessors _ = error "findSuccessors can only be called on Jump, IndirectJump, Syscall or Break statements"


-- Work function to do one iteration of the liveness analysis for a given basic block
-- Input: initial LiveOut set, GEN and KILL sets for this block, 
-- and the LiveIn sets for the possible successors
-- Output: new LiveIn and LiveOut sets
iterateLiveness :: Region -> Region -> Region -> [Region] -> (Region,Region)
iterateLiveness oldOut gen kill successors = 
    let newIn = rgnUnion (rgnDifference oldOut kill) gen
        newOut = foldl' rgnUnion rgnEmpty successors
    in (newIn, newOut)

-- Main function to do one iteration of the liveness analysis for a given basic block.
-- Returns a new map from Addr to the in/out sets.
doLivenessUpdate :: Map Addr [JumpTarget] -> Map Addr (Region,Region) -> Region
                 -> Addr -> Map Addr (Region,Region) -> Map Addr (Region,Region)
doLivenessUpdate successors genKillRegions cachedInSetOfIndirect blockToUpdate oldMap = 
    let outSet = snd (oldMap Map.! blockToUpdate)  :: Region
        (gen, kill) = (genKillRegions Map.! blockToUpdate)  :: (Region, Region)
        possSuccessors = (successors Map.! blockToUpdate)   :: [JumpTarget]
        inSetsOfSuccessors = map findInSet possSuccessors :: [Region]
                                    where findInSet (Direct addr) = fst (oldMap Map.! addr)
                                          findInSet (Indirect)    = cachedInSetOfIndirect
        iterationResult = iterateLiveness outSet gen kill inSetsOfSuccessors  :: (Region, Region)
    in iterationResult `seq` Map.insert blockToUpdate iterationResult oldMap


-- Run a liveness iteration over all blocks
livenessIterateAll :: [Addr] -> Map Addr [JumpTarget] -> Map Addr (Region,Region)
                   -> Map Addr (Region,Region) -> Map Addr (Region,Region)
livenessIterateAll indJumpTargets successors genKillRegions oldMap =
    let blocks = Map.keys successors
        cachedInSetOfIndirect = foldl' rgnUnion rgnEmpty (map (\blk -> fst (oldMap Map.! blk)) indJumpTargets)
    in foldr (doLivenessUpdate successors genKillRegions cachedInSetOfIndirect) oldMap blocks


-- Main routine to do liveness analysis
-- Input: register regions, indirect jump targets, all basic blocks
-- Output: a map from basic blocks to their In and Out regions.
livenessAnalysis :: [Addr] -> Map Addr [Statement] -> Map Addr (Region, Region)
livenessAnalysis indJumpTargets blocks =
    let successors :: Map Addr [JumpTarget]
        successors = Map.union (Map.map (findSuccessors . last) blocks) Map.empty
        genKillSets :: Map Addr (Region,Region)
        genKillSets = Map.union (Map.map findGenAndKill blocks) Map.empty
        initialInOutSets :: Map Addr (Region,Region)
        initialInOutSets = Map.union (Map.map (\b -> (rgnEmpty,rgnEmpty)) blocks) Map.empty
    in recursively (livenessIterateAll indJumpTargets successors genKillSets) initialInOutSets


-- Replace non-final StoreRegs with Lets (allowing them to be worked on by the substitution pass).
replaceNonFinalStores :: Int -> [Statement] -> [Statement]
replaceNonFinalStores vnum ((StoreReg r e):rest)
    | isJust (find (containsStoreTo r) rest) 
        = let varName = "nf_var_" ++ show vnum
          in (Let varName e) : replaceNonFinalStores (vnum+1) (regToVar r varName rest)
    where containsStoreTo r (StoreReg r2 _) | r == r2 = True
          containsStoreTo _ _ = False
replaceNonFinalStores vnum (s:rest) = s : replaceNonFinalStores vnum rest
replaceNonFinalStores vnum [] = []

-- replaces LoadRegExpr regName with VarExpr varName, BUT only up until
-- regName is reassigned.
regToVar :: RegName -> VarName -> [Statement] -> [Statement]
regToVar regName varName stmts =
    let (beforeReassign, afterReassign) = breakOnReassign regName stmts
    in map (mapOverExprs f) beforeReassign ++ afterReassign
        where f e@(LitExpr _) = e
              f e@(VarExpr _) = e
              f (UnExpr op e) = UnExpr op (f e)
              f (BinExpr op e1 e2) = BinExpr op (f e1) (f e2)
              f (LoadMemExpr op e) = LoadMemExpr op (f e)
              f (LoadRegExpr r2) | regName == r2 = VarExpr varName  -- change regName into varName
                                 | otherwise = LoadRegExpr r2       -- leave other reg names unchanged

breakOnReassign regName stmts
    = case (break (isStoreTo regName) stmts) of
        (before, (at:after)) -> (before ++ [at], after)
        (before, []) -> (before, [])

isStoreTo r1 (StoreReg r2 _) | r1 == r2 = True
isStoreTo _ _ = False


-- Replace dead StoreRegs with Lets
replaceDeadStores1 :: Region -> Int -> [Statement] -> [Statement]
replaceDeadStores1 liveOnExit vnum ((StoreReg r e):rest)
    | not (regionsOverlap (regNameToRegion r) liveOnExit)    -- store to a dead register
        = let varName = "dead_var_" ++ show vnum
          in (Let varName e) : replaceDeadStores1 liveOnExit (vnum+1) (regToVar r varName rest)
replaceDeadStores1 liveOnExit vnum (s:rest) = s : replaceDeadStores1 liveOnExit vnum rest
replaceDeadStores1 _ _ [] = []

replaceDeadStores :: Map Addr (Region,Region) -> Addr -> [Statement] -> [Statement]
replaceDeadStores livenessResults addr stmts =
    let liveOnExit = snd (livenessResults Map.! addr)
    in replaceDeadStores1 liveOnExit 0 stmts


-- Remove useless assignments of form x = x.
-- (These can sometimes be generated after substitution.)
removeUselessAssignments :: [Statement] -> [Statement]
removeUselessAssignments = filter f
    where f (StoreReg reg1 (LoadRegExpr reg2)) | reg1 == reg2 = False
          f _ = True


-- Main function to run all optimization passes.
simplify :: Int -> [Addr] -> Map Addr [Statement] -> Map Addr [Statement]
simplify optimizationLevel indJumpTargets basicBlocks =
    let withLets = Map.map (replaceNonFinalStores 0) basicBlocks                                 :: Map Addr [Statement]
        localSimplifiedBlocks = Map.map (recursively simplifyBB1) withLets                 :: Map Addr [Statement]
        livenessResults = livenessAnalysis indJumpTargets localSimplifiedBlocks  :: Map Addr (Region,Region)
        deadStoreResult = Map.mapWithKey (replaceDeadStores livenessResults) localSimplifiedBlocks  :: Map Addr [Statement]
        secondSimplifyRound = Map.map (recursively simplifyBB1) deadStoreResult            :: Map Addr [Statement]
    in case optimizationLevel of
         0 -> basicBlocks
         1 -> localSimplifiedBlocks
         2 -> secondSimplifyRound
         _ -> error $ "Unknown optimization level: " ++ show optimizationLevel

-- This does simplifications that can be done "locally" (i.e. one basic block at a time)
simplifyBB1 :: [Statement] -> [Statement]
simplifyBB1 stmts =
    let constFoldedStmts = map (mapOverExprs runConstFold) stmts
        constFolded2 = map (mapOverCondExprs runConstFoldC) constFoldedStmts
        newStmts' = substitute constFolded2
        newStmts = constantPropagation newStmts'
    in removeUselessAssignments newStmts
