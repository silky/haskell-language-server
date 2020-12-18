{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TypeFamilies      #-}
{-# LANGUAGE ViewPatterns      #-}
module Ide.Plugin.Class
  ( descriptor
  ) where

import           BooleanFormula
import           Class
import           ConLike
import           Control.Applicative
import           Control.Lens hiding (List, use)
import           Control.Monad
import           Data.Aeson
import           Data.Char
import qualified Data.HashMap.Strict as H
import           Data.List
import qualified Data.Map.Strict as Map
import           Data.Maybe
import qualified Data.Text as T
import           Development.IDE
import           Development.IDE.Core.PositionMapping (fromCurrentRange, toCurrentRange)
import           Development.IDE.GHC.Compat hiding (getLoc)
import           Development.IDE.Spans.AtPoint
import qualified GHC.Generics as Generics
import           GhcPlugins hiding (Var, getLoc, (<>))
import           Ide.Plugin
import           Ide.PluginUtils
import           Ide.Types
import           Language.Haskell.GHC.ExactPrint
import           Language.Haskell.GHC.ExactPrint.Parsers (parseDecl)
import           Language.Haskell.GHC.ExactPrint.Types hiding (GhcPs, Parens)
import           Language.Haskell.LSP.Core
import           Language.Haskell.LSP.Types
import qualified Language.Haskell.LSP.Types.Lens as J
import           SrcLoc
import           TcEnv
import           TcRnMonad

descriptor :: PluginId -> PluginDescriptor
descriptor plId = (defaultPluginDescriptor plId)
  { pluginCommands = commands
  , pluginCodeActionProvider = Just codeAction
  }

commands :: [PluginCommand]
commands
  = [ PluginCommand "addMinimalMethodPlaceholders" "add placeholders for minimal methods" addMethodPlaceholders
    ]

-- | Parameter for the addMethods PluginCommand.
data AddMinimalMethodsParams = AddMinimalMethodsParams
  { uri         :: Uri
  , range       :: Range
  , methodGroup :: List T.Text
  }
  deriving (Show, Eq, Generics.Generic, ToJSON, FromJSON)

addMethodPlaceholders :: CommandFunction AddMinimalMethodsParams
addMethodPlaceholders lf state AddMinimalMethodsParams{..} = do
  Just pm <- runAction "classplugin" state $ use GetParsedModule docPath
  let
    ps = pm_parsed_source pm
    anns = relativiseApiAnns ps (pm_annotations pm)
    old = T.pack $ exactPrint ps anns

  Just (hsc_dflags . hscEnv -> df) <- runAction "classplugin" state $ use GhcSessionDeps docPath
  let
    Right (List (unzip -> (mAnns, mDecls))) = traverse (makeMethodDecl df) methodGroup
    (ps', (anns', _), _) = runTransform (mergeAnns (mergeAnnList mAnns) anns) (addMethodDecls ps mDecls)
    new = T.pack $ exactPrint ps' anns'

  pure (Right Null, Just (WorkspaceApplyEdit, ApplyWorkspaceEditParams (workspaceEdit caps old new)))
  where
    caps = clientCapabilities lf
    Just docPath = uriToNormalizedFilePath $ toNormalizedUri uri

    indent = 2

    makeMethodDecl df mName  = do
      (ann, d) <- parseDecl df (T.unpack mName) . T.unpack $ toMethodName mName <> " = _"
      pure (setPrecedingLines d 1 indent ann, d)

    addMethodDecls :: ParsedSource -> [LHsDecl GhcPs] -> Transform (Located (HsModule GhcPs))
    addMethodDecls ps mDecls = do
      d <- findInstDecl ps
      newSpan <- uniqueSrcSpanT
      let
        newAnnKey = AnnKey newSpan (CN "HsValBinds")
        addWhere mkds@(Map.lookup (mkAnnKey d) -> Just ann)
          = Map.insert newAnnKey ann2 mkds2
          where
            annKey = mkAnnKey d
            ann1 = ann
                   { annsDP = annsDP ann ++ [(G AnnWhere, DP (0, 1))]
                   , annCapturedSpan = Just newAnnKey
                   , annSortKey = Just (fmap getLoc mDecls)
                   }
            mkds2 = Map.insert annKey ann1 mkds
            ann2 = annNone
                   { annEntryDelta = DP (1, 2)
                   }
        addWhere _ = panic "Ide.Plugin.Class.addMethodPlaceholder"
      modifyAnnsT addWhere
      modifyAnnsT (captureOrderAnnKey newAnnKey mDecls)
      foldM (insertAfter d) ps (reverse mDecls)

    findInstDecl :: ParsedSource -> Transform (LHsDecl GhcPs)
    findInstDecl ps = head . filter (containRange range . getLoc) <$> hsDecls ps

    workspaceEdit caps old new
      = diffText caps (uri, old) new IncludeDeletions

    toMethodName n
      | Just (h, _) <- T.uncons n
      , not (isAlpha h)
      = "(" <> n <> ")"
      | otherwise
      = n

-- | This implementation is extremely ad-hoc in a sense that
-- 1. sensitive to the format of diagnostic messages from GHC
-- 2. pattern matches are not exhaustive
codeAction :: CodeActionProvider
codeAction _ state plId (TextDocumentIdentifier uri) _ CodeActionContext{ _diagnostics = List diags } = do
  actions <- join <$> mapM mkActions methodDiags
  pure . Right . List $ actions
  where
    Just docPath = uriToNormalizedFilePath $ toNormalizedUri uri

    ghcDiags = filter (\d -> d ^. J.source == Just "typecheck") diags
    methodDiags = filter (\d -> isClassMethodWarning (d ^. J.message)) ghcDiags

    mkActions diag = do
      ident <- findClassIdentifier range
      cls <- findClassFromIdentifier ident
      traverse mkAction . minDefToMethodGroups . classMinimalDef $ cls
      where
        range = diag ^. J.range

        mkAction methodGroup
          = mkCodeAction title
            <$> mkLspCommand plId "addMinimalMethodPlaceholders" title (Just cmdParams)
          where
            title = mkTitle methodGroup
            cmdParams = mkCmdParams methodGroup

        mkTitle methodGroup
          = "Add placeholders for "
          <> mconcat (intersperse ", " (fmap (\m -> "'" <> m <> "'") methodGroup))

        mkCmdParams methodGroup = [toJSON (AddMinimalMethodsParams uri range (List methodGroup))]

        mkCodeAction title
          = CACodeAction
          . CodeAction title (Just CodeActionQuickFix) (Just (List [])) Nothing
          . Just

    findClassIdentifier :: Range -> IO Identifier
    findClassIdentifier range = do
      Just (hieAst -> hf, pmap) <- runAction "classplugin" state $ useWithStale GetHieAst docPath
      pure
        $ head . head
        $ pointCommand hf (fromJust (fromCurrentRange pmap range) ^. J.start & J.character -~ 1)
          ( (Map.keys . Map.filter isClassNodeIdentifier . nodeIdentifiers . nodeInfo)
            <=< nodeChildren
          )

    findClassFromIdentifier :: Identifier -> IO Class
    findClassFromIdentifier (Right name) = do
      Just (hscEnv -> hscenv, _) <- runAction "classplugin" state $ useWithStale GhcSessionDeps docPath
      Just (tmrTypechecked -> thisMod, _) <- runAction "classplugin" state $ useWithStale TypeCheck docPath
      (_, Just cls) <- initTcWithGbl hscenv thisMod ghostSpan $ do
        tcthing <- tcLookup name
        case tcthing of
          AGlobal (AConLike (RealDataCon con))
            | Just cls <- tyConClass_maybe (dataConOrigTyCon con) -> pure cls
          _ -> panic "Ide.Plugin.Class.findClassFromIdentifier"
      pure cls
    findClassFromIdentifier (Left _) = panic "Ide.Plugin.Class.findClassIdentifier"

ghostSpan :: RealSrcSpan
ghostSpan = realSrcLocSpan $ mkRealSrcLoc (fsLit "<haskell-language-sever>") 1 1

containRange :: Range -> SrcSpan -> Bool
containRange range x = isInsideSrcSpan (range ^. J.start) x || isInsideSrcSpan (range ^. J.end) x

isClassNodeIdentifier :: IdentifierDetails a -> Bool
isClassNodeIdentifier = isNothing . identType

isClassMethodWarning :: T.Text -> Bool
isClassMethodWarning = T.isPrefixOf "• No explicit implementation for"

minDefToMethodGroups :: BooleanFormula Name -> [[T.Text]]
minDefToMethodGroups = go
  where
    go (Var mn) = [[T.pack . occNameString . occName $ mn]]
    go (Or ms) = concatMap (go . unLoc) ms
    go (And ms) = foldr (liftA2 (<>)) [[]] (fmap (go . unLoc) ms)
    go (Parens m) = go (unLoc m)
