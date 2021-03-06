
module Main (main) where

import qualified Distribution.ModuleName as ModuleName
import Distribution.PackageDescription
import Distribution.PackageDescription.Check hiding (doesFileExist)
import Distribution.PackageDescription.Configuration
import Distribution.PackageDescription.Parse
import Distribution.Simple
import Distribution.Simple.Configure
import Distribution.Simple.LocalBuildInfo
import Distribution.Simple.Program
import Distribution.Simple.Program.HcPkg
import Distribution.Simple.Utils (defaultPackageDesc, writeFileAtomic, toUTF8)
import Distribution.Simple.Build (writeAutogenFiles)
import Distribution.Simple.Register
import Distribution.Text
import Distribution.Verbosity
import qualified Distribution.InstalledPackageInfo as Installed
import qualified Distribution.Simple.PackageIndex as PackageIndex

import Data.List
import Data.Maybe
import System.IO
import System.Directory
import System.Environment
import System.Exit
import System.FilePath

main :: IO ()
main = do hSetBuffering stdout LineBuffering
          args <- getArgs
          case args of
              "hscolour" : distDir : dir : args' ->
                  runHsColour distDir dir args'
              "check" : dir : [] ->
                  doCheck dir
              "install" : ghc : ghcpkg : strip : topdir : directory : distDir
                        : myDestDir : myPrefix : myLibdir : myDocdir
                        : relocatableBuild : args' ->
                  doInstall ghc ghcpkg strip topdir directory distDir
                            myDestDir myPrefix myLibdir myDocdir
                            relocatableBuild args'
              "configure" : args' -> case break (== "--") args' of
                   (config_args, "--" : distdir : directories) ->
                       mapM_ (generate config_args distdir) directories
                   _ -> die syntax_error
              "sdist" : dir : distDir : [] ->
                  doSdist dir distDir
              ["--version"] ->
                  defaultMainArgs ["--version"]
              _ -> die syntax_error

syntax_error :: [String]
syntax_error =
    ["syntax: ghc-cabal configure <configure-args> -- <distdir> <directory>...",
     "        ghc-cabal install <ghc-pkg> <directory> <distdir> <destdir> <prefix> <args>...",
     "        ghc-cabal hscolour <distdir> <directory> <args>..."]

die :: [String] -> IO a
die errs = do mapM_ (hPutStrLn stderr) errs
              exitWith (ExitFailure 1)

-- XXX Should use bracket
withCurrentDirectory :: FilePath -> IO a -> IO a
withCurrentDirectory directory io
 = do curDirectory <- getCurrentDirectory
      setCurrentDirectory directory
      r <- io
      setCurrentDirectory curDirectory
      return r

-- We need to use the autoconfUserHooks, as the packages that use
-- configure can create a .buildinfo file, and we need any info that
-- ends up in it.
userHooks :: UserHooks
userHooks = autoconfUserHooks

runDefaultMain :: IO ()
runDefaultMain
 = do let verbosity = normal
      gpdFile <- defaultPackageDesc verbosity
      gpd <- readPackageDescription verbosity gpdFile
      case buildType (flattenPackageDescription gpd) of
          Just Configure -> defaultMainWithHooks autoconfUserHooks
          -- time has a "Custom" Setup.hs, but it's actually Configure
          -- plus a "./Setup test" hook. However, Cabal is also
          -- "Custom", but doesn't have a configure script.
          Just Custom ->
              do configureExists <- doesFileExist "configure"
                 if configureExists
                     then defaultMainWithHooks autoconfUserHooks
                     else defaultMain
          -- not quite right, but good enough for us:
          _ -> defaultMain

doSdist :: FilePath -> FilePath -> IO ()
doSdist directory distDir
 = withCurrentDirectory directory
 $ withArgs (["sdist", "--builddir", distDir])
            runDefaultMain

doCheck :: FilePath -> IO ()
doCheck directory
 = withCurrentDirectory directory
 $ do let verbosity = normal
      gpdFile <- defaultPackageDesc verbosity
      gpd <- readPackageDescription verbosity gpdFile
      case partition isFailure $ checkPackage gpd Nothing of
          ([],   [])       -> return ()
          ([],   warnings) -> mapM_ print warnings
          (errs, _)        -> do mapM_ print errs
                                 exitWith (ExitFailure 1)
    where isFailure (PackageDistSuspicious {}) = False
          isFailure _ = True

runHsColour :: FilePath -> FilePath -> [String] -> IO ()
runHsColour distdir directory args
 = withCurrentDirectory directory
 $ defaultMainArgs ("hscolour" : "--builddir" : distdir : args)

