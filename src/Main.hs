{-# LANGUAGE TemplateHaskell #-}
module Main()
where

import System.Environment
import System.Exit
import System.Console.GetOpt
import System.FilePath
import System.Directory
import System.IO
import Data.Either
import Data.List
import Data.Maybe
import Data.Char
import Control.Monad
import Text.Printf
import qualified Data.Set as S

import Text.Regex.Posix
import Safe

import HeaderParser
import HeaderData
import DeriveMod

getFuns :: [Object] -> [Object]
getFuns [] = []
getFuns (o:os) = 
  case o of
    (FunDecl _ _ _ _ _ _)   -> o : getFuns os
    (Namespace _ os2)       -> getFuns os2 ++ getFuns os
    (ClassDecl _ _ n _ os2) -> 
       case n of
         []              -> getFuns os2 ++ getFuns os
         ((Public, _):_) -> getFuns os2 ++ getFuns os
         _               -> getFuns os
    _                       -> getFuns os

getClasses :: [Object] -> [Object]
getClasses [] = []
getClasses (o:os) = 
  case o of
    (Namespace _ os2)       -> getClasses os2 ++ getClasses os
    (ClassDecl _ _ _ _ os2) -> o : getClasses os2 ++ getClasses os
    _                       -> getClasses os

getObjName :: Object -> String
getObjName (FunDecl n _ _ _ _ _) = n
getObjName (Namespace n _ )      = n
getObjName (TypeDef (n, _))      = n
getObjName (ClassDecl n _ _ _ _) = n
getObjName (VarDecl p _)         = varname p
getObjName (EnumDef n _)         = n

publicMemberFunction :: Object -> Bool
publicMemberFunction (FunDecl _ _ _ _ (Just (Public, _)) _) = True
publicMemberFunction _                                      = False

data Options = Options
  {
    outputdir       :: FilePath
  , inputfiles      :: [FilePath]
  , includefiles    :: [FilePath]
  , excludepatterns :: [String] 
  , dumpmode        :: Bool
  }
$(deriveMods ''Options)

defaultOptions :: Options
defaultOptions = Options "" [] [] [] False

options :: [OptDescr (Options -> Options)]
options = [
    Option ['o'] ["output"]  (ReqArg (setOutputdir) "Directory")             "output directory for the C files"
  , Option []    ["header"]  (ReqArg (\l -> modIncludefiles   (l:)) "File")  "file to include in the generated headers"
  , Option []    ["exclude"] (ReqArg (\l -> modExcludepatterns (l:)) "File") "exclude pattern for function names"
  , Option []    ["dump"]    (NoArg  (setDumpmode True))                     "simply dump the parsed data of the header"
  ]

main :: IO ()
main = do 
  args <- getArgs
  let (actions, rest, errs) = getOpt Permute options args
  when (not (null errs)) $ do
    mapM_ print errs
    exitWith (ExitFailure 1)
  let opts = foldl' (flip ($)) defaultOptions actions
  contents <- mapM readFile rest
  let parses = map parseHeader contents
      (perrs, press) = partitionEithers parses
  case perrs of
    ((str, err):_) -> do
        putStrLn str
        putStrLn $ "Could not parse: " ++ show err
        exitWith (ExitFailure 1)
    _              -> do
      if dumpmode opts
        then print press
        else handleParses (outputdir opts) (includefiles opts) (excludepatterns opts) $ zip (map takeFileName rest) press

handleParses :: FilePath -> [FilePath] -> [String] -> [(FilePath, [Object])] -> IO ()
handleParses outdir incfiles excls objs = do
    createDirectoryIfMissing True outdir
    mapM_ (uncurry $ handleHeader outdir incfiles excls) objs
    exitWith ExitSuccess

toCapital = map toUpper

showP (ParamDecl pn pt _ _) = pt ++ " " ++ pn

paramFormat :: [ParamDecl] -> String
paramFormat (p1:p2:ps) = showP p1 ++ ", " ++ paramFormat (p2:ps)
paramFormat [p1]       = showP p1
paramFormat []         = ""

correctParam :: ParamDecl -> ParamDecl
correctParam p = p{vartype = correctType (vartype p)} -- TODO: arrays?

refToPointerParam :: ParamDecl -> ParamDecl
refToPointerParam p = p{vartype = refToPointer (vartype p)}

refToPointer :: String -> String
refToPointer t = 
  if last t == '&'
    then init t ++ "*"
    else t

-- separate pointer * from other chars.
correctType :: String -> String
correctType t =
  let ns = words t
  in case ns of
       []  -> ""
       ms  -> intercalate " " $ sepChars "*" $ filter isType ms

sepChars :: String -> [String] -> [String]
sepChars st = map (sepChar st)

sepChar :: String -> String -> String
sepChar st (x:y:xs)    = if x /= ' ' && x `notElem` st && y `elem` st
                           then x {-: ' '-} : sepChar st (y:xs)
                           else x : sepChar st (y:xs)
sepChar _  l           = l

isType :: String -> Bool
isType "virtual" = False
isType "static"  = False
isType "const"   = False
isType "mutable" = False
isType "struct"  = False
isType "union"   = False
isType "inline"  = False
isType _         = True

handleHeader :: FilePath -> [FilePath] -> [String] -> FilePath -> [Object] -> IO ()
handleHeader outdir incfiles excls headername objs = do
    withFile outfile WriteMode $ \h -> do
        hPrintf h "#ifndef CGEN_%s_H\n" (toCapital (takeBaseName headername))
        hPrintf h "#define CGEN_%s_H\n" (toCapital (takeBaseName headername))
        hPrintf h "\n"
        forM_ incfiles $ \inc -> do
            hPrintf h "#include <%s>\n" inc
        hPrintf h "\n"
        hPrintf h "extern \"C\"\n"
        hPrintf h "{\n"
        -- hPrintf h "#ifndef CGEN_OUTPUT_INTERN\n"
        -- hPrintf h "\n"
        -- forM_ classnames $ \cl -> do
            -- hPrintf h "struct %s;\n" cl
        -- hPrintf h "\n"
        -- hPrintf h "#else\n"
        hPrintf h "\n"
        forM_ namespaces $ \ns -> do
            hPrintf h "using namespace %s;\n" ns
        hPrintf h "\n"
        forM_ typedefs $ \(td1, td2) -> do
            hPrintf h "typedef %s %s;\n" td1 td2
        print extratypedefs
        -- hPrintf h "\n"
        -- hPrintf h "#endif\n"
        hPrintf h "\n"
        forM_ funs $ \fun -> do
            hPrintf h "%s %s(%s);\n" 
                (rettype fun) 
                (funname fun) 
                (paramFormat (params fun))
        hPrintf h "\n"
        hPrintf h "}\n"
        hPrintf h "\n"
        hPrintf h "#endif\n"
        hPrintf h "\n"
        hPutStrLn stderr $ "Wrote file " ++ outfile

    withFile cppoutfile WriteMode $ \h -> do
        hPrintf h "#define CGEN_OUTPUT_INTERN\n"
        hPrintf h "#include \"%s\"" headername
        hPrintf h "\n"
        forM_ (zip funs allfuns) $ \(fun, origfun) -> do
            hPrintf h "%s %s(%s)\n" 
                (rettype fun)
                (funname fun)
                (paramFormat (params fun))
            hPrintf h "{\n"
            let prs = intercalate ", " $ map correctRef (params origfun)
            switch (funname origfun)
              [(getClname origfun,      hPrintf h "    return new %s(%s);\n" (funname origfun) prs),
               ('~':getClname origfun,  hPrintf h "    delete this_ptr;\n")]
              (if rettype fun == "void" 
                 then hPrintf h "    this_ptr->%s(%s);\n" (funname origfun) prs
                 else hPrintf h "    return this_ptr->%s(%s);\n" (funname origfun) prs)
            hPrintf h "}\n"
            hPrintf h "\n"
        hPutStrLn stderr $ "Wrote file " ++ cppoutfile

  where outfile    = (outdir </> headername)
        cppoutfile = (outdir </> takeBaseName headername <.> "cpp")
        allfuns    = filter (\f -> publicMemberFunction f && not (abstract f) && not (excludeFun f)) (getFuns objs)
        namespaces = filter (not . null) $ nub $ map (headDef "") (map fnnamespace funs)
        classnames = filter (not . null) $ nub $ map getObjName $ getClasses objs
        classes    = concatMap (\nm -> filter (classHasName nm) (getClasses objs)) classnames
        alltypedefs = catMaybes $ map getTypedef (concatMap classobjects classes)
        usedtypedefs = usedTypedefs usedtypes alltypedefs
        extratypedefs = extraTypedefs usedtypedefs alltypedefs -- TODO: simply use all public typedefs instead
        typedefs   = nub $ extratypedefs ++ usedtypedefs
        funs       = mangle $ map expandFun allfuns
        excludeFun f = lastDef ' ' (correctType $ rettype f) == '&' || -- TODO: allow returned references
                       or (map (\e -> funname f =~ e) excls) ||
                       take 8 (funname f) == "operator"
        expandFun f = correctFuncRetType . correctFuncParams . finalName . addClassspaces classes . addThisPointer . extendFunc $ f
        usedtypes  = getAllTypes funs

-- typesInType "int" = ["int"]
-- typesInType "map<String, Animation*>::type" = ["String", "Animation"]
typesInType :: String -> [String]
typesInType v =
    case betweenAngBrackets v of
      "" -> [stripPtr v]
      n  -> map stripPtr $ splitBy ',' n

splitBy :: Char -> String -> [String]
splitBy c str = 
  let (w1, rest) = break (== c) str
  in if null rest
       then if null w1 then [] else [w1]
       else w1 : splitBy c (tailSafe rest)

extraTypedefs :: [(String, String)] -> [(String, String)] -> [(String, String)]
extraTypedefs ts = filter (extractSecType ts)

extractSecType :: [(String, String)] -> (String, String) -> Bool
extractSecType ts (_, t2) = 
  let sectypes = typesInType t2
      tsstypes = concatMap typesInType (map fst ts)
  in (any (`elem` tsstypes) sectypes)

-- "aaa < bbb, ddd> fff" = " bbb, ddd"
betweenAngBrackets :: String -> String
betweenAngBrackets = fst . foldr go ("", Nothing)
  where go _   (accs, Just True)  = (accs, Just True)    -- done
        go '>' (accs, Nothing)    = (accs, Just False)   -- start
        go '<' (accs, Just False) = (accs, Just True)    -- finish
        go c   (accs, Just False) = (c:accs, Just False) -- collect
        go _   (accs, Nothing)    = (accs, Nothing)      -- continue

-- filtering typedefs doesn't help - t1 may refer to private definitions.
usedTypedefs :: S.Set String -> [(String, String)] -> [(String, String)]
usedTypedefs s = filter (\(_, t2) -> t2 `S.member` s)

getAllTypes :: [Object] -> S.Set String
getAllTypes = S.fromList . map stripPtr . concatMap getUsedFunTypes

getUsedFunTypes :: Object -> [String]
getUsedFunTypes (FunDecl _ rt ps _ _ _) =
  rt:(map vartype ps)
getUsedFunTypes _ = []

-- for all types of a function, turn "y" into "x::y" when y is a nested class inside x.
addClassspaces :: [Object] -> Object -> Object
addClassspaces classes f@(FunDecl _ rt ps _ _ _) =
  let rt' = addClassQual classes rt
      ps' = map (addParamClassQual classes) ps
  in f{rettype = rt',
       params  = ps'}
addClassspaces _       n                         = n

addParamClassQual :: [Object] -> ParamDecl -> ParamDecl
addParamClassQual classes p@(ParamDecl _ t _ _) =
  let t' = addClassQual classes t
  in p{vartype = t'}

addClassQual classes rt =
  case fetchClass classes (stripPtr rt) of
    Nothing -> rt
    Just c  -> addNamespaceQual (map snd $ classnesting c) rt

stripPtr :: String -> String
stripPtr = stripWhitespace . takeWhile (/= '*')

stripWhitespace :: String -> String
stripWhitespace = snd . foldr go (True, "") . dropWhile (== ' ')
  where go ' ' (True,  acc) = (True, acc)
        go x   (_,     acc) = (False, x:acc)

fetchClass classes n = headMay $ filter (classHasName n) classes

addNamespaceQual :: [String] -> String -> String
addNamespaceQual ns n = concatMap (++ "::") ns ++ n

classHasName :: String -> Object -> Bool
classHasName n (ClassDecl cn _ _ _ _) = n == cn
classHasName _ _                      = False

getTypedef :: Object -> Maybe (String, String)
getTypedef (TypeDef t) = Just t
getTypedef _           = Nothing

-- turn a "char& param" into "*param".
correctRef :: ParamDecl -> String
correctRef (ParamDecl nm pt _ _) =
  if '&' `elem` take 2 (reverse pt)
    then '*':nm
    else nm

switch :: (Eq a) => a -> [(a, b)] -> b -> b
switch _ []          df = df
switch v ((n, f):ns) df
  | v == n    = f
  | otherwise = switch v ns df

getClname :: Object -> String
getClname (FunDecl _ _ _ _ (Just (_, n)) _) = n
getClname _                                 = ""

-- change ref to pointer and separate pointer * from other chars for all params.
correctFuncParams :: Object -> Object
correctFuncParams f@(FunDecl _ _ ps _ _ _) = 
  f{params = map (correctParam . refToPointerParam) ps}
correctFuncParams n                                 = n

-- expand function name by namespace and class name.
finalName :: Object -> Object
finalName f@(FunDecl fname _ _ funns _ _) =
  let clname = getClname f
      nsname = headDef "" funns
      updname = nsname ++ (if not (null nsname) then "_" else "") ++ 
                clname ++ (if not (null clname) then "_" else "") ++ fname
  in f{funname = updname}
finalName n = n

constructorName, destructorName :: String
constructorName = "new"
destructorName = "delete"

addThisPointer :: Object -> Object
addThisPointer f@(FunDecl fname _ ps _ (Just (_, clname)) _)
  | fname == constructorName = f
  | otherwise
    = f{params = (t:ps)}
      where t = ParamDecl "this_ptr" (clname ++ "*") Nothing Nothing
addThisPointer n = n

-- correct constructors and destructors.
extendFunc :: Object -> Object
extendFunc f@(FunDecl fname _ _ _ (Just (_, clname)) _) 
  | fname == clname = f{funname = constructorName,
                        rettype = fname ++ " *"}
  | fname == '~':clname = f{funname = destructorName,
                            rettype = "void"}
  | otherwise           = f
extendFunc n = n

-- separate pointer * from other chars in function return type.
correctFuncRetType :: Object -> Object
correctFuncRetType f@(FunDecl _ fr _ _ _ _)
  = f{rettype = correctType fr}
correctFuncRetType n = n

-- o(n).
mangle :: [Object] -> [Object]
mangle []     = []
mangle (n:ns) = 
  let num = length $ filter (== funname n) $ map funname ns
      m   = n{funname = funname n ++ show num}
  in if num == 0
       then n : mangle ns
       else m : mangle ns

