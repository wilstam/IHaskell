{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}
{- | Description : Wrapper around GHC API, exposing a single `evaluate` interface that runs
                   a statement, declaration, import, or directive.

This module exports all functions used for evaluation of IHaskell input.
-}
module IHaskell.Eval.Evaluate (
  interpret, evaluate, Interpreter, liftIO,
  typeCleaner
  ) where

import ClassyPrelude hiding (liftIO, hGetContents)
import Prelude(putChar, tail, init)
import Data.List.Utils
import Data.List(findIndex)
import Data.String.Utils
import Text.Printf

import Language.Haskell.Exts.Parser hiding (parseType)
import Language.Haskell.Exts.Pretty
import Language.Haskell.Exts.Syntax hiding (Name)

import InteractiveEval
import HscTypes
import GhcMonad (liftIO)
import GHC hiding (Stmt, TypeSig)
import GHC.Paths
import Exception hiding (evaluate)

import Outputable
import qualified System.IO.Strict as StrictIO

import IHaskell.Types

data ErrorOccurred = Success | Failure

debug :: Bool
debug = False

ignoreTypePrefixes :: [String]
ignoreTypePrefixes = ["GHC.Types", "GHC.Base", "GHC.Show", "System.IO",
                      "GHC.Float"]

typeCleaner :: String -> String
typeCleaner = useStringType . foldl' (.) id (map (`replace` "") fullPrefixes)
  where
    fullPrefixes = map (++ ".") ignoreTypePrefixes
    useStringType = replace "[Char]" "String"

makeWrapperStmts :: (String, [String], [String])
makeWrapperStmts = (fileName, initStmts, postStmts)
  where
    randStr = "1345964344725219474" :: String
    fileVariable = "file_var_" ++ randStr
    oldVariable = fileVariable ++ "_old"
    itVariable = "it_var_" ++ randStr
    fileName = ".ihaskell_capture"

    initStmts :: [String]
    initStmts = [
      printf "let %s = it" itVariable,
      printf "%s <- openFile \"%s\" WriteMode" fileVariable fileName,
      printf "%s <- hDuplicate stdout" oldVariable,
      printf "hDuplicateTo %s stdout" fileVariable,
      printf "let it = %s" itVariable]

    postStmts :: [String]
    postStmts = [
      printf "let %s = it" itVariable,
      "hFlush stdout",
      printf "hDuplicateTo %s stdout" oldVariable,
      printf "hClose %s" fileVariable,
      printf "let it = %s" itVariable]

write :: GhcMonad m => String -> m ()
write x = when debug $ liftIO $ hPutStrLn stderr x

type LineNumber = Int
type ColumnNumber = Int

type Interpreter = Ghc

data DirectiveType = GetType String deriving Show

data Command
  = Directive DirectiveType
  | Import String
  | Declaration String
  | Statement String
  | ParseError LineNumber ColumnNumber String
  deriving Show

globalImports :: [String]
globalImports = 
  [ "import Prelude"
  , "import Control.Applicative ((<$>))"
  , "import GHC.IO.Handle (hDuplicateTo, hDuplicate)"
  , "import System.IO"
  ]

directiveChar :: Char
directiveChar = ':'

-- | Run an interpreting action. This is effectively runGhc with
-- initialization and importing.
interpret :: Interpreter a -> IO a
interpret action = runGhc (Just libdir) $ do
  -- Set the dynamic session flags
  dflags <- getSessionDynFlags
  void $ setSessionDynFlags $ dflags { hscTarget = HscInterpreted, ghcLink = LinkInMemory }

  -- Import modules.
  imports <- mapM parseImportDecl globalImports
  setContext $ map IIDecl imports

  -- Give a value for `it`. This is required due to the way we handle `it`
  -- in the wrapper statements - if it doesn't exist, the first statement
  -- will fail.
  runStmt "()" RunToCompletion

  -- Run the rest of the interpreter
  action

-- | Evaluate some IPython input code.
evaluate :: Int                       -- ^ The execution counter of this evaluation.
         -> String                    -- ^ Haskell code or other interpreter commands.
         -> Interpreter [DisplayData] -- ^ All of the output.