doInstall :: FilePath -> FilePath -> FilePath -> FilePath -> FilePath
          -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath
          -> String -> [String]
          -> IO ()
doInstall ghc ghcpkg strip topdir directory distDir
          myDestDir myPrefix myLibdir myDocdir
          relocatableBuildStr args
 = withCurrentDirectory directory $ do
     relocatableBuild <- case relocatableBuildStr of
                         "YES" -> return True
                         "NO"  -> return False
                         _ -> die ["Bad relocatableBuildStr: " ++
                                   show relocatableBuildStr]
     let copyArgs = ["copy", "--builddir", distDir]
                 ++ (if null myDestDir
                     then []
                     else ["--destdir", myDestDir])
                 ++ args
         regArgs = "register" : "--builddir" : distDir : args
         copyHooks = userHooks {
                         copyHook = noGhcPrimHook
                                  $ modHook False
                                  $ copyHook userHooks
                     }
         regHooks = userHooks {
                        regHook = modHook relocatableBuild
                                $ regHook userHooks
                    }

     defaultMainWithHooksArgs copyHooks copyArgs
     defaultMainWithHooksArgs regHooks  regArgs
    where
      noGhcPrimHook f pd lbi us flags
              = let pd'
                     | packageName pd == PackageName "ghc-prim" =
                        case library pd of
                        Just lib ->
                            let ghcPrim = fromJust (simpleParse "GHC.Prim")
                                ems = filter (ghcPrim /=) (exposedModules lib)
                                lib' = lib { exposedModules = ems }
                            in pd { library = Just lib' }
                        Nothing ->
                            error "Expected a library, but none found"
                     | otherwise = pd
                in f pd' lbi us flags
      modHook relocatableBuild f pd lbi us flags
       = do let verbosity = normal
                idts = installDirTemplates lbi
                idts' = idts {
                            prefix    = toPathTemplate $
                                            if relocatableBuild
                                            then "$topdir"
                                            else myPrefix,
                            libdir    = toPathTemplate $
                                            if relocatableBuild
                                            then "$topdir"
                                            else myLibdir,
                            libsubdir = toPathTemplate "$pkgid",
                            docdir    = toPathTemplate $
                                            if relocatableBuild
                                            then "$topdir/../doc/html/libraries/$pkgid"
                                            else (myDocdir </> "$pkgid"),
                            htmldir   = toPathTemplate "$docdir"
                        }
                progs = withPrograms lbi
                ghcProg = ConfiguredProgram {
                              programId = programName ghcProgram,
                              programVersion = Nothing,
                              programDefaultArgs = ["-B" ++ topdir],
                              programOverrideArgs = [],
                              programLocation = UserSpecified ghc
                          }
                ghcpkgconf = topdir </> "package.conf.d"
                ghcPkgProg = ConfiguredProgram {
                                 programId = programName ghcPkgProgram,
                                 programVersion = Nothing,
                                 programDefaultArgs = ["--global-conf",
                                                       ghcpkgconf]
                                               ++ if not (null myDestDir)
                                                  then ["--force"]
                                                  else [],
                                 programOverrideArgs = [],
                                 programLocation = UserSpecified ghcpkg
                             }
                stripProg = ConfiguredProgram {
                              programId = programName stripProgram,
                              programVersion = Nothing,
                              programDefaultArgs = [],
                              programOverrideArgs = [],
                              programLocation = UserSpecified strip
                          }
                progs' = updateProgram ghcProg
                       $ updateProgram ghcPkgProg
                       $ updateProgram stripProg
                         progs
            instInfos <- dump verbosity ghcPkgProg GlobalPackageDB
            let installedPkgs' = PackageIndex.fromList instInfos
            let mlc = libraryConfig lbi
                mlc' = case mlc of
                       Just lc ->
                           let cipds = componentPackageDeps lc
                               cipds' = [ (fixupPackageId instInfos ipid, pid)
                                        | (ipid,pid) <- cipds ]
                           in Just $ lc {
                                         componentPackageDeps = cipds'
                                     }
                       Nothing -> Nothing
                lbi' = lbi {
                               libraryConfig = mlc',
                               installedPkgs = installedPkgs',
                               installDirTemplates = idts',
                               withPrograms = progs'
                           }
            f pd lbi' us flags

-- The packages are built with the package ID ending in "-inplace", but
-- when they're installed they get the package hash appended. We need to
-- fix up the package deps so that they use the hash package IDs, not
-- the inplace package IDs.
fixupPackageId :: [Installed.InstalledPackageInfo]
               -> InstalledPackageId
               -> InstalledPackageId
fixupPackageId _ x@(InstalledPackageId ipi)
 | "builtin_" `isPrefixOf` ipi = x
