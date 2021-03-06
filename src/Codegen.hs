{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}

module Codegen where

import Data.Word
import Data.List
import Data.Function
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (listToMaybe)

import Control.Monad.State
import Control.Monad.Trans.Maybe (MaybeT(..))
import Control.Applicative

import LLVM.General.AST
import LLVM.General.AST.Global
import qualified LLVM.General.AST as AST
import qualified LLVM.General.AST.Global as G

import qualified LLVM.General.AST.Constant as C
import qualified LLVM.General.AST.Attribute as A
import qualified LLVM.General.AST.CallingConvention as CC
import qualified LLVM.General.AST.FloatingPointPredicate as FP
import qualified LLVM.General.AST.IntegerPredicate as IP
import LLVM.General.AST.Type (ptr)

import Syntax (SymName)

-------------------------------------------------------------------------------
-- Module Level
-------------------------------------------------------------------------------

newtype LLVM a = LLVM { unLLVM :: State AST.Module a }
  deriving (Functor, Applicative, Monad, MonadState AST.Module)

runLLVM :: AST.Module -> LLVM a -> AST.Module
runLLVM = flip (execState . unLLVM)

emptyModule :: String -> AST.Module
emptyModule label = defaultModule { moduleName = label }

addDefn :: Definition -> LLVM ()
addDefn d = do
  defs <- gets moduleDefinitions
  modify $ \s -> s { moduleDefinitions = nub $ defs ++ [d] }

defineGlobalVar :: String -> LLVM ()
defineGlobalVar varName = addDefn $
  GlobalDefinition $ globalVariableDefaults {
    name = Name varName
  , G.type' = uint
  , initializer = Just $ C.Int uintSize 0
  }

defineFunc :: Type -> String -> [(Type, Name)] -> [BasicBlock] -> LLVM ()
defineFunc retty label argtys body = addDefn $
  GlobalDefinition $ functionDefaults {
    name        = Name label
  , parameters  = ([Parameter ty nm [] | (ty, nm) <- argtys], False)
  , returnType  = retty
  , basicBlocks = body
  }

delFunc :: String -> LLVM ()
delFunc fname = do
  mFuncDef <- gets $ getFuncDefinition fname . moduleDefinitions
  maybe (return ()) del mFuncDef
 where
  del funcDef =
    modify $ \mod ->
      mod { AST.moduleDefinitions = delete funcDef $ moduleDefinitions mod }

getFuncDefinition :: SymName -> [AST.Definition] -> Maybe AST.Definition
getFuncDefinition searchedName modDefs =
  listToMaybe . filter filt $ modDefs
 where
  filt
    (AST.GlobalDefinition
      (AST.Function { G.name = AST.Name funcName, .. }))
    | funcName == searchedName = True
  filt _ = False


defineType :: String -> Type -> LLVM ()
defineType name ty = addDefn . TypeDefinition (Name name) . Just $ ty

external ::  Type -> String -> [(Type, Name)] -> LLVM ()
external retty label argtys = addDefn $
  GlobalDefinition $ functionDefaults {
    name        = Name label
  , parameters  = ([Parameter ty nm [] | (ty, nm) <- argtys], False)
  , returnType  = retty
  , basicBlocks = []
  }

---------------------------------------------------------------------------------
-- Types
-------------------------------------------------------------------------------

uint :: Type
uint = IntegerType uintSize

uintSize :: Num a => a
uintSize = 64

double :: Type
double = FloatingPointType 64 IEEE

i8ptr :: Type
i8ptr = ptr $ IntegerType 8

uintSizeBytes :: Integral a => a
uintSizeBytes  = uintSize `div` 8

-------------------------------------------------------------------------------
-- Names
-------------------------------------------------------------------------------

type Names = Map.Map String Int

uniqueName :: String -> Names -> (String, Names)
uniqueName nm ns =
  case Map.lookup nm ns of
    Nothing -> (nm,  Map.insert nm 1 ns)
    Just ix -> (nm ++ show ix, Map.insert nm (ix+1) ns)

-------------------------------------------------------------------------------
-- Codegen State
-------------------------------------------------------------------------------

type SymbolTable = Map SymName Operand

