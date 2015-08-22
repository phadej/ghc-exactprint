{-# LANGUAGE CPP #-}
{-# LANGUAGE ViewPatterns #-}
-----------------------------------------------------------------------------
-- |
-- This module rexposes wrapped parsers from the GHC API. Along with
-- returning the parse result, the corresponding annotations are also
-- returned such that it is then easy to modify the annotations and print
-- the result.
--
----------------------------------------------------------------------------
module Language.Haskell.GHC.ExactPrint.Parsers (
        -- * Utility
          Parser
        , withDynFlags
        , CppOptions(..)
        , defaultCppOptions

        -- * Module Parsers
        , parseModule
        , parseModuleWithCpp

        -- * Basic Parsers
        , parseExpr
        , parseImport
        , parseType
        , parseDecl
        , parsePattern
        , parseStmt

        , parseWith
        ) where

import Language.Haskell.GHC.ExactPrint.Annotate
import Language.Haskell.GHC.ExactPrint.Delta
import Language.Haskell.GHC.ExactPrint.Preprocess
import Language.Haskell.GHC.ExactPrint.Types

import Control.Monad.RWS

import GHC.Paths (libdir)

import qualified ApiAnnotation as GHC
import qualified DynFlags      as GHC
import qualified FastString    as GHC
import qualified GHC           as GHC hiding (parseModule)
import qualified HeaderInfo    as GHC
import qualified Lexer         as GHC
import qualified MonadUtils    as GHC
import qualified Outputable    as GHC
import qualified Parser        as GHC
import qualified SrcLoc        as GHC
import qualified StringBuffer  as GHC

#if __GLASGOW_HASKELL__ <= 710
import qualified OrdList as OL
#endif

import qualified Data.Map as Map

-- ---------------------------------------------------------------------

-- | Wrapper function which returns Annotations along with the parsed
-- element.
parseWith :: Annotate w
          => GHC.DynFlags
          -> FilePath
          -> GHC.P (GHC.Located w)
          -> String
          -> Either (GHC.SrcSpan, String) (Anns, GHC.Located w)
parseWith dflags fileName parser s =
  case runParser parser dflags fileName s of
    GHC.PFailed ss m                    -> Left (ss, GHC.showSDoc dflags m)
    GHC.POk (mkApiAnns -> apianns) pmod -> Right (as, pmod)
      where as = relativiseApiAnns pmod apianns

parseDeclWith ::
             GHC.DynFlags
          -> FilePath
          -> GHC.P (GHC.LHsDecl GHC.RdrName)
          -> String
          -> Either (GHC.SrcSpan, String) (Anns, GHC.LHsDecl GHC.RdrName)
parseDeclWith dflags fileName parser s =
  case runParser parser dflags fileName s of
    GHC.PFailed ss m                    -> Left (ss, GHC.showSDoc dflags m)
    GHC.POk (mkApiAnns -> apianns) pmod -> Right (as, pmod)
      where as = relativiseApiAnnsLhsDecl pmod apianns

-- ---------------------------------------------------------------------

runParser :: GHC.P a -> GHC.DynFlags -> FilePath -> String -> GHC.ParseResult a
runParser parser flags filename str = GHC.unP parser parseState
    where
      location = GHC.mkRealSrcLoc (GHC.mkFastString filename) 1 1
      buffer = GHC.stringToStringBuffer str
      parseState = GHC.mkPState flags buffer location

-- ---------------------------------------------------------------------

-- | Provides a safe way to consume a properly initialised set of
-- 'DynFlags'.
--
-- @
-- myParser fname expr = withDynFlags (\\d -> parseExpr d fname expr)
-- @
withDynFlags :: (GHC.DynFlags -> a) -> IO a
withDynFlags action =
    GHC.defaultErrorHandler GHC.defaultFatalMessager GHC.defaultFlushOut $
      GHC.runGhc (Just libdir) $ do
        dflags <- GHC.getSessionDynFlags
        void $ GHC.setSessionDynFlags dflags
        return (action dflags)

-- ---------------------------------------------------------------------

parseFile :: GHC.DynFlags -> FilePath -> String -> GHC.ParseResult (GHC.Located (GHC.HsModule GHC.RdrName))
parseFile = runParser GHC.parseModule

-- ---------------------------------------------------------------------

type Parser a = GHC.DynFlags -> FilePath -> String
                -> Either (GHC.SrcSpan, String)
                          (Anns, a)

parseExpr :: Parser (GHC.LHsExpr GHC.RdrName)
parseExpr df fp = parseWith df fp GHC.parseExpression

parseImport :: Parser (GHC.LImportDecl GHC.RdrName)
parseImport df fp = parseWith df fp GHC.parseImport

parseType :: Parser (GHC.LHsType GHC.RdrName)
parseType df fp = parseWith df fp GHC.parseType

-- safe, see D1007
parseDecl :: Parser (GHC.LHsDecl GHC.RdrName)
#if __GLASGOW_HASKELL__ <= 710
parseDecl df fp = parseDeclWith df fp (head . OL.fromOL <$> GHC.parseDeclaration)
#else
parseDecl df fp = parseDeclWith df fp GHC.parseDeclaration
#endif

parseStmt :: Parser (GHC.ExprLStmt GHC.RdrName)
parseStmt df fp = parseWith df fp GHC.parseStatement

parsePattern :: Parser (GHC.LPat GHC.RdrName)
parsePattern df fp = parseWith df fp GHC.parsePattern

-- ---------------------------------------------------------------------
--

-- | This entry point will also work out which language extensions are
-- required and perform CPP processing if necessary.
--
-- @
-- parseModule = parseModuleWithCpp defaultCppOptions
-- @
--
-- Note: 'GHC.ParsedSource' is a synonym for @Located (HsModule RdrName)@
parseModule :: FilePath -> IO (Either (GHC.SrcSpan, String) (Anns, (GHC.Located (GHC.HsModule GHC.RdrName))))
parseModule = parseModuleWithCpp defaultCppOptions

-- | Parse a module with specific instructions for the C pre-processor.
parseModuleWithCpp :: CppOptions
                   -> FilePath
                   -> IO (Either (GHC.SrcSpan, String) (Anns, GHC.Located (GHC.HsModule GHC.RdrName)))
parseModuleWithCpp cppOptions file =
  GHC.defaultErrorHandler GHC.defaultFatalMessager GHC.defaultFlushOut $
    GHC.runGhc (Just libdir) $ do
      dflags <- initDynFlags file
      let useCpp = GHC.xopt GHC.Opt_Cpp dflags
      (fileContents, injectedComments) <-
        if useCpp
          then do
            contents <- getPreprocessedSrcDirect cppOptions file
            cppComments <- getCppTokensAsComments cppOptions file
            return (contents,cppComments)
          else do
            txt <- GHC.liftIO $ readFile file
            let (contents1,lp) = stripLinePragmas txt
            return (contents1,lp)
      return $
        case parseFile dflags file fileContents of
          GHC.PFailed ss m -> Left $ (ss, (GHC.showSDoc dflags m))
          GHC.POk (mkApiAnns -> apianns) pmod  ->
            let as = relativiseApiAnnsWithComments injectedComments pmod apianns in
            Right $ (as, pmod)

-- ---------------------------------------------------------------------

initDynFlags :: GHC.GhcMonad m => FilePath -> m GHC.DynFlags
initDynFlags file = do
  dflags0 <- GHC.getSessionDynFlags
  let dflags1 = GHC.gopt_set dflags0 GHC.Opt_KeepRawTokenStream
  src_opts <- GHC.liftIO $ GHC.getOptionsFromFile dflags1 file
  (dflags2, _, _)
    <- GHC.parseDynamicFilePragma dflags1 src_opts
  void $ GHC.setSessionDynFlags dflags2
  return dflags2

-- ---------------------------------------------------------------------

mkApiAnns :: GHC.PState -> GHC.ApiAnns
mkApiAnns pstate
  = ( Map.fromListWith (++) . GHC.annotations $ pstate
    , Map.fromList ((GHC.noSrcSpan, GHC.comment_q pstate) : (GHC.annotations_comments pstate)))