fixupPackageId ipinfos (InstalledPackageId ipi)
 = case stripPrefix (reverse "-inplace") $ reverse ipi of
   Nothing ->
       error ("Installed package ID doesn't end in -inplace: " ++ show ipi)
   Just x ->
       let ipi' = reverse ('-' : x)
           f (ipinfo : ipinfos') = case Installed.installedPackageId ipinfo of
                                   y@(InstalledPackageId ipinfoid)
                                    | ipi' `isPrefixOf` ipinfoid ->
                                       y
                                   _ ->
                                       f ipinfos'
           f [] = error ("Installed package ID not registered: " ++ show ipi)
       in f ipinfos

generate :: [String] -> FilePath -> FilePath -> IO ()
generate config_args distdir directory
 = withCurrentDirectory directory
 $ do let verbosity = normal
      -- XXX We shouldn't just configure with the default flags
      -- XXX And this, and thus the "getPersistBuildConfig distdir" below,
      -- aren't going to work when the deps aren't built yet
      withArgs (["configure", "--distdir", distdir] ++ config_args)
               runDefaultMain

      lbi <- getPersistBuildConfig distdir
      let pd0 = localPkgDescr lbi

      hooked_bi <-
           if (buildType pd0 == Just Configure) || (buildType pd0 == Just Custom)
           then do
              maybe_infoFile <- defaultHookedPackageDesc
              case maybe_infoFile of
                  Nothing       -> return emptyHookedBuildInfo
                  Just infoFile -> readHookedBuildInfo verbosity infoFile
           else
              return emptyHookedBuildInfo

      let pd = updatePackageDescription hooked_bi pd0

      -- generate Paths_<pkg>.hs and cabal-macros.h
      writeAutogenFiles verbosity pd lbi

      -- generate inplace-pkg-config
      case (library pd, libraryConfig lbi) of
          (Nothing, Nothing) -> return ()
          (Just lib, Just clbi) -> do
              cwd <- getCurrentDirectory
              let ipid = InstalledPackageId (display (packageId pd) ++ "-inplace")
              let installedPkgInfo = inplaceInstalledPackageInfo cwd distdir
                                         pd lib lbi clbi
                  final_ipi = installedPkgInfo {
                                  Installed.installedPackageId = ipid,
                                  Installed.haddockHTMLs = ["../" ++ display (packageId pd)]
                              }
                  content = Installed.showInstalledPackageInfo final_ipi ++ "\n"
              writeFileAtomic (distdir </> "inplace-pkg-config") (toUTF8 content)
          _ -> error "Inconsistent lib components; can't happen?"

      let
          libBiModules lib = (libBuildInfo lib, libModules lib)
          exeBiModules exe = (buildInfo exe, ModuleName.main : exeModules exe)
          biModuless = (maybeToList $ fmap libBiModules $ library pd)
                    ++ (map exeBiModules $ executables pd)
          buildableBiModuless = filter isBuildable biModuless
              where isBuildable (bi', _) = buildable bi'
          (bi, modules) = case buildableBiModuless of
                          [] -> error "No buildable component found"
                          [biModules] -> biModules
                          _ -> error ("XXX ghc-cabal can't handle " ++
                                      "more than one buildinfo yet")
          -- XXX Another Just...
          Just ghcProg = lookupProgram ghcProgram (withPrograms lbi)

          dep_pkgs = PackageIndex.topologicalOrder (packageHacks (installedPkgs lbi))
          forDeps f = concatMap f dep_pkgs

          -- copied from Distribution.Simple.PreProcess.ppHsc2Hs
          packageHacks = case compilerFlavor (compiler lbi) of
            GHC -> hackRtsPackage
            _   -> id
          -- We don't link in the actual Haskell libraries of our
          -- dependencies, so the -u flags in the ldOptions of the rts
          -- package mean linking fails on OS X (it's ld is a tad
          -- stricter than gnu ld). Thus we remove the ldOptions for
          -- GHC's rts package:
          hackRtsPackage index =
            case PackageIndex.lookupPackageName index (PackageName "rts") of
              [(_,[rts])] ->
                 PackageIndex.insert rts{
                     Installed.ldOptions = [],
                     Installed.libraryDirs = filter (not . ("gcc-lib" `isSuffixOf`)) (Installed.libraryDirs rts)} index
                        -- GHC <= 6.12 had $topdir/gcc-lib in their
                        -- library-dirs for the rts package, which causes
                        -- problems when we try to use the in-tree mingw,
                        -- due to accidentally picking up the incompatible
                        -- libraries there.  So we filter out gcc-lib from
                        -- the RTS's library-dirs here.
              _ -> error "No (or multiple) ghc rts package is registered!!"

          dep_ids = map snd (externalPackageDeps lbi)

      wrappedIncludeDirs <- wrap $ forDeps Installed.includeDirs
      wrappedLibraryDirs <- wrap $ forDeps Installed.libraryDirs

      let variablePrefix = directory ++ '_':distdir
      let xs = [variablePrefix ++ "_VERSION = " ++ display (pkgVersion (package pd)),
                variablePrefix ++ "_MODULES = " ++ unwords (map display modules),
                variablePrefix ++ "_HIDDEN_MODULES = " ++ unwords (map display (otherModules bi)),
                variablePrefix ++ "_SYNOPSIS =" ++ synopsis pd,
                variablePrefix ++ "_HS_SRC_DIRS = " ++ unwords (hsSourceDirs bi),
                variablePrefix ++ "_DEPS = " ++ unwords (map display dep_ids),
                variablePrefix ++ "_DEP_NAMES = " ++ unwords (map (display . packageName) dep_ids),
                variablePrefix ++ "_INCLUDE_DIRS = " ++ unwords (includeDirs bi),
                variablePrefix ++ "_INCLUDES = " ++ unwords (includes bi),
                variablePrefix ++ "_INSTALL_INCLUDES = " ++ unwords (installIncludes bi),
                variablePrefix ++ "_EXTRA_LIBRARIES = " ++ unwords (extraLibs bi),
                variablePrefix ++ "_EXTRA_LIBDIRS = " ++ unwords (extraLibDirs bi),
                variablePrefix ++ "_C_SRCS  = " ++ unwords (cSources bi),
                variablePrefix ++ "_CMM_SRCS  := $(addprefix cbits/,$(notdir $(wildcard " ++ directory ++ "/cbits/*.cmm)))",
                variablePrefix ++ "_DATA_FILES = "    ++ unwords (dataFiles pd),
                -- XXX This includes things it shouldn't, like:
                -- -odir dist-bootstrapping/build
                variablePrefix ++ "_HC_OPTS = " ++ escape (unwords
                       (   programDefaultArgs ghcProg
                        ++ hcOptions GHC bi
                        ++ languageToFlags (compiler lbi) (defaultLanguage bi)
                        ++ extensionsToFlags (compiler lbi) (usedExtensions bi)
                        ++ programOverrideArgs ghcProg)),
                variablePrefix ++ "_CC_OPTS = "                        ++ unwords (ccOptions bi),
                variablePrefix ++ "_CPP_OPTS = "                       ++ unwords (cppOptions bi),
                variablePrefix ++ "_LD_OPTS = "                        ++ unwords (ldOptions bi),
                variablePrefix ++ "_DEP_INCLUDE_DIRS_SINGLE_QUOTED = " ++ unwords wrappedIncludeDirs,
                variablePrefix ++ "_DEP_CC_OPTS = "                    ++ unwords (forDeps Installed.ccOptions),
                variablePrefix ++ "_DEP_LIB_DIRS_SINGLE_QUOTED = "     ++ unwords wrappedLibraryDirs,
                variablePrefix ++ "_DEP_EXTRA_LIBS = "                 ++ unwords (forDeps Installed.extraLibraries),
                variablePrefix ++ "_DEP_LD_OPTS = "                    ++ unwords (forDeps Installed.ldOptions),
                variablePrefix ++ "_BUILD_GHCI_LIB = "                 ++ boolToYesNo (withGHCiLib lbi),
                "",
                -- Sometimes we need to modify the automatically-generated package-data.mk
                -- bindings in a special way for the GHC build system, so allow that here:
                "$(eval $(" ++ directory ++ "_PACKAGE_MAGIC))"
                ]
      writeFile (distdir ++ "/package-data.mk") $ unlines xs
      writeFile (distdir ++ "/haddock-prologue.txt") $
          if null (description pd) then synopsis pd
                                   else description pd
  where
     escape = foldr (\c xs -> if c == '#' then '\\':'#':xs else c:xs) []
     wrap = mapM wrap1
     wrap1 s
      | null s        = die ["Wrapping empty value"]
      | '\'' `elem` s = die ["Single quote in value to be wrapped:", s]
      -- We want to be able to assume things like <space><quote> is the
      -- start of a value, so check there are no spaces in confusing
      -- positions
      | head s == ' ' = die ["Leading space in value to be wrapped:", s]
      | last s == ' ' = die ["Trailing space in value to be wrapped:", s]
      | otherwise     = return ("\'" ++ s ++ "\'")
     boolToYesNo True = "YES"
     boolToYesNo False = "NO"