data CodegenState
  = CodegenState {
    currentBlock :: Name                     -- Name of the active block to append to
  , blocks       :: Map.Map Name BlockState  -- Blocks for function
  , symtab       :: SymbolTable              -- Function scope symbol table
  , blockCount   :: Int                      -- Count of basic blocks
  , count        :: Word                     -- Count of unnamed instructions
  , names        :: Names                    -- Name Supply
  , extraFuncs   :: [LLVM ()]                -- LLVM computations of lambdas
  , funcName     :: SymName                  -- 'CodegenState's function name
  , globalVars   :: [SymName]
  } {-deriving Show-}

data BlockState
  = BlockState {
    idx   :: Int                            -- Block index
  , stack :: [Named Instruction]            -- Stack of instructions
  , term  :: Maybe (Named Terminator)       -- Block terminator
  } deriving Show

-------------------------------------------------------------------------------
-- Codegen Operations
-------------------------------------------------------------------------------

newtype Codegen a = Codegen { runCodegen :: State CodegenState a }
  deriving (Functor, Applicative, Monad, MonadState CodegenState )

sortBlocks :: [(Name, BlockState)] -> [(Name, BlockState)]
sortBlocks = sortBy (compare `on` (idx . snd))

createBlocks :: CodegenState -> [BasicBlock]
createBlocks m = map makeBlock $ sortBlocks $ Map.toList (blocks m)

mergeBlocks :: BasicBlock -> BasicBlock -> BasicBlock
mergeBlocks (BasicBlock _ srcInstrs _) (BasicBlock name targetInstrs term) =
  BasicBlock name (targetInstrs ++ srcInstrs) term

makeBlock :: (Name, BlockState) -> BasicBlock
makeBlock (l, BlockState _ s t) = BasicBlock l s (maketerm t)
  where
    maketerm (Just x) = x
    maketerm Nothing = error $ "Block has no terminator: " ++ show l

entryBlockName :: String
entryBlockName = "entry"

emptyBlock :: Int -> BlockState
emptyBlock i = BlockState i [] Nothing

emptyCodegen :: SymName -> CodegenState
emptyCodegen fname =
  CodegenState
    (Name entryBlockName) Map.empty Map.empty 1 0 Map.empty [] fname []

execCodegen :: SymName -> [SymName] -> Codegen a -> CodegenState
execCodegen fname globalVars computation =
  execState (runCodegen computation) $
    (emptyCodegen fname) { globalVars = globalVars }

fresh :: Codegen Word
fresh = do
  i <- gets count
  modify $ \s -> s { count = 1 + i }
  return $ i + 1

instr :: Instruction -> Codegen Operand
instr ins = do
  n <- fresh
  let ref = UnName n
  blk <- current
  let i = stack blk
  modifyBlock (blk { stack = i ++ [ref := ins] } )
  return $ local ref

terminator :: Named Terminator -> Codegen (Named Terminator)
terminator trm = do
  blk <- current
  modifyBlock (blk { term = Just trm })
  return trm

-------------------------------------------------------------------------------
-- Block Stack
-------------------------------------------------------------------------------

entry :: Codegen Name
entry = gets currentBlock

addBlock :: String -> Codegen Name
addBlock bname = do
  bls <- gets blocks
  ix <- gets blockCount
  nms <- gets names
  let new = emptyBlock ix
      (qname, supply) = uniqueName bname nms
  modify $ \s -> s { blocks = Map.insert (Name qname) new bls
                   , blockCount = ix + 1
                   , names = supply
                   }
  return (Name qname)

setBlock :: Name -> Codegen Name
setBlock bname = do
  modify $ \s -> s { currentBlock = bname }
  return bname

getBlock :: Codegen Name
getBlock = gets currentBlock

modifyBlock :: BlockState -> Codegen ()
modifyBlock new = do
  active <- gets currentBlock
  modify $ \s -> s { blocks = Map.insert active new (blocks s) }

current :: Codegen BlockState
current = do
  c <- gets currentBlock
  blks <- gets blocks
  case Map.lookup c blks of
    Just x -> return x
    Nothing -> error $ "No such block: " ++ show c

-------------------------------------------------------------------------------
-- Symbol Table
-------------------------------------------------------------------------------

assign :: String -> Operand -> Codegen ()
assign var x = do
  lcls <- gets symtab
  modify $ \s -> s { symtab = Map.insert var x lcls }

getvar :: String -> Codegen (Maybe Operand)
getvar var = return . Map.lookup var =<< gets symtab

-------------------------------------------------------------------------------

-- References
local :: Name -> Operand
local = LocalReference uint

