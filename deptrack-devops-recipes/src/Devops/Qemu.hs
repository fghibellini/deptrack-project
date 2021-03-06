{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies      #-}

-- TODO:
-- * pass VNC params to expose a networked service
-- * pass monitor params on a char device to expose a console
module Devops.Qemu where

import           Data.Monoid            ((<>))
import qualified Data.Text              as Text
import           System.FilePath.Posix  ((</>))
import           Text.Printf            (printf)

import           Devops.BaseImage (BaseImage(..))
import           Devops.Debian
import           Devops.Debian.Commands
import           Devops.Debian.User
import           Devops.Dhcp
import           Devops.DnsResolver
import           Devops.Networking
import           Devops.Parasite
import           Devops.Service
import           Devops.Storage
import           Devops.Base
import           Devops.Utils
import           Devops.QemuBootstrap (QemuBase)

type RAM = Int -- TODO: improve
type RepoDir = FilePath

qemuUser :: DevOp env (User)
qemuUser = user "devopuser" qemuGroup (sequence [kvmGroup])

qemuGroup :: DevOp env Group
qemuGroup = group "devopuser"

qemuUserKvmGroup :: DevOp env (User,Group)
qemuUserKvmGroup = (,) <$> qemuUser <*> kvmGroup

kvmGroup :: DevOp env Group
kvmGroup = deb "qemu-kvm" >> udevRuleHackForKvm >> preExistingGroup "kvm"
  where udevRuleHackForKvm = fileContent "/etc/udev/rules.d/80-kvm.rules"
                                         (pure "KERNEL==\"kvm\", GROUP=\"kvm\", MODE=\"0666\"\n")

qemufilePermissions :: DevOp env FilePresent -> DevOp env FilePresent
qemufilePermissions = filePermissions ((,) <$> qemuUser <*> qemuGroup)

data QemuVM
type instance DaemonConfig QemuVM =
    (Index, IpNetString, MacAddressString, Daemon DHCP, Bridge, Interface, RAM, Int, QemuDisk)

qemuCommandArgs :: DaemonConfig QemuVM -> CommandArgs
qemuCommandArgs (_, _, macStr, _, _, iface, ram, cpuCount, (QemuDisk (FilePresent path))) =
  [ "-enable-kvm"
  , "-nographic"
  , "-m", show ram
  , "-smp", "cpus=" <> show cpuCount
  , "-hda", path
  , "-net", "nic,macaddr=" <> Text.unpack macStr
  , "-net", printf "tap,ifname=%s,script=no,downscript=no" (Text.unpack $ interfaceName iface)
  ]

data DiskFile = DiskFile !Name deriving Show
data QemuDisk = QemuDisk !FilePresent

type Depth = Int
diskFileName :: Index -> Depth -> Name
diskFileName idx n = Text.pack (printf "disk-%02d.%d.img" idx n)

-- | Fetches a DiskFile identified by its name from a known local repository.
fetchDiskFile :: (RunDir, RepoDir) -> DiskFile -> DevOp env (RepositoryFile, FilePresent)
fetchDiskFile (rundir,repodir) (DiskFile x) = do
  let origin = localRepositoryFile (repodir </> Text.unpack x)
  (repo,fp) <- fileCopy (pure $ rundir </> Text.unpack x) origin
  filepresent <- qemufilePermissions $ pure fp
  return (repo, filepresent)

-- | Prepares a QemuDisk from a list of diskfiles, appending a new image at the beginning.
newHeadFromBackingChain :: (RunDir, RepoDir) -> Index -> [DiskFile] -> DevOp env QemuDisk
newHeadFromBackingChain env idx chain = do
  QemuDisk <$> newHeadDiskfile env idx chain

-- | Prepares a QemuDisk from a list of diskfiles, keeping the beginning of the backing chain.
savedHeadfromBackingChain :: (RunDir, RepoDir) -> Index -> [DiskFile] -> DevOp env QemuDisk
savedHeadfromBackingChain env idx chain = do
  QemuDisk <$> preserveHeadDiskFile env idx chain

preserveHeadDiskFile :: (RunDir, RepoDir) -> Index -> [DiskFile] -> DevOp env FilePresent
preserveHeadDiskFile env _ chain = do
  let getHeadFile = head <$> traverse (fetchDiskFile env) chain
  (repoFile,_) <- getHeadFile
  let (LocalRepositoryFile rpath) = repoFile
  let headFile = fmap snd $ getHeadFile
  fmap snd $ turndownfileBackup rpath headFile

newHeadPath :: RunDir -> Index -> FilePath
newHeadPath rundir idx = printf (rundir </> "head-disk-%02d.img") idx

newHeadDiskfile :: (RunDir,RepoDir) -> Index -> [DiskFile] -> DevOp env FilePresent
newHeadDiskfile (rundir,repo) idx chain = do
  let path = newHeadPath rundir idx
  let newHeadBackupPath = repo </> (Text.unpack $ diskFileName idx (length chain))
  let mkArgsFromLocalCopy (FilePresent x) = [
            "create"
          , "-f", "qcow2"
          , "-o", "backing_file="<> x
          , path
          ]
  let args = mkArgsFromLocalCopy . head <$> traverse (fmap snd . fetchDiskFile (rundir,repo)) chain
  let headFile = qemufilePermissions $ fmap (\(_,_,x)->x) $ generatedFile path qemuImg args
  fmap snd $ (turndownfileBackup newHeadBackupPath headFile)

-- | Creates a new QemuVM using a snapshot consisting of a list of DiskFiles.
-- DiskFiles in this case are files present in the RepoDir.
-- This function appends a new diskfile at the tip of the snapshot, see
-- existingQemuVm to continue editing the snapshot.
newQemuVm :: (RunDir,RepoDir)
          -> AddressPlan
          -> Index
          -> RAM
          -> Int
          -> DevOp env Interface
          -> [DiskFile]
          -> DevOp env (Daemon QemuVM)
newQemuVm env@(rundir,repo) plan idx ram cpuCount mkIface backingChain = do
    let disk = newHeadFromBackingChain (rundir,repo) idx backingChain
    qemuVm env plan idx ram cpuCount mkIface disk

-- | Creates a new QemuVM using a snapshot consisting of a list of DiskFiles.
-- DiskFiles in this case are files present in the RepoDir.
-- This function continue editing the diskfile at the tip of the snapshot.
-- See newQemuVm to continue editing the snapshot.
existingQemuVm :: (RunDir,RepoDir)
               -> AddressPlan
               -> Index
               -> RAM
               -> Int
               -> DevOp env Interface
               -> [DiskFile]
               -> DevOp env (Daemon QemuVM)
existingQemuVm env@(rundir,repo) plan idx ram cpuCount mkIface backingChain = do
    let disk = savedHeadfromBackingChain (rundir,repo) idx backingChain
    qemuVm env plan idx ram cpuCount mkIface disk

-- | Spawns a QemuVm from a base image.
baseImageQemuVm :: (RunDir,RepoDir)
       -> AddressPlan
       -> Index
       -> RAM
       -> Int
       -> DevOp env Interface
       -> DevOp env (BaseImage (QemuBase env))
       -> DevOp env (Daemon QemuVM)
baseImageQemuVm env@(rundir,_) plan idx ram cpuCount mkIface boot = do
    let disk = newDiskFromBaseImage rundir idx boot
    qemuVm env plan idx ram cpuCount mkIface disk

newDiskFromBaseImage
  :: RunDir
  -> Index
  -> DevOp env (BaseImage (QemuBase env))
  -> DevOp env QemuDisk
newDiskFromBaseImage rundir idx mkBase = do
  let asRepo (FilePresent f) = LocalRepositoryFile f
  let f = asRepo . imagePath <$> mkBase
  let g = snd <$> fileCopy (pure $ newHeadPath rundir idx ) f
  QemuDisk <$> qemufilePermissions g

-- | Spawns a QemuVM uniquely identified by its Index.
qemuVm :: (RunDir,RepoDir)
       -> AddressPlan
       -> RAM
       -> Index
       -> Int
       -> DevOp env Interface
       -> DevOp env QemuDisk
       -> DevOp env (Daemon QemuVM)
qemuVm (rundir,_) plan idx ram cpuCount mkIface mkdisk = do
  daemon ("qemu-" <> Text.pack (show idx)) (Just qemuUserKvmGroup) qemux86 qemuCommandArgs $ do
    _ <- traverse deb ["qemu", "qemu-kvm"]
    disk <- mkdisk
    (dhcp, (tap0, br)) <- vmNetwork rundir idx plan mkIface
    let ip = fixedIp plan idx
    return (idx, ip, fixedMac plan idx, dhcp, br, tap0, ram, cpuCount, disk)

eth0 :: DevOp env Interface
eth0 = pure $ PhysicalIface "eth0"

br0 :: DevOp env Bridge
br0 = fmap fst (bridge "br0" ((,) <$> brctl <*> binIp))

tapN :: Index -> DevOp env Tap
tapN idx = let tapName = Text.pack (printf "tap%d" idx) in
        fst <$> tap tapName qemuUser tunctl

vmNetwork :: RunDir
          -> Index
          -> AddressPlan
          -> DevOp env Interface
          -> DevOp env (Daemon DHCP, BridgedInterface)
vmNetwork rundir idx plan iface = declare (noop ("~networking: " <> Text.pack (show idx)) "example network config") $ do
  -- enable IP forwarding
  _ <- ipForwarding
  -- setup some interfaces
  (t,br,_) <- bridgedInterface (TapIface <$> tapN idx) br0 ((,) <$> brctl <*> binIp)
  _ <- nating iptables iface (BridgeIface <$> br0)
  -- start networking services
  let localDnsDaemon = dnsResolver rundir plan googlePublicDns
  let dns = fmap listeningDnsResolverDaemon localDnsDaemon
  let localhost = existingRemote (localhostIp plan) -- TODO: create a "localhost helper taking a configured interface"
  let dnsService = Remoted <$> localhost <*> dns
  dhcp <- dhcpServer rundir plan dnsService br0
  return (dhcp, (t, br))

-- | Asserts control on a running QemuVM.
--
-- Verification is done by ssh-ing in the VM and running the 'echo' command,
-- hence echo must be available at the remote end.
controlledQemuVm :: ParasiteLogin -> DevOp env (Daemon QemuVM) -> DevOp env ControlledHost
controlledQemuVm login vm = devop fst mkOp $ do
  (Daemon _ _ _ (idx,ip,_,_,_,_,_,_,_)) <- vm
  return (ControlledHost login (Remote ip), idx)
  where mkOp (ControlledHost _ (Remote ip), idx) =
            (buildOp
              ("remote-qemu-vm: " <> Text.pack (show idx))
              ("controllable remote machine at " <> ip)
              (checkHelloWorld ip)
              ((retryWithBackoff 3 5 $ checkHelloWorld ip) >> return ())
              noAction
              noAction)
        checkHelloWorld ip = checkExitCodeAndStdout (=="hello-world\n") "ssh" (sshCmd ip) ""
        sshCmd ip = [ "-o", "StrictHostKeyChecking no"
                    , "-o", "UserKnownHostsFile /dev/null"
                    , "-l", Text.unpack login, Text.unpack ip, "echo", "hello-world"]
