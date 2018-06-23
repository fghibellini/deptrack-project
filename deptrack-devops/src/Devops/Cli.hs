{-# LANGUAGE RecordWildCards #-}
-- | Building-block methods to build a command-line tool able to inspect and
-- turnup/turndown DevOps.
module Devops.Cli (
    Method (..), Concurrency (..)
  , applyMethod
  -- * Building main programs
  , SelfPath
  , ForestOptimization
  , App (..)
  , appMain
  , appMethod
  , methodArg
  -- * Utilities
  , getDependenciesOnly
  , graphize
  , opClosureFromB64
  , opClosureToB64
  ) where

import           Control.Distributed.Closure (Closure, unclosure)
import           Control.Monad.Identity      (runIdentity)
import qualified Data.Binary                 as Binary
import qualified Data.ByteString.Base64.Lazy as B64
import           Data.ByteString.Lazy        (ByteString)
import           Data.Tree                   (Forest)
import           Data.Typeable               (Typeable)
import           DepTrack                    (GraphData, buildGraph, evalDepForest1)
import           Prelude                     hiding (readFile)
import           System.Environment          (getArgs, getExecutablePath)

import           Devops.Actions              (checkStatuses, concurrentTurndown, concurrentTurnup, concurrentUpkeep, defaultDotify,
                                              display, dotifyWithStatuses, listUniqNodes, sequentialTurnDown, sequentialTurnup)
import           Devops.Base                 (DevOp, OpUniqueId, PreOp, preOpUniqueId, getDependenciesOnly)

--------------------------------------------------------------------

data Method =
    TurnUp Concurrency
  | TurnDown Concurrency
  | Upkeep
  | Print
  | Dot
  | CheckDot
  | List

data Concurrency = Concurrently | Sequentially

--------------------------------------------------------------------
applyMethod :: [(Forest PreOp -> Forest PreOp)]
            -> Forest PreOp
            -> Method
            -> IO ()
applyMethod transformations originalForest meth = do
  let forest = foldl (.) id transformations originalForest
  let graph = graphize forest

  case meth of
    TurnUp Concurrently   -> concurrentTurnup graph
    TurnUp Sequentially   -> sequentialTurnup graph
    TurnDown Concurrently -> concurrentTurndown graph
    TurnDown Sequentially -> sequentialTurnDown graph
    Upkeep                -> concurrentUpkeep graph
    Print                 -> display forest
    Dot                   -> putStrLn . defaultDotify $ graph
    CheckDot              -> putStrLn . dotifyWithStatuses graph =<< checkStatuses graph
    List                  -> listUniqNodes forest

--------------------------------------------------------------------

-- | A FilePath corresponding to the file with the currently-executing binary.
type SelfPath = FilePath

-- | An optimization on PreOp forests.
type ForestOptimization = Forest PreOp -> Forest PreOp

-- | A builder for app that can be useful for defining an infrastructure as a
-- recursive structure where the "main entry point" of the recursion is the
-- binary itself.
data App env node = App {
    _parseArgs :: [String] -> (node, Method)
  -- ^ Parses arguments, returns a parsed architecture and a set of args for
  -- the real defaulMain.
  , _revParse  :: node -> Method -> [String]
  -- ^ Reverse parse arguments, for instance when building a callback.
  , _target    :: node -> SelfPath -> (node -> Method -> [String]) -> DevOp env ()
  -- ^ Generates a target from the argument and the selfPath
  , _opts      :: [ForestOptimization]
  -- ^ Optimizations to run.
  , _retrieveEnv  :: node -> IO env
  -- ^ IO to retrieve the current environment.
  }

-- | DefaultMain for 'App'.
appMain :: App env a -> IO ()
appMain App{..} = do
    self <- getExecutablePath
    args <- getArgs
    let (node, meth) = _parseArgs args
    env  <- _retrieveEnv node
    let forest = getDependenciesOnly env $ _target node self _revParse
    applyMethod _opts forest meth

-- | Unsafely parse a 'Method' from what could be a command line argument.
--
-- (NB. unsafe means this function is partial, you should use this function in
-- conjunction with 'methodArg' for the reverse parse and you will be fine).
appMethod :: String -> Method
appMethod "up"        = TurnUp Concurrently
appMethod "up-seq"    = TurnUp Sequentially
appMethod "down"      = TurnDown Concurrently
appMethod "down-seq"  = TurnDown Sequentially
appMethod "upkeep"    = Upkeep
appMethod "print"     = Print
appMethod "dot"       = Dot
appMethod "check-dot" = CheckDot
appMethod "list"      = List
appMethod str         = error $ "unparsed appMethod: " ++ str

-- | Serializes a 'Method' to what should be a command-line argument later
-- parsed via 'appMethod'.
methodArg :: Method -> String
methodArg (TurnUp Concurrently)   = "up"
methodArg (TurnUp Sequentially)   = "up-seq"
methodArg (TurnDown Concurrently) = "down"
methodArg (TurnDown Sequentially) = "down-seq"
methodArg Upkeep                  = "upkeep"
methodArg Print                   = "print"
methodArg Dot                     = "dot"
methodArg CheckDot                = "check-dot"
methodArg List                    = "list"

--------------------------------------------------------------------

-- | Builds a Graph from dependencies represented as a Forest.
--
-- Nodes with a same hash in the Forest will correspond to the same node in the
-- graph, hence, it's possible to create cycles by mistake if two nodes have a
-- same hash by mistake (this is possible if the hash does not depend on all
-- arguments to a DevOp).
graphize :: Forest PreOp -> GraphData PreOp OpUniqueId
graphize forest = buildGraph preOpUniqueId forest

-- | Helper to deal with App when you want to use Closures as a
-- serialization/deserialization mechanism.
--
-- You will likely add 'opClosureFromB64' in the '_parseArgs' field of your
-- 'App' and 'opClosureToB64' in the '_revParse' field.
opClosureFromB64 :: (Typeable env, Typeable a) => ByteString -> Closure (DevOp env a)
opClosureFromB64 b64 = do
    let bstr = B64.decode b64
    let encodedClosure = either (error "invalid base64") id bstr
    Binary.decode encodedClosure

-- | Dual to 'opClosureFromB64'.
opClosureToB64 :: (Typeable env, Typeable a) => Closure (DevOp env a) -> ByteString
opClosureToB64 clo =
    B64.encode $ Binary.encode clo