global ::  Name -> C.Constant
global = C.GlobalReference uint

extern :: Name -> Operand
extern = ConstantOperand . C.GlobalReference uint

-- Arithmetic and Constants
iadd :: Operand -> Operand -> Codegen Operand
iadd a b = instr $ Add False False a b []

isub :: Operand -> Operand -> Codegen Operand
isub a b = instr $ Sub False False a b []

imul :: Operand -> Operand -> Codegen Operand
imul a b = instr $ Mul False False a b []

idiv :: Operand -> Operand -> Codegen Operand
idiv a b = instr $ SDiv False a b []

icmp :: IP.IntegerPredicate -> Operand -> Operand -> Codegen Operand
icmp cond a b = instr $ ICmp cond a b []

fadd :: Operand -> Operand -> Codegen Operand
fadd a b = instr $ FAdd NoFastMathFlags a b []

fsub :: Operand -> Operand -> Codegen Operand
fsub a b = instr $ FSub NoFastMathFlags a b []

fmul :: Operand -> Operand -> Codegen Operand
fmul a b = instr $ FMul NoFastMathFlags a b []

fdiv :: Operand -> Operand -> Codegen Operand
fdiv a b = instr $ FDiv NoFastMathFlags a b []

fcmp :: FP.FloatingPointPredicate -> Operand -> Operand -> Codegen Operand
fcmp cond a b = instr $ FCmp cond a b []

funcOpr :: Type -> Name -> [Type] -> Operand
funcOpr retTy name tys =
  constOpr $
    C.GlobalReference
      (FunctionType retTy tys False)
      name

namedType :: String -> Type
namedType = AST.NamedTypeReference . AST.Name

constUint :: Integral i => i -> Operand
constUint = constOpr . C.Int uintSize . fromIntegral

constUintSize :: Integral i => Word32 -> i -> Operand
constUintSize size = constOpr . C.Int size . fromIntegral

constOpr :: C.Constant -> Operand
constOpr = ConstantOperand

uitofp :: Type -> Operand -> Codegen Operand
uitofp ty a = instr $ UIToFP a ty []

inttoptr :: Operand -> Type -> Codegen Operand
inttoptr  a ty = instr $ IntToPtr a ty []

ptrtoint :: Operand -> Type -> Codegen Operand
ptrtoint  a ty = instr $ PtrToInt a ty []

zext :: Type -> Operand -> Codegen Operand
zext ty a = instr $ ZExt a ty []

shl :: Operand -> Operand -> Codegen Operand
shl a shiftSize = instr $ Shl False False a shiftSize []

shr :: Operand -> Operand -> Codegen Operand
shr a shiftSize = instr $ LShr False a shiftSize []

or :: Operand -> Operand -> Codegen Operand
or a b = instr $ Or a b []

toArgs :: [Operand] -> [(Operand, [A.ParameterAttribute])]
toArgs = map (\x -> (x, []))

-- Effects
call :: Operand -> [Operand] -> Codegen Operand
call fn args = instr $ Call False CC.C [] (Right fn) (toArgs args) [] []

bitcast :: Operand -> Type -> Codegen Operand
bitcast opr ty = instr $ BitCast opr ty []

alloca :: Type -> Codegen Operand
alloca ty = instr $ Alloca ty Nothing 0 []

store :: Operand -> Operand -> Codegen Operand
store ptr val = instr $ Store False ptr val Nothing 0 []

load :: Operand -> Codegen Operand
load ptr = instr $ Load False ptr Nothing 0 []

getelementptr :: Integral i => Operand -> i -> Codegen Operand
getelementptr address ix = getelementptrRaw address [0, ix]

getelementptrRaw :: Integral i => Operand -> [i] -> Codegen Operand
getelementptrRaw address ixs =
  instr $ GetElementPtr True address (map (constUintSize 32) ixs) []

-- Control Flow
br :: Name -> Codegen (Named Terminator)
br val = terminator $ Do $ Br val []

cbr :: Operand -> Name -> Name -> Codegen (Named Terminator)
cbr cond tr fl = terminator $ Do $ CondBr cond tr fl []

phi :: Type -> [(Operand, Name)] -> Codegen Operand
phi ty incoming = instr $ Phi ty incoming []

ret :: Operand -> Codegen (Named Terminator)
ret val = terminator $ Do $ Ret (Just val) []
