{-# LANGUAGE GADTs, KindSignatures, LambdaCase, TypeOperators, UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-missing-signatures #-}
module Semantic.REPL
( rubyREPL
) where

import Control.Abstract hiding (Continue, List, string)
import Control.Effect.Carrier
import Control.Effect.Resource
import Control.Effect.Sum
import Data.Abstract.Address.Precise as Precise
import Data.Abstract.Environment as Env
import Data.Abstract.Evaluatable hiding (string)
import Data.Abstract.Module
import Data.Abstract.ModuleTable as ModuleTable
import Data.Abstract.Package
import Data.Abstract.Value.Concrete as Concrete
import Data.Blob (Blob(..))
import Data.Error (showExcerpt)
import Data.File (File (..), readBlobFromFile)
import Data.Graph (topologicalSort)
import Data.Language as Language
import Data.List (uncons)
import Data.Project
import Data.Quieterm
import Data.Span
import qualified Data.Time.Clock.POSIX as Time (getCurrentTime)
import qualified Data.Time.LocalTime as LocalTime
import Numeric (readDec)
import Parsing.Parser (rubyParser)
import Prologue
import Semantic.Analysis
import Semantic.Config (logOptionsFromConfig)
import Semantic.Distribute
import Semantic.Graph
import Semantic.Resolution
import Semantic.Task hiding (Error)
import qualified Semantic.Task.Files as Files
import Semantic.Telemetry
import Semantic.Timeout
import Semantic.Telemetry.Log (LogOptions, Message(..), writeLogMessage)
import Semantic.Util
import System.Console.Haskeline
import System.Directory (createDirectoryIfMissing, getHomeDirectory)
import System.FilePath

data REPL (m :: * -> *) k
  = Prompt (Maybe String -> k)
  | Output String k
  deriving (Functor)

prompt :: (Member REPL sig, Carrier sig m) => m (Maybe String)
prompt = send (Prompt ret)

output :: (Member REPL sig, Carrier sig m) => String -> m ()
output s = send (Output s (ret ()))


data Quit = Quit
  deriving Show

instance Exception Quit


instance HFunctor REPL where
  hmap _ = coerce

instance Effect REPL where
  handle state handler (Prompt k) = Prompt (handler . (<$ state) . k)
  handle state handler (Output s k) = Output s (handler (k <$ state))


runREPL :: (MonadIO m, Carrier sig m) => Prefs -> Settings IO -> Eff (REPLC m) a -> m a
runREPL prefs settings = flip runREPLC (prefs, settings) . interpret

newtype REPLC m a = REPLC { runREPLC :: (Prefs, Settings IO) -> m a }

instance (Carrier sig m, MonadIO m) => Carrier (REPL :+: sig) (REPLC m) where
  ret = REPLC . const . ret
  eff op = REPLC (\ args -> handleSum (eff . handleReader args runREPLC) (\case
    Prompt   k -> liftIO (uncurry runInputTWithPrefs args (getInputLine (cyan <> "repl: " <> plain))) >>= flip runREPLC args . k
    Output s k -> liftIO (uncurry runInputTWithPrefs args (outputStrLn s)) *> runREPLC k args) op)

rubyREPL = repl (Proxy @'Language.Ruby) rubyParser

repl proxy parser paths = defaultConfig debugOptions >>= \ config -> runM . runDistribute . runResource (runM . runDistribute) . runTimeout (runM . runDistribute . runResource (runM . runDistribute)) . runError @_ @_ @SomeException . runTelemetryIgnoringStat (logOptionsFromConfig config) . runTraceInTelemetry . runReader config . Files.runFiles . runResolution . runTaskF $ do
  blobs <- catMaybes <$> traverse readBlobFromFile (flip File (Language.reflect proxy) <$> paths)
  package <- fmap (fmap quieterm) <$> parsePackage parser (Project (takeDirectory (maybe "/" fst (uncons paths))) blobs (Language.reflect proxy) [])
  modules <- topologicalSort <$> runImportGraphToModules proxy (snd <$> package)
  homeDir <- liftIO getHomeDirectory
  prefs <- liftIO (readPrefs (homeDir <> "/.haskeline"))
  let settingsDir = homeDir <> "/.local/semantic"
  liftIO $ createDirectoryIfMissing True settingsDir
  let settings = Settings
        { complete = noCompletion
        , historyFile = Just (settingsDir <> "/repl_history")
        , autoAddHistory = True
        }
  runEvaluator
    . runREPL prefs settings
    . fmap snd
    . runState ([] @Breakpoint)
    . runReader Step
    . runEvaluator
    . id @(Evaluator _ Precise (Value _ Precise) _ _)
    . raiseHandler runTraceByPrinting
    . runHeap
    . raiseHandler runFresh
    . fmap reassociate
    . runLoadError
    . runUnspecialized
    . runEnvironmentError
    . runEvalError
    . runResolutionError
    . runAddressError
    . runValueError
    . runModuleTable
    . runModules (ModuleTable.modulePaths (packageModules (snd <$> package)))
    . raiseHandler (runReader (packageInfo package))
    . raiseHandler (runState (lowerBound @Span))
    . raiseHandler (runReader (lowerBound @Span))
    $ evaluate proxy id (evalTerm (withTermSpans . step (fmap (\ (x:|_) -> moduleBody x) <$> ModuleTable.toPairs (packageModules (fst <$> package))))) modules

-- TODO: REPL for typechecking/abstract semantics
-- TODO: drive the flow from within the REPL instead of from without

runTelemetryIgnoringStat :: (Carrier sig m, MonadIO m) => LogOptions -> Eff (TelemetryIgnoringStatC m) a -> m a
runTelemetryIgnoringStat logOptions = flip runTelemetryIgnoringStatC logOptions . interpret

newtype TelemetryIgnoringStatC m a = TelemetryIgnoringStatC { runTelemetryIgnoringStatC :: LogOptions -> m a }

instance (Carrier sig m, MonadIO m) => Carrier (Telemetry :+: sig) (TelemetryIgnoringStatC m) where
  ret = TelemetryIgnoringStatC . const . ret
  eff op = TelemetryIgnoringStatC (\ logOptions -> handleSum (eff . handleReader logOptions runTelemetryIgnoringStatC) (\case
    WriteStat _                  k -> runTelemetryIgnoringStatC k logOptions
    WriteLog level message pairs k -> do
      time <- liftIO Time.getCurrentTime
      zonedTime <- liftIO (LocalTime.utcToLocalZonedTime time)
      writeLogMessage logOptions (Message level message pairs zonedTime)
      runTelemetryIgnoringStatC k logOptions) op)

step :: ( Member (Env address) sig
        , Member (Error SomeException) sig
        , Member REPL sig
        , Member (Reader ModuleInfo) sig
        , Member (Reader Span) sig
        , Member (Reader Step) sig
        , Member (State [Breakpoint]) sig
        , Show address
        , Carrier sig m
        )
     => [(ModulePath, Blob)]
     -> Open (Open (term -> Evaluator term address value m a))
step blobs recur0 recur term = do
  break <- shouldBreak
  if break then do
    list
    runCommands (recur0 recur term)
  else
    recur0 recur term
  where list = do
          path <- asks modulePath
          span <- ask
          maybe (pure ()) (\ blob -> output (showExcerpt True span blob "")) (Prelude.lookup path blobs)
        help = do
          output "Commands available from the prompt:"
          output ""
          output "  :help, :?                   display this list of commands"
          output "  :list                       show the source code around current breakpoint"
          output "  :step                       single-step after stopping at a breakpoint"
          output "  :continue                   continue evaluation until the next breakpoint"
          output "  :show bindings              show the current bindings"
          output "  :quit, :q, :abandon         abandon the current evaluation and exit the repl"
        showBindings = do
          bindings <- Env.head <$> getEnv
          output $ unlines (uncurry showBinding <$> Env.pairs bindings)
        showBinding name addr = show name <> " = " <> show addr
        runCommand run [":step"]     = local (const Step) run
        runCommand run [":continue"] = local (const Continue) run
        runCommand run [":break", s]
          | [(i, "")] <- readDec s = modify (OnLine i :) >> runCommands run
        -- TODO: :show breakpoints
        -- TODO: :delete breakpoints
        runCommand run [":list"] = list >> runCommands run
        runCommand run [":show", "bindings"] = showBindings >> runCommands run
        -- TODO: show the value(s) in the heap
        -- TODO: can we call functions somehow? Maybe parse expressions with the current parser?
        runCommand _   [quit] | quit `elem` [":quit", ":q", ":abandon"] = throwError (SomeException Quit)
        runCommand run [":help"] = help >> runCommands run
        runCommand run [":?"] = help >> runCommands run
        runCommand run [] = runCommands run
        runCommand run other = output ("unknown command '" <> unwords other <> "'") >> output "use :? for help" >> runCommands run
        runCommands run = do
          str <- prompt
          maybe (runCommands run) (runCommand run . words) str


newtype Breakpoint
  = OnLine Int
  deriving Show

-- FIXME: OnLine should take a module, defaulting to the current module
-- TODO: OnPos, taking a column number as well as line number and module
-- TODO: OnSymbol, taking a function/method name? This could be tricky to implement cross-language

data Step
  = Step
  | Continue
  deriving Show

-- TODO: StepLocal/StepModule

shouldBreak :: (Member (State [Breakpoint]) sig, Member (Reader Span) sig, Member (Reader Step) sig, Carrier sig m) => Evaluator term address value m Bool
shouldBreak = do
  step <- ask
  case step of
    Step -> pure True
    Continue -> do
      breakpoints <- get
      span <- ask
      pure (any @[] (matching span) breakpoints)
  where matching Span{..} (OnLine n)
          | n >= posLine spanStart
          , n <= posLine spanEnd   = True
          | otherwise              = False


cyan :: String
cyan = "\ESC[1;36m\STX"

plain :: String
plain = "\ESC[0m\STX"
