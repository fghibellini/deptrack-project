
module Devops.Storage.BlockDevice where

data BlockDevice a = BlockDevice { blockDevicePath :: FilePath
                                 , partitionPath   :: Int -> FilePath
                                 }
