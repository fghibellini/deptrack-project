{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Control.Monad (void, sequence)
import           Data.String.Conversions (convertString)
import           System.Environment (getArgs)

import           Devops.Storage (FileContent, fileContent)
import           Devops.Debian.User (mereUser, userDirectory)
import qualified Devops.Debian.Commands as Cmd
import           Devops.Base (DevOp)
import           Devops.Cli (simpleMain)
import           Devops.Git (GitUrl, gitClone)
import           Devops.Optimize (optimizeDebianPackages)
import           Devops.Nginx
import qualified Devops.StaticSite as StaticSite

main :: IO ()
main = do
    args <- getArgs
    simpleMain webSites [optimizeDebianPackages] args ()
  where
    webSites :: DevOp env ()
    webSites = void $ reverseProxy "/opt/rundir" nginxConfigs

nginxConfigs :: [DevOp env NginxServerConfig]
nginxConfigs = [
    site "dicioccio.fr" "https://github.com/lucasdicioccio/site"
  , site "lubian.info" "https://github.com/lubian/site"
  ]

site :: HostName -> GitUrl -> DevOp env NginxServerConfig
site host url = StaticSite.gitCloned repo
  where
    repo = gitClone url "master" Cmd.git (userDirectory (convertString host) user)
    user = mereUser "staticsites"
