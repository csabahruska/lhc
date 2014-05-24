{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Compiler.HaskellToCore
    ( convert
    ) where

import Control.Applicative
import           Control.Monad.Reader
import           Control.Monad.State
import           Control.Monad.Writer
import           Control.Monad.RWS
import           Data.Map                        (Map)
import qualified Data.Map                        as Map
import           Data.Maybe
import qualified Language.Haskell.Exts.Annotated as HS

import           Compiler.Core
import Data.Bedrock.Misc
import           Data.Bedrock                    (AvailableNamespace(..),
                                                  CType (..), Foreign (..),
                                                  Name (..), Type (..),
                                                  Variable (..), NodeDefinition(..))
import           Language.Haskell.Scope          (GlobalName (..),
                                                  NameInfo (Global), Scoped,
                                                  Scoped (..),
                                                  getNameIdentifier)
import qualified Language.Haskell.Scope as Scope

data Scope = Scope
    { scopeVariables    :: Map HS.SrcLoc Name
    , scopeNodes        :: Map GlobalName Name
    , scopeConstructors :: Map GlobalName Name -- XXX: Merge with scopeNodes?
    }
instance Monoid Scope where
    mempty = Scope
        { scopeVariables    = Map.empty
        , scopeNodes        = Map.empty
        , scopeConstructors = Map.empty }
    mappend a b = Scope
        { scopeVariables    = w scopeVariables
        , scopeNodes        = w scopeNodes
        , scopeConstructors = w scopeConstructors }
        where w f = mappend (f a) (f b)

data Env = Env
    { envScope        :: Scope
    , envForeigns     :: [Foreign]
    , envNodes        :: [NodeDefinition]
    , envDecls        :: [Decl]
    , envConstructors :: Map Name Name
    }

instance Monoid Env where
    mempty = Env
        { envScope    = mempty
        , envForeigns = mempty
        , envNodes    = mempty
        , envDecls    = mempty
        , envConstructors = mempty
        }
    mappend a b = Env
        { envScope    = w envScope
        , envForeigns = w envForeigns
        , envNodes    = w envNodes
        , envDecls    = w envDecls
        , envConstructors = w envConstructors
        }
        where w f = mappend (f a) (f b)

newtype M a = M { unM :: RWS Scope Env AvailableNamespace a }
    deriving
        ( Monad, Functor, Applicative
        , MonadReader Scope, MonadState AvailableNamespace
        , MonadWriter Env )

runM :: M a -> (AvailableNamespace, Env)
runM m = (ns', env)
  where
    (ns', env) = execRWS (unM m) (envScope env) ns
    ns = AvailableNamespace 0 0 0 0

pushForeign :: Foreign -> M ()
pushForeign f = tell mempty{ envForeigns = [f] }

pushDecl :: Decl -> M ()
pushDecl decl = tell mempty{ envDecls = [decl] }

pushNode :: NodeDefinition -> M ()
pushNode def = tell mempty{ envNodes = [def] }

newUnique :: M Int
newUnique = do
    ns <- get
    let (idNum, ns') = newGlobalID ns
    put ns'
    return idNum

newName :: String -> M Name
newName ident = do
    u <- newUnique
    return $ Name [] ident u

bindName :: HS.Name Scoped -> M Name
bindName hsName =
    case info of
        Scope.Variable point -> do
            name <- newName (getNameIdentifier hsName)
            tell $ mempty{envScope = mempty
                { scopeVariables = Map.singleton point name } }
            return name
        Scope.Global global@(GlobalName m ident) -> do
            name <- newName ident
            let n = name{nameModule = [m]}
            tell $ mempty{envScope = mempty
                { scopeNodes = Map.singleton global n } }
            return n
        _ -> error "bindName"
  where
    Scoped info _ = HS.ann hsName

bindConstructor :: HS.Name Scoped -> Name -> M Name
bindConstructor dataCon mkCon =
    case info of
        Scope.Global global@(GlobalName m ident) -> do
            name <- newName ident
            let n = name{nameModule = [m]}
            tell $ mempty{envScope = mempty
                { scopeNodes = Map.singleton global n
                , scopeConstructors = Map.singleton global mkCon } }
            return n
        _ -> error "bindName"
  where
    Scoped info _ = HS.ann dataCon

resolveName :: HS.Name Scoped -> M Name
resolveName hsName =
    case info of
        Scope.Variable point -> do
            asks $ Map.findWithDefault scopeError point . scopeVariables
        Scope.Global gname ->
            asks $ Map.findWithDefault scopeError gname . scopeConstructors
        _ -> error "resolveName"
  where
    Scoped info _ = HS.ann hsName
    scopeError = error $ "resolveName: Not in scope: " ++
                    getNameIdentifier hsName

resolveGlobalName :: GlobalName -> M Name
resolveGlobalName gname =
    asks $ Map.findWithDefault scopeError gname . scopeNodes
  where
    scopeError = error $ "resolveGlobalName: Not in scope: " ++ show gname

resolveQName :: HS.QName Scoped -> M Name
resolveQName qname =
    case qname of
        HS.Qual _ _ name -> resolveName name
        HS.UnQual _ name -> resolveName name
        _ -> error "HaskellToCore.resolveQName"

-- XXX: Ugly, ugly code.
resolveQGlobalName :: HS.QName Scoped -> M Name
resolveQGlobalName qname =
    case qname of
        HS.Qual _ _ name -> worker name
        HS.UnQual _ name -> worker name
        _ -> error "HaskellToCore.resolveQName"
  where
    worker name =
        let Scoped (Global gname) _ = HS.ann name
        in resolveGlobalName gname

--resolveConstructor :: HS.QName Scoped -> M Name
--resolveConstructor con = do
--    name <- resolveQName con
--    asks 

convert :: HS.Module Scoped -> Module
convert (HS.Module _ _ _ _ decls) = Module
    { coreForeigns  = envForeigns env
    , coreDecls     = envDecls env
    , coreNodes     = envNodes env
    , coreNamespace = ns }
  where
    (ns, env) = runM $ do
        mapM_ convertDecl decls
convert _ = error "HaskellToCore.convert"

convertDecl :: HS.Decl Scoped -> M ()
convertDecl decl =
    case decl of
        HS.FunBind _ [HS.Match _ name pats rhs _] ->
            pushDecl =<< Decl
                <$> bindName name
                <*> convertPats pats rhs
            -- (convertName name, convertPats pats rhs)
        HS.PatBind _ (HS.PVar _ name) _type rhs _binds ->
            pushDecl =<< Decl
                <$> bindName name
                <*> convertRhs rhs
        HS.ForImp _ _conv _safety mbExternal name ty -> do
            let external = fromMaybe (getNameIdentifier name) mbExternal
            pushDecl =<< Decl
                <$> bindName name
                <*> convertExternal external ty

            let (argTypes, _isIO, retType) = ffiTypes ty
            pushForeign $ Foreign
                { foreignName = external
                , foreignReturn = retType
                , foreignArguments = argTypes }

        HS.DataDecl _ (HS.DataType _) _ctx _dhead qualCons _deriving ->
            mapM_ convertQualCon qualCons
        _ -> return ()

convertQualCon :: HS.QualConDecl Scoped -> M ()
convertQualCon (HS.QualConDecl _ _tyvars _ctx con) =
    convertConDecl con

convertConDecl :: HS.ConDecl Scoped -> M ()
convertConDecl con =
    case con of
        HS.ConDecl _ name tys -> do
            
            u <- newUnique
            let mkCon = Name [] ("mk" ++ getNameIdentifier name) u

            conName <- bindConstructor name mkCon
            rockTypes <- mapM convertBangType tys

            argNames <- replicateM (length tys) (newName "arg")
            let args = zipWith Variable argNames rockTypes
            pushDecl $ Decl mkCon (Lam args $ Con conName args)

            pushNode $ NodeDefinition conName rockTypes
        _ -> error "convertCon"

convertBangType :: HS.BangType Scoped -> M Type
convertBangType bty =
    case bty of
        HS.UnBangedTy _ ty -> convertType ty
        HS.BangedTy _ ty -> convertType ty
        _ -> error "convertBangType"

convertType :: HS.Type Scoped -> M Type
convertType ty =
    case ty of
        HS.TyCon _ qname
            | toGlobalName qname == GlobalName "Main" "I8"
            -> pure $ Primitive I8
            | toGlobalName qname == GlobalName "Main" "I32"
            -> pure $ Primitive I32
            | toGlobalName qname == GlobalName "Main" "I64"
            -> pure $ Primitive I64
            | toGlobalName qname == GlobalName "Main" "RealWorld"
            -> pure NodePtr -- $ Primitive CVoid
        HS.TyApp _ (HS.TyCon _ qname) sub
            | toGlobalName qname == GlobalName "Main" "Addr"
            -> do
                subTy <- convertType sub
                case subTy of
                    Primitive p -> pure $ Primitive (CPointer p)
                    _ -> error "Addr to non-primitive type"
        HS.TyParen _ sub ->
            convertType sub
        HS.TyVar{} -> pure NodePtr
        HS.TyCon{} -> pure NodePtr
        _ -> error $ "convertType: " ++ show ty -- pure NodePtr


-- cfun :: Addr I8 -> IO ()
-- \ptr s -> External cfun Void [ptr,s]
-- cfun :: Addr I8 -> IO CInt
-- \ptr s -> External cfun CInt [ptr,s]
-- cfun :: CInt -> CInt
-- \cint -> External cfun [cint]
convertExternal :: String -> HS.Type Scoped -> M Expr
convertExternal cName ty
    | isIO      = do
        out <- newName "out"
        let outV = Variable out (Primitive retType)
        unit <- resolveGlobalName (GlobalName "Main" "IOUnit")
        let mkUnit = Variable unit NodePtr
        pure $ Lam (args ++ [s])
            (WithExternal outV cName retType args s
                (Con unit [outV, s]))
    -- | otherwise = pure $ Lam args (ExternalPure cName retType args)
  where
    s = Variable (Name [] "s" 0) NodePtr
    (argTypes, isIO, retType) = ffiTypes ty
    args =
        [ Variable (Name [] "arg" 0) (Primitive t)
        | t <- argTypes ]

--packCType :: CType -> Expr -> M Expr
--packCType 

ffiTypes :: HS.Type Scoped -> ([CType], Bool, CType)
ffiTypes = worker []

  where
    worker acc ty =
        case ty of
            HS.TyFun _ t ty' -> worker (toBedrockType t : acc) ty'
            HS.TyApp _ (HS.TyCon _ qname) sub
                | toGlobalName qname == GlobalName "Main" "IO"
                    -> (reverse acc, True, toBedrockType sub)
            _ -> (reverse acc, False, toBedrockType ty)
            --_ -> error "ffiArguments"
    -- Addr ty
    toBedrockType (HS.TyApp _ (HS.TyCon _ qname) ty)
        | toGlobalName qname == GlobalName "Main" "Addr"
            = CPointer (toBedrockType ty)
    -- Void
    toBedrockType (HS.TyCon _ (HS.Special _ (HS.UnitCon _)))
        = CVoid
    -- I8, I32
    toBedrockType (HS.TyCon _ qname)
        | toGlobalName qname == GlobalName "Main" "I8"
            = I8
        | toGlobalName qname == GlobalName "Main" "I32"
            = I32
    toBedrockType t = error $ "toBedrockType: " ++ show t


convertPats :: [HS.Pat Scoped] -> HS.Rhs Scoped -> M Expr
convertPats [] rhs = convertRhs rhs
convertPats pats rhs =
    Lam <$> sequence [ Variable <$> bindName name <*> pure NodePtr
                    | HS.PVar _ name <- pats ]
        <*> (convertRhs rhs)

convertRhs :: HS.Rhs Scoped -> M Expr
convertRhs rhs =
    case rhs of
        HS.UnGuardedRhs _ expr -> convertExp expr
        _ -> error "convertRhs"

convertExp :: HS.Exp Scoped -> M Expr
convertExp expr =
    case expr of
        HS.Var _ name -> do
            n <- resolveQName name
            return $ Var (Variable n NodePtr)
        HS.Con _ name -> do
            n <- resolveQName name
            return $ Var (Variable n NodePtr)
        HS.App _ a b ->
            App
                <$> convertExp a
                <*> convertExp b
        HS.InfixApp _ a (HS.QVarOp _ var) b -> do
            ae <- convertExp a
            be <- convertExp b
            n <- resolveQName var
            pure $ App (App (Var (Variable n NodePtr)) ae) be
        HS.Paren _ sub -> convertExp sub
        HS.Lambda _ pats sub ->
            Lam
                <$> sequence [ Variable <$> bindName name <*> pure NodePtr
                        | HS.PVar _ name <- pats ]
                <*> convertExp sub
        HS.Case _ scrut alts ->
            Case
                <$> convertExp scrut
                <*> mapM convertAlt alts
        HS.Lit _ lit -> pure $ Lit (convertLiteral lit)
        --HS.Tuple  _ HS.Unboxed exprs ->
        --    Var [ Variable (convertQName name) NodePtr
        --        | HS.Var _ name <- exprs ]
        _ -> error $ "convertExp: " ++ show expr

convertAlt :: HS.Alt Scoped -> M Alt
convertAlt alt =
    case alt of
        HS.Alt _ (HS.PApp _ name pats) (HS.UnGuardedAlt _ branch) Nothing -> do
            args <- sequence [ Variable <$> bindName var <*> pure NodePtr
                             | HS.PVar _ var <- pats ]
            Alt <$> (ConPat <$> resolveQGlobalName name <*> pure args)
                <*> convertExp branch
        _ -> error "convertAlt"


convertLiteral :: HS.Literal Scoped -> Literal
convertLiteral lit =
    case lit of
        HS.PrimString _ str _ -> LitString str
        HS.PrimInt _ int _    -> LitInt int
        _ -> error "convertLiteral"

toGlobalName :: HS.QName Scoped -> GlobalName
toGlobalName qname =
    case info of
        Global gname -> gname
        _ -> error $ "toGlobalName: " ++ show qname
  where
    Scoped info _ = HS.ann qname