evaluate execCount code
  | strip code == "" = return [] 
  | otherwise = joinDisplays <$> runUntilFailure (parseCommands (strip code) ++ [storeItCommand execCount])
  where
    runUntilFailure :: [Command] -> Interpreter [DisplayData]
    runUntilFailure [] = return []
    runUntilFailure (cmd:rest) = do 
      (success, result) <- evalCommand cmd
      case success of
        Success -> do
          restRes <- runUntilFailure rest
          return $ result ++ restRes
        Failure -> return result

    storeItCommand execCount = Statement $ printf "let it%d = it" execCount

joinDisplays :: [DisplayData] -> [DisplayData]
joinDisplays displays = 
  let isPlain (Display mime _) = (mime == PlainText)
      plains = filter isPlain displays
      other = filter (not . isPlain) displays 
      getText (Display PlainText text) = text
      joinedPlains = Display PlainText $ concat $ map getText plains in
    case length plains of
      0 -> other
      _ -> joinedPlains : other


parseCommands :: String     -- ^ Code containing commands.
              -> [Command]  -- ^ Commands contained in code string.
parseCommands code = joinMultilineDeclarations $ concatMap makeCommands pieces
  where
    -- Group the text into different pieces.
    -- Pieces can be declarations, statement lists, or directives.
    -- We distinguish declarations from statements via the first line an
    -- indentation, and directives based on the first character.
    indentLevel (' ':str) = 1 + indentLevel str
    indentLevel _ = 0 :: Int

    makePieces :: [String] -> [String]
    makePieces [] = []
    makePieces (first:rest)
      | isDirective first = first : makePieces rest
      | isImport first = first : makePieces rest
      | otherwise =
          -- Special case having a type declaration right before
          -- a function declaration. Using normal parsing, the type
          -- declaration and the function declaration are separate
          -- statements.
          if isTypeDeclaration firstStmt
          then case restStmt of
            funDec:rest -> (firstStmt ++ "\n" ++ funDec) : rest
            [] -> [firstStmt]
          else firstStmt : restStmt
          where (firstStmt, otherLines) = splitByIndent $ first:rest
                restStmt = makePieces otherLines

    splitByIndent :: [String] -> (String, [String])
    splitByIndent (first:rest) = (unlines $ first:take endOfBlock rest, filter (/= "") $ drop endOfBlock rest)
      where
        endOfBlock = fromMaybe (length rest) $ findIndex (\x -> indentLevel x <= indentLevel first) rest

    pieces = makePieces $ lines code
    makeCommands str
      | isDirective str = [createDirective str]
      | isImport str    = [Import $ strip str]
      | length rest > 0 && isTypeDeclaration first =
          let (firstStmt:restStmts) = makeCommands $ unlines rest in
            case firstStmt of
              Declaration decl -> Declaration (first ++ decl) : restStmts
              _ -> [ParseError 0 0 ("Expected declaration after type declaration: " ++ first)]
      | otherwise = case (parseDecl str, parseStmts str) of
            (ParseOk declaration, _) -> [Declaration $ prettyPrint declaration]
            (ParseFailed {}, Right stmts) -> map (Statement . prettyPrint) $ init stmts

            -- Show the parse error for the most likely type.
            (ParseFailed srcLoc errMsg, _) | isDeclaration str  -> [ParseError (srcLine srcLoc) (srcColumn srcLoc) errMsg]
            (_, Left (lineNumber, colNumber,errMsg)) -> [ParseError lineNumber colNumber errMsg]
      where
        (first, rest) = splitByIndent $ lines str

    -- Check whether this string reasonably represents a type declaration
    -- for a variable. 
    isTypeDeclaration :: String -> Bool
    isTypeDeclaration str = case parseDecl str of
      ParseOk TypeSig{} -> True
      _ -> False

    isDeclaration line = any (`isInfixOf` line) ["type", "newtype", "data", "instance", "class"]
    isDirective line = startswith [directiveChar] (strip line) 
    isImport line = startswith "import" (strip line)

    createDirective line = case strip line of
      ':':'t':' ':expr -> Directive (GetType expr)
      other            -> ParseError 0 0 $ "Unknown command: " ++ other ++ "."

