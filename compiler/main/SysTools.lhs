-----------------------------------------------------------------------------
--
-- (c) The University of Glasgow 2001-2003
--
-- Access to system tools: gcc, cp, rm etc
--
-----------------------------------------------------------------------------

\begin{code}
{-# OPTIONS -fno-warn-unused-do-bind #-}
module SysTools (
        -- Initialisation
        initSysTools,

        -- Interface to system tools
        runUnlit, runCpp, runCc, -- [Option] -> IO ()
        runPp,                   -- [Option] -> IO ()
        runSplit,                -- [Option] -> IO ()
        runAs, runLink,          -- [Option] -> IO ()
        runMkDLL,
        runWindres,
        runLlvmOpt,
        runLlvmLlc,
        readElfSection,

        touch,                  -- String -> String -> IO ()
        copy,
        copyWithHeader,

        -- Temporary-file management
        setTmpDir,
        newTempName,
        cleanTempDirs, cleanTempFiles, cleanTempFilesExcept,
        addFilesToClean,

        Option(..)

 ) where

#include "HsVersions.h"

import DriverPhases
import Config
import Outputable
import ErrUtils
import Panic
import Util
import DynFlags
import StaticFlags
import Exception

import Data.IORef
import Control.Monad
import System.Exit
import System.Environment
import System.FilePath
import System.IO
import System.IO.Error as IO
import System.Directory
import Data.Char
import Data.List
import qualified Data.Map as Map
import Text.ParserCombinators.ReadP hiding (char)
import qualified Text.ParserCombinators.ReadP as R

#ifndef mingw32_HOST_OS
import qualified System.Posix.Internals
#else /* Must be Win32 */
import Foreign
import Foreign.C.String
#endif

import System.Process
import Control.Concurrent
import FastString
import SrcLoc           ( SrcLoc, mkSrcLoc, noSrcSpan, mkSrcSpan )
\end{code}

How GHC finds its files
~~~~~~~~~~~~~~~~~~~~~~~

[Note topdir]

GHC needs various support files (library packages, RTS etc), plus
various auxiliary programs (cp, gcc, etc).  It starts by finding topdir,
the root of GHC's support files

On Unix:
  - ghc always has a shell wrapper that passes a -B<dir> option

On Windows:
  - ghc never has a shell wrapper.
  - we can find the location of the ghc binary, which is
        $topdir/bin/<something>.exe
    where <something> may be "ghc", "ghc-stage2", or similar
  - we strip off the "bin/<something>.exe" to leave $topdir.

from topdir we can find package.conf, ghc-asm, etc.


SysTools.initSysProgs figures out exactly where all the auxiliary programs
are, and initialises mutable variables to make it easy to call them.
To to this, it makes use of definitions in Config.hs, which is a Haskell
file containing variables whose value is figured out by the build system.

Config.hs contains two sorts of things

  cGCC,         The *names* of the programs
  cCPP            e.g.  cGCC = gcc
  cUNLIT                cCPP = gcc -E
  etc           They do *not* include paths


  cUNLIT_DIR   The *path* to the directory containing unlit, split etc
  cSPLIT_DIR   *relative* to the root of the build tree,
                   for use when running *in-place* in a build tree (only)



---------------------------------------------
NOTES for an ALTERNATIVE scheme (i.e *not* what is currently implemented):

Another hair-brained scheme for simplifying the current tool location
nightmare in GHC: Simon originally suggested using another
configuration file along the lines of GCC's specs file - which is fine
except that it means adding code to read yet another configuration
file.  What I didn't notice is that the current package.conf is
general enough to do this:

Package
    {name = "tools",    import_dirs = [],  source_dirs = [],
     library_dirs = [], hs_libraries = [], extra_libraries = [],
     include_dirs = [], c_includes = [],   package_deps = [],
     extra_ghc_opts = ["-pgmc/usr/bin/gcc","-pgml${topdir}/bin/unlit", ... etc.],
     extra_cc_opts = [], extra_ld_opts = []}

Which would have the advantage that we get to collect together in one
place the path-specific package stuff with the path-specific tool
stuff.
                End of NOTES
---------------------------------------------

%************************************************************************
%*                                                                      *
\subsection{Initialisation}
%*                                                                      *
%************************************************************************

\begin{code}
initSysTools :: Maybe String    -- Maybe TopDir path (without the '-B' prefix)
             -> IO Settings     -- Set all the mutable variables above, holding
                                --      (a) the system programs
                                --      (b) the package-config file
                                --      (c) the GHC usage message
initSysTools mbMinusB
  = do  { top_dir <- findTopDir mbMinusB
                -- see [Note topdir]
                -- NB: top_dir is assumed to be in standard Unix
                -- format, '/' separated

        ; let settingsFile = top_dir </> "settings"
        ; settingsStr <- readFile settingsFile
        ; mySettings <- case maybeReadFuzzy settingsStr of
                        Just s ->
                            return s
                        Nothing ->
                            pgmError ("Can't parse " ++ show settingsFile)
        ; let getSetting key = case lookup key mySettings of
                               Just xs ->
                                   return xs
                               Nothing -> pgmError ("No entry for " ++ show key ++ " in " ++ show settingsFile)
        ; myExtraGccViaCFlags <- getSetting "GCC extra via C opts"

        ; let installed :: FilePath -> FilePath
              installed file = top_dir </> file
              installed_mingw_bin file = top_dir </> ".." </> "mingw" </> "bin" </> file
              installed_perl_bin file = top_dir </> ".." </> "perl" </> file

        ; let pkgconfig_path = installed "package.conf.d"
              ghc_usage_msg_path  = installed "ghc-usage.txt"
              ghci_usage_msg_path = installed "ghci-usage.txt"

                -- For all systems, unlit, split, mangle are GHC utilities
                -- architecture-specific stuff is done when building Config.hs
              unlit_path = installed cGHC_UNLIT_PGM

                -- split is a Perl script
              split_script  = installed cGHC_SPLIT_PGM

              windres_path  = installed_mingw_bin "windres"

        ; tmpdir <- getTemporaryDirectory

        -- On Windows, mingw is distributed with GHC,
        --      so we look in TopDir/../mingw/bin
        ; let
              gcc_prog
                | isWindowsHost = installed_mingw_bin "gcc"
                | otherwise     = cGCC
              perl_path
                | isWindowsHost = installed_perl_bin cGHC_PERL
                | otherwise     = cGHC_PERL
              -- 'touch' is a GHC util for Windows
              touch_path
                | isWindowsHost = installed cGHC_TOUCHY_PGM
                | otherwise     = "touch"
              -- On Win32 we don't want to rely on #!/bin/perl, so we prepend
              -- a call to Perl to get the invocation of split.
              -- On Unix, scripts are invoked using the '#!' method.  Binary
              -- installations of GHC on Unix place the correct line on the
              -- front of the script at installation time, so we don't want
              -- to wire-in our knowledge of $(PERL) on the host system here.
              (split_prog,  split_args)
                | isWindowsHost = (perl_path,    [Option split_script])
                | otherwise     = (split_script, [])
              (mkdll_prog, mkdll_args)
                | not isWindowsHost
                    = panic "Can't build DLLs on a non-Win32 system"
                | otherwise =
                    (installed_mingw_bin cMKDLL, [])

        -- cpp is derived from gcc on all platforms
        -- HACK, see setPgmP below. We keep 'words' here to remember to fix
        -- Config.hs one day.
        ; let cpp_path  = (gcc_prog,
                           (Option "-E"):(map Option (words cRAWCPP_FLAGS)))

        -- Other things being equal, as and ld are simply gcc
        ; let   as_prog  = gcc_prog
                ld_prog  = gcc_prog

        -- figure out llvm location. (TODO: Acutally implement).
        ; let lc_prog = "llc"
              lo_prog = "opt"

        ; return $ Settings {
                        sTmpDir = normalise tmpdir,
                        sGhcUsagePath = ghc_usage_msg_path,
                        sGhciUsagePath = ghci_usage_msg_path,
                        sTopDir  = top_dir,
                        sRawSettings = mySettings,
                        sExtraGccViaCFlags = words myExtraGccViaCFlags,
                        sSystemPackageConfig = pkgconfig_path,
                        sPgm_L   = unlit_path,
                        sPgm_P   = cpp_path,
                        sPgm_F   = "",
                        sPgm_c   = (gcc_prog,[]),
                        sPgm_s   = (split_prog,split_args),
                        sPgm_a   = (as_prog,[]),
                        sPgm_l   = (ld_prog,[]),
                        sPgm_dll = (mkdll_prog,mkdll_args),
                        sPgm_T   = touch_path,
                        sPgm_sysman = top_dir ++ "/ghc/rts/parallel/SysMan",
                        sPgm_windres = windres_path,
                        sPgm_lo  = (lo_prog,[]),
                        sPgm_lc  = (lc_prog,[]),
                        -- Hans: this isn't right in general, but you can
                        -- elaborate it in the same way as the others
                        sOpt_L       = [],
                        sOpt_P       = (if opt_PIC
                                        then -- this list gets reversed
                                             ["-D__PIC__", "-U __PIC__"]
                                        else []),
                        sOpt_F       = [],
                        sOpt_c       = [],
                        sOpt_a       = [],
                        sOpt_m       = [],
                        sOpt_l       = [],
                        sOpt_windres = [],
                        sOpt_lo      = [],
                        sOpt_lc      = []
                }
        }
\end{code}

\begin{code}
-- returns a Unix-format path (relying on getBaseDir to do so too)
findTopDir :: Maybe String -- Maybe TopDir path (without the '-B' prefix).
           -> IO String    -- TopDir (in Unix format '/' separated)
findTopDir (Just minusb) = return (normalise minusb)
findTopDir Nothing
    = do -- Get directory of executable
         maybe_exec_dir <- getBaseDir
         case maybe_exec_dir of
             -- "Just" on Windows, "Nothing" on unix
             Nothing  -> ghcError (InstallationError "missing -B<dir> option")
             Just dir -> return dir
\end{code}


%************************************************************************
%*                                                                      *
\subsection{Running an external program}
%*                                                                      *
%************************************************************************


\begin{code}
runUnlit :: DynFlags -> [Option] -> IO ()
runUnlit dflags args = do
  let p = pgm_L dflags
  runSomething dflags "Literate pre-processor" p args

runCpp :: DynFlags -> [Option] -> IO ()
runCpp dflags args =   do
  let (p,args0) = pgm_P dflags
      args1 = args0 ++ args
      args2 = if dopt Opt_WarnIsError dflags
              then Option "-Werror" : args1
              else                    args1
  mb_env <- getGccEnv args2
  runSomethingFiltered dflags id  "C pre-processor" p args2 mb_env

runPp :: DynFlags -> [Option] -> IO ()
runPp dflags args =   do
  let p = pgm_F dflags
  runSomething dflags "Haskell pre-processor" p args

runCc :: DynFlags -> [Option] -> IO ()
runCc dflags args =   do
  let (p,args0) = pgm_c dflags
      args1 = args0 ++ args
  mb_env <- getGccEnv args1
  runSomethingFiltered dflags cc_filter "C Compiler" p args1 mb_env
 where
  -- discard some harmless warnings from gcc that we can't turn off
  cc_filter = unlines . doFilter . lines

  {-
  gcc gives warnings in chunks like so:
      In file included from /foo/bar/baz.h:11,
                       from /foo/bar/baz2.h:22,
                       from wibble.c:33:
      /foo/flibble:14: global register variable ...
      /foo/flibble:15: warning: call-clobbered r...
  We break it up into its chunks, remove any call-clobbered register
  warnings from each chunk, and then delete any chunks that we have
  emptied of warnings.
  -}
  doFilter = unChunkWarnings . filterWarnings . chunkWarnings []
  -- We can't assume that the output will start with an "In file inc..."
  -- line, so we start off expecting a list of warnings rather than a
  -- location stack.
  chunkWarnings :: [String] -- The location stack to use for the next
                            -- list of warnings
                -> [String] -- The remaining lines to look at
                -> [([String], [String])]
  chunkWarnings loc_stack [] = [(loc_stack, [])]
  chunkWarnings loc_stack xs
      = case break loc_stack_start xs of
        (warnings, lss:xs') ->
            case span loc_start_continuation xs' of
            (lsc, xs'') ->
                (loc_stack, warnings) : chunkWarnings (lss : lsc) xs''
        _ -> [(loc_stack, xs)]

  filterWarnings :: [([String], [String])] -> [([String], [String])]
  filterWarnings [] = []
  -- If the warnings are already empty then we are probably doing
  -- something wrong, so don't delete anything
  filterWarnings ((xs, []) : zs) = (xs, []) : filterWarnings zs
  filterWarnings ((xs, ys) : zs) = case filter wantedWarning ys of
                                       [] -> filterWarnings zs
                                       ys' -> (xs, ys') : filterWarnings zs

  unChunkWarnings :: [([String], [String])] -> [String]
  unChunkWarnings [] = []
  unChunkWarnings ((xs, ys) : zs) = xs ++ ys ++ unChunkWarnings zs

  loc_stack_start        s = "In file included from " `isPrefixOf` s
  loc_start_continuation s = "                 from " `isPrefixOf` s
  wantedWarning w
   | "warning: call-clobbered register used" `isContainedIn` w = False
   | otherwise = True

isContainedIn :: String -> String -> Bool
xs `isContainedIn` ys = any (xs `isPrefixOf`) (tails ys)

-- If the -B<dir> option is set, add <dir> to PATH.  This works around
-- a bug in gcc on Windows Vista where it can't find its auxiliary
-- binaries (see bug #1110).
getGccEnv :: [Option] -> IO (Maybe [(String,String)])
getGccEnv opts =
  if null b_dirs
     then return Nothing
     else do env <- getEnvironment
             return (Just (map mangle_path env))
 where
  (b_dirs, _) = partitionWith get_b_opt opts

  get_b_opt (Option ('-':'B':dir)) = Left dir
  get_b_opt other = Right other

  mangle_path (path,paths) | map toUpper path == "PATH"
        = (path, '\"' : head b_dirs ++ "\";" ++ paths)
  mangle_path other = other

runSplit :: DynFlags -> [Option] -> IO ()
runSplit dflags args = do
  let (p,args0) = pgm_s dflags
  runSomething dflags "Splitter" p (args0++args)

runAs :: DynFlags -> [Option] -> IO ()
runAs dflags args = do
  let (p,args0) = pgm_a dflags
      args1 = args0 ++ args
  mb_env <- getGccEnv args1
  runSomethingFiltered dflags id "Assembler" p args1 mb_env

runLlvmOpt :: DynFlags -> [Option] -> IO ()
runLlvmOpt dflags args = do
  let (p,args0) = pgm_lo dflags
  runSomething dflags "LLVM Optimiser" p (args0++args)

runLlvmLlc :: DynFlags -> [Option] -> IO ()
runLlvmLlc dflags args = do
  let (p,args0) = pgm_lc dflags
  runSomething dflags "LLVM Compiler" p (args0++args)

runLink :: DynFlags -> [Option] -> IO ()
runLink dflags args = do
  let (p,args0) = pgm_l dflags
      args1 = args0 ++ args
  mb_env <- getGccEnv args1
  runSomethingFiltered dflags id "Linker" p args1 mb_env

runMkDLL :: DynFlags -> [Option] -> IO ()
runMkDLL dflags args = do
  let (p,args0) = pgm_dll dflags
      args1 = args0 ++ args
  mb_env <- getGccEnv (args0++args)
  runSomethingFiltered dflags id "Make DLL" p args1 mb_env

runWindres :: DynFlags -> [Option] -> IO ()
runWindres dflags args = do
  let (gcc, gcc_args) = pgm_c dflags
      windres = pgm_windres dflags
      quote x = "\"" ++ x ++ "\""
      args' = -- If windres.exe and gcc.exe are in a directory containing
              -- spaces then windres fails to run gcc. We therefore need
              -- to tell it what command to use...
              Option ("--preprocessor=" ++
                      unwords (map quote (gcc :
                                          map showOpt gcc_args ++
                                          ["-E", "-xc", "-DRC_INVOKED"])))
              -- ...but if we do that then if windres calls popen then
              -- it can't understand the quoting, so we have to use
              -- --use-temp-file so that it interprets it correctly.
              -- See #1828.
            : Option "--use-temp-file"
            : args
  mb_env <- getGccEnv gcc_args
  runSomethingFiltered dflags id "Windres" windres args' mb_env

touch :: DynFlags -> String -> String -> IO ()
touch dflags purpose arg =
  runSomething dflags purpose (pgm_T dflags) [FileOption "" arg]

copy :: DynFlags -> String -> FilePath -> FilePath -> IO ()
copy dflags purpose from to = copyWithHeader dflags purpose Nothing from to

copyWithHeader :: DynFlags -> String -> Maybe String -> FilePath -> FilePath
               -> IO ()
copyWithHeader dflags purpose maybe_header from to = do
  showPass dflags purpose

  hout <- openBinaryFile to   WriteMode
  hin  <- openBinaryFile from ReadMode
  ls <- hGetContents hin -- inefficient, but it'll do for now. ToDo: speed up
  maybe (return ()) (hPutStr hout) maybe_header
  hPutStr hout ls
  hClose hout
  hClose hin

-- | read the contents of the named section in an ELF object as a
-- String.
readElfSection :: DynFlags -> String -> FilePath -> IO (Maybe String)
readElfSection _dflags section exe = do
  let
     prog = "readelf"
     args = [Option "-p", Option section, FileOption "" exe]
  --
  r <- readProcessWithExitCode prog (filter notNull (map showOpt args)) ""
  case r of
    (ExitSuccess, out, _err) -> return (doFilter (lines out))
    _ -> return Nothing
 where
  doFilter [] = Nothing
  doFilter (s:r) = case readP_to_S parse s of
                    [(p,"")] -> Just p
                    _r       -> doFilter r
   where parse = do
           skipSpaces; R.char '['; skipSpaces; string "0]"; skipSpaces;
           munch (const True)
\end{code}

%************************************************************************
%*                                                                      *
\subsection{Managing temporary files
%*                                                                      *
%************************************************************************

\begin{code}
cleanTempDirs :: DynFlags -> IO ()
cleanTempDirs dflags
   = unless (dopt Opt_KeepTmpFiles dflags)
   $ do let ref = dirsToClean dflags
        ds <- readIORef ref
        removeTmpDirs dflags (Map.elems ds)
        writeIORef ref Map.empty

cleanTempFiles :: DynFlags -> IO ()
cleanTempFiles dflags
   = unless (dopt Opt_KeepTmpFiles dflags)
   $ do let ref = filesToClean dflags
        fs <- readIORef ref
        removeTmpFiles dflags fs
        writeIORef ref []

cleanTempFilesExcept :: DynFlags -> [FilePath] -> IO ()
cleanTempFilesExcept dflags dont_delete
   = unless (dopt Opt_KeepTmpFiles dflags)
   $ do let ref = filesToClean dflags
        files <- readIORef ref
        let (to_keep, to_delete) = partition (`elem` dont_delete) files
        writeIORef ref to_keep
        removeTmpFiles dflags to_delete


-- find a temporary name that doesn't already exist.
newTempName :: DynFlags -> Suffix -> IO FilePath
newTempName dflags extn
  = do d <- getTempDir dflags
       x <- getProcessID
       findTempName (d </> "ghc" ++ show x ++ "_") 0
  where
    findTempName :: FilePath -> Integer -> IO FilePath
    findTempName prefix x
      = do let filename = (prefix ++ show x) <.> extn
           b  <- doesFileExist filename
           if b then findTempName prefix (x+1)
                else do -- clean it up later
                        consIORef (filesToClean dflags) filename
                        return filename

-- return our temporary directory within tmp_dir, creating one if we
-- don't have one yet
getTempDir :: DynFlags -> IO FilePath
getTempDir dflags
  = do let ref = dirsToClean dflags
           tmp_dir = tmpDir dflags
       mapping <- readIORef ref
       case Map.lookup tmp_dir mapping of
           Nothing ->
               do x <- getProcessID
                  let prefix = tmp_dir </> "ghc" ++ show x ++ "_"
                  let
                      mkTempDir :: Integer -> IO FilePath
                      mkTempDir x
                       = let dirname = prefix ++ show x
                         in do createDirectory dirname
                               let mapping' = Map.insert tmp_dir dirname mapping
                               writeIORef ref mapping'
                               debugTraceMsg dflags 2 (ptext (sLit "Created temporary directory:") <+> text dirname)
                               return dirname
                            `catchIO` \e ->
                                    if isAlreadyExistsError e
                                    then mkTempDir (x+1)
                                    else ioError e
                  mkTempDir 0
           Just d -> return d

addFilesToClean :: DynFlags -> [FilePath] -> IO ()
-- May include wildcards [used by DriverPipeline.run_phase SplitMangle]
addFilesToClean dflags files = mapM_ (consIORef (filesToClean dflags)) files

removeTmpDirs :: DynFlags -> [FilePath] -> IO ()
removeTmpDirs dflags ds
  = traceCmd dflags "Deleting temp dirs"
             ("Deleting: " ++ unwords ds)
             (mapM_ (removeWith dflags removeDirectory) ds)

removeTmpFiles :: DynFlags -> [FilePath] -> IO ()
removeTmpFiles dflags fs
  = warnNon $
    traceCmd dflags "Deleting temp files"
             ("Deleting: " ++ unwords deletees)
             (mapM_ (removeWith dflags removeFile) deletees)
  where
     -- Flat out refuse to delete files that are likely to be source input
     -- files (is there a worse bug than having a compiler delete your source
     -- files?)
     --
     -- Deleting source files is a sign of a bug elsewhere, so prominently flag
     -- the condition.
    warnNon act
     | null non_deletees = act
     | otherwise         = do
        putMsg dflags (text "WARNING - NOT deleting source files:" <+> hsep (map text non_deletees))
        act

    (non_deletees, deletees) = partition isHaskellUserSrcFilename fs

removeWith :: DynFlags -> (FilePath -> IO ()) -> FilePath -> IO ()
removeWith dflags remover f = remover f `catchIO`
  (\e ->
   let msg = if isDoesNotExistError e
             then ptext (sLit "Warning: deleting non-existent") <+> text f
             else ptext (sLit "Warning: exception raised when deleting")
                                            <+> text f <> colon
               $$ text (show e)
   in debugTraceMsg dflags 2 msg
  )

-----------------------------------------------------------------------------
-- Running an external program

runSomething :: DynFlags
             -> String          -- For -v message
             -> String          -- Command name (possibly a full path)
                                --      assumed already dos-ified
             -> [Option]        -- Arguments
                                --      runSomething will dos-ify them
             -> IO ()

runSomething dflags phase_name pgm args =
  runSomethingFiltered dflags id phase_name pgm args Nothing

runSomethingFiltered
  :: DynFlags -> (String->String) -> String -> String -> [Option]
  -> Maybe [(String,String)] -> IO ()

runSomethingFiltered dflags filter_fn phase_name pgm args mb_env = do
  let real_args = filter notNull (map showOpt args)
#if __GLASGOW_HASKELL__ >= 701
      cmdLine = showCommandForUser pgm real_args
#else
      cmdLine = unwords (pgm:real_args)
#endif
  traceCmd dflags phase_name cmdLine $ do
  (exit_code, doesn'tExist) <-
     catchIO (do
         rc <- builderMainLoop dflags filter_fn pgm real_args mb_env
         case rc of
           ExitSuccess{} -> return (rc, False)
           ExitFailure n
             -- rawSystem returns (ExitFailure 127) if the exec failed for any
             -- reason (eg. the program doesn't exist).  This is the only clue
             -- we have, but we need to report something to the user because in
             -- the case of a missing program there will otherwise be no output
             -- at all.
            | n == 127  -> return (rc, True)
            | otherwise -> return (rc, False))
                -- Should 'rawSystem' generate an IO exception indicating that
                -- 'pgm' couldn't be run rather than a funky return code, catch
                -- this here (the win32 version does this, but it doesn't hurt
                -- to test for this in general.)
              (\ err ->
                if IO.isDoesNotExistError err
                 then return (ExitFailure 1, True)
                 else IO.ioError err)
  case (doesn'tExist, exit_code) of
     (True, _)        -> ghcError (InstallationError ("could not execute: " ++ pgm))
     (_, ExitSuccess) -> return ()
     _                -> ghcError (PhaseFailed phase_name exit_code)

builderMainLoop :: DynFlags -> (String -> String) -> FilePath
                -> [String] -> Maybe [(String, String)]
                -> IO ExitCode
builderMainLoop dflags filter_fn pgm real_args mb_env = do
  chan <- newChan
  (hStdIn, hStdOut, hStdErr, hProcess) <- runInteractiveProcess pgm real_args Nothing mb_env

  -- and run a loop piping the output from the compiler to the log_action in DynFlags
  hSetBuffering hStdOut LineBuffering
  hSetBuffering hStdErr LineBuffering
  _ <- forkIO (readerProc chan hStdOut filter_fn)
  _ <- forkIO (readerProc chan hStdErr filter_fn)
  -- we don't want to finish until 2 streams have been completed
  -- (stdout and stderr)
  -- nor until 1 exit code has been retrieved.
  rc <- loop chan hProcess (2::Integer) (1::Integer) ExitSuccess
  -- after that, we're done here.
  hClose hStdIn
  hClose hStdOut
  hClose hStdErr
  return rc
  where
    -- status starts at zero, and increments each time either
    -- a reader process gets EOF, or the build proc exits.  We wait
    -- for all of these to happen (status==3).
    -- ToDo: we should really have a contingency plan in case any of
    -- the threads dies, such as a timeout.
    loop _    _        0 0 exitcode = return exitcode
    loop chan hProcess t p exitcode = do
      mb_code <- if p > 0
                   then getProcessExitCode hProcess
                   else return Nothing
      case mb_code of
        Just code -> loop chan hProcess t (p-1) code
        Nothing
          | t > 0 -> do
              msg <- readChan chan
              case msg of
                BuildMsg msg -> do
                  log_action dflags SevInfo noSrcSpan defaultUserStyle msg
                  loop chan hProcess t p exitcode
                BuildError loc msg -> do
                  log_action dflags SevError (mkSrcSpan loc loc) defaultUserStyle msg
                  loop chan hProcess t p exitcode
                EOF ->
                  loop chan hProcess (t-1) p exitcode
          | otherwise -> loop chan hProcess t p exitcode

readerProc :: Chan BuildMessage -> Handle -> (String -> String) -> IO ()
readerProc chan hdl filter_fn =
    (do str <- hGetContents hdl
        loop (linesPlatform (filter_fn str)) Nothing)
    `finally`
       writeChan chan EOF
        -- ToDo: check errors more carefully
        -- ToDo: in the future, the filter should be implemented as
        -- a stream transformer.
    where
        loop []     Nothing    = return ()
        loop []     (Just err) = writeChan chan err
        loop (l:ls) in_err     =
                case in_err of
                  Just err@(BuildError srcLoc msg)
                    | leading_whitespace l -> do
                        loop ls (Just (BuildError srcLoc (msg $$ text l)))
                    | otherwise -> do
                        writeChan chan err
                        checkError l ls
                  Nothing -> do
                        checkError l ls
                  _ -> panic "readerProc/loop"

        checkError l ls
           = case parseError l of
                Nothing -> do
                    writeChan chan (BuildMsg (text l))
                    loop ls Nothing
                Just (file, lineNum, colNum, msg) -> do
                    let srcLoc = mkSrcLoc (mkFastString file) lineNum colNum
                    loop ls (Just (BuildError srcLoc (text msg)))

        leading_whitespace []    = False
        leading_whitespace (x:_) = isSpace x

parseError :: String -> Maybe (String, Int, Int, String)
parseError s0 = case breakColon s0 of
                Just (filename, s1) ->
                    case breakIntColon s1 of
                    Just (lineNum, s2) ->
                        case breakIntColon s2 of
                        Just (columnNum, s3) ->
                            Just (filename, lineNum, columnNum, s3)
                        Nothing ->
                            Just (filename, lineNum, 0, s2)
                    Nothing -> Nothing
                Nothing -> Nothing

breakColon :: String -> Maybe (String, String)
breakColon xs = case break (':' ==) xs of
                    (ys, _:zs) -> Just (ys, zs)
                    _ -> Nothing

breakIntColon :: String -> Maybe (Int, String)
breakIntColon xs = case break (':' ==) xs of
                       (ys, _:zs)
                        | not (null ys) && all isAscii ys && all isDigit ys ->
                           Just (read ys, zs)
                       _ -> Nothing

data BuildMessage
  = BuildMsg   !SDoc
  | BuildError !SrcLoc !SDoc
  | EOF

traceCmd :: DynFlags -> String -> String -> IO () -> IO ()
-- a) trace the command (at two levels of verbosity)
-- b) don't do it at all if dry-run is set
traceCmd dflags phase_name cmd_line action
 = do   { let verb = verbosity dflags
        ; showPass dflags phase_name
        ; debugTraceMsg dflags 3 (text cmd_line)
        ; hFlush stderr

           -- Test for -n flag
        ; unless (dopt Opt_DryRun dflags) $ do {

           -- And run it!
        ; action `catchIO` handle_exn verb
        }}
  where
    handle_exn _verb exn = do { debugTraceMsg dflags 2 (char '\n')
                              ; debugTraceMsg dflags 2 (ptext (sLit "Failed:") <+> text cmd_line <+> text (show exn))
                              ; ghcError (PhaseFailed phase_name (ExitFailure 1)) }
\end{code}

%************************************************************************
%*                                                                      *
\subsection{Support code}
%*                                                                      *
%************************************************************************

\begin{code}
-----------------------------------------------------------------------------
-- Define       getBaseDir     :: IO (Maybe String)

getBaseDir :: IO (Maybe String)
#if defined(mingw32_HOST_OS)
-- Assuming we are running ghc, accessed by path  $(stuff)/bin/ghc.exe,
-- return the path $(stuff)/lib.
getBaseDir = do let len = (2048::Int) -- plenty, PATH_MAX is 512 under Win32.
                buf <- mallocArray len
                ret <- getModuleFileName nullPtr buf len
                if ret == 0 then free buf >> return Nothing
                            else do s <- peekCString buf
                                    free buf
                                    return (Just (rootDir s))
  where
    rootDir s = case splitFileName $ normalise s of
                (d, ghc_exe)
                 | lower ghc_exe `elem` ["ghc.exe",
                                         "ghc-stage1.exe",
                                         "ghc-stage2.exe",
                                         "ghc-stage3.exe"] ->
                    case splitFileName $ takeDirectory d of
                    -- ghc is in $topdir/bin/ghc.exe
                    (d', bin) | lower bin == "bin" -> takeDirectory d' </> "lib"
                    _ -> fail
                _ -> fail
        where fail = panic ("can't decompose ghc.exe path: " ++ show s)
              lower = map toLower

foreign import stdcall unsafe "GetModuleFileNameA"
  getModuleFileName :: Ptr () -> CString -> Int -> IO Int32
#else
getBaseDir = return Nothing
#endif

#ifdef mingw32_HOST_OS
foreign import ccall unsafe "_getpid" getProcessID :: IO Int -- relies on Int == Int32 on Windows
#else
getProcessID :: IO Int
getProcessID = System.Posix.Internals.c_getpid >>= return . fromIntegral
#endif

-- Divvy up text stream into lines, taking platform dependent
-- line termination into account.
linesPlatform :: String -> [String]
#if !defined(mingw32_HOST_OS)
linesPlatform ls = lines ls
#else
linesPlatform "" = []
linesPlatform xs =
  case lineBreak xs of
    (as,xs1) -> as : linesPlatform xs1
  where
   lineBreak "" = ("","")
   lineBreak ('\r':'\n':xs) = ([],xs)
   lineBreak ('\n':xs) = ([],xs)
   lineBreak (x:xs) = let (as,bs) = lineBreak xs in (x:as,bs)

#endif

\end{code}