joinMultilineDeclarations :: [Command] -> [Command]
joinMultilineDeclarations = map joinCommands . groupBy declaringSameFunction
  where
    joinCommands :: [Command] -> Command
    joinCommands [x] = x
    joinCommands commands = Declaration . unlines $ map getDeclarationText commands
      where
        getDeclarationText (Declaration text) = text

    declaringSameFunction :: Command -> Command -> Bool
    declaringSameFunction (Declaration first) (Declaration second) = declared first == declared second
      where declared :: String -> String
            declared = takeWhile (`notElem` (" \t\n:" :: String)) . strip
    declaringSameFunction _ _ = False

wrapExecution :: Interpreter [DisplayData] -> Interpreter (ErrorOccurred, [DisplayData])
wrapExecution exec = ghandle handler $ exec >>= \res ->
    return (Success, res)
  where 
    handler :: SomeException -> Interpreter (ErrorOccurred, [DisplayData])
    handler exception = return (Failure, [Display MimeHtml $ makeError $ show exception])

-- | Return the display data for this command, as well as whether it
-- resulted in an error.
evalCommand :: Command -> Interpreter (ErrorOccurred, [DisplayData])
evalCommand (Import importStr) = wrapExecution $ do
  write $ "Import: " ++ importStr
  importDecl <- parseImportDecl importStr
  context <- getContext
  setContext $ IIDecl importDecl : context
  return []

evalCommand (Directive (GetType expr)) = wrapExecution $ do
  result <- exprType expr
  dflags <- getSessionDynFlags
  return [Display MimeHtml $ printf "<span style='font-weight: bold; color: green;'>%s</span>" $ showSDocUnqual dflags $ ppr result]

evalCommand (Statement stmt) = do
  write $ "Statement: " ++ stmt
  ghandle handler $ do
    (printed, result) <- capturedStatement stmt
    case result of
      RunOk names -> do
        dflags <- getSessionDynFlags
        write $ "Names: " ++ show (map (showPpr dflags) names)  
        return (Success, [Display PlainText printed])
      RunException exception -> do
        write $ "RunException: " ++ show exception
        return (Failure, [Display MimeHtml $ makeError $ show exception])
      RunBreak{} ->
        error "Should not break."
  where 
    handler :: SomeException -> Interpreter (ErrorOccurred, [DisplayData])
    handler exception = do
      write $ concat ["BreakCom: ", show exception, "\nfrom statement:\n", stmt]

      -- Close the file handle we opened for writing stdout and other cleanup.
      let (_, _, postStmts) = makeWrapperStmts
      forM_ postStmts $ \s -> runStmt s RunToCompletion

      return (Failure, [Display MimeHtml $ makeError $ show exception])

evalCommand (Declaration decl) = wrapExecution $ runDecls decl >> return []

evalCommand (ParseError line col err) = wrapExecution $
  return [Display MimeHtml $ makeError $ printf "Error (line %d, column %d): %s" line col err]

capturedStatement :: String -> Interpreter (String, RunResult)
capturedStatement stmt = do
  -- Generate random variable names to use so that we cannot accidentally
  -- override the variables by using the right names in the terminal.
  let (fileName, initStmts, postStmts) = makeWrapperStmts
      goStmt s = runStmt s RunToCompletion

  forM_ initStmts goStmt
  result <- goStmt stmt
  forM_ postStmts goStmt

  -- We must use strict IO, because we write to that file again if we
  -- execute more statements. If we read lazily, we may cause errors when
  -- trying to open the file for writing later.
  printedOutput <- liftIO $ StrictIO.readFile fileName

  return (printedOutput, result)

parseStmts :: String -> Either (LineNumber, ColumnNumber, String) [Stmt]
parseStmts code = 
  case parseResult of
    ParseOk (Do stmts) -> Right stmts
    ParseOk _ -> Right []
    ParseFailed srcLoc errMsg -> Left (srcLine srcLoc, srcColumn srcLoc, errMsg) 
  where
    parseResult = parseExp doBlock
    doBlock = unlines $ ("do" : map indent (lines code)) ++ [indent returnStmt]
    indent = ("  " ++) 
    returnStmt = "return ()"

makeError :: String -> String
makeError = printf "<span style='color: red; font-style: italic;'>%s</span>" .
            replace "\n" "<br/>" . 
            replace useDashV "" .
            typeCleaner
  where 
        useDashV = "\nUse -v to see a list of the files searched for."
