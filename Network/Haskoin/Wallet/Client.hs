module Network.Haskoin.Wallet.Client (clientMain) where

import System.FilePath ((</>))
import System.Directory (createDirectoryIfMissing)
import System.Posix.Directory (changeWorkingDirectory)
import System.Posix.Files 
    ( setFileMode
    , setFileCreationMask
    , unionFileModes
    , ownerModes
    , groupModes
    , otherModes
    , fileExist
    )
import System.Posix.Env (getEnv)
import qualified System.Environment as E (getArgs)
import System.Console.GetOpt 
    ( getOpt
    , usageInfo
    , OptDescr (Option)
    , ArgDescr (NoArg, ReqArg)
    , ArgOrder (Permute)
    )

import Control.Applicative ((<$>))
import Control.Monad (when, forM_)
import Control.Monad.Trans (liftIO)
import qualified Control.Monad.Reader as R (runReaderT)

import Data.FileEmbed (embedFile)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T (pack, unpack)

import Yesod.Default.Config2 (loadAppSettings, useEnv)

import Network.Haskoin.Util
import Network.Haskoin.Constants
import Network.Haskoin.Wallet.Settings
import Network.Haskoin.Wallet.Client.Commands

import System.FilePath.Posix (isAbsolute)

usageHeader :: String
usageHeader = "Usage: hw [<options>] <command> [<args>]"

cmdHelp :: [String]
cmdHelp = lines $ bsToString $ $(embedFile "config/help")

warningMsg :: String
warningMsg = unwords 
    [ "!!!", "This software is experimental."
    , "Use only small amounts of Bitcoins.", "!!!"
    ]

usage :: [String]
usage = warningMsg : usageInfo usageHeader options : cmdHelp

options :: [OptDescr (Config -> Config)]
options =
    [ Option ['w'] ["wallet"]
        (ReqArg (\s cfg -> cfg { configWallet = T.pack s }) "WALLET") $
        "Which wallet to use (default: "
            ++ T.unpack (configWallet hardConfig) ++ ")"
    , Option ['c'] ["count"] 
        (ReqArg (\s cfg -> cfg { configCount = read s }) "INT") $
        "Set the output size of some commands (default: "
            ++ show (configCount hardConfig) ++ ")"
    , Option ['m'] ["minconf"] 
        (ReqArg (\s cfg -> cfg { configMinConf = read s }) "INT") $
        "Required minimum confirmations for balances (default: "
            ++ show (configMinConf hardConfig) ++ ")"
    , Option ['f'] ["fee"] 
        (ReqArg (\s cfg -> cfg { configFee = read s }) "INT") $
        "Fee per 1000 bytes for new transactions (default: "
            ++ show (configFee hardConfig) ++ ")"
    , Option ['S'] ["nosig"]
        (NoArg $ \cfg -> cfg { configSignNewTx = False }) $
        "Do not sign new transactions (default: "
            ++ show (not $ configSignNewTx hardConfig) ++ ")"
    , Option ['i'] ["internal"]
        (NoArg $ \cfg -> cfg { configInternal = True }) $
        "Display internal addresses (default: "
            ++ show (configInternal hardConfig) ++ ")"
    , Option ['z'] ["finalize"]
        (NoArg $ \cfg -> cfg { configFinalize = True }) $
        "Only sign if the tx will be complete (default: "
            ++ show (configFinalize hardConfig) ++ ")"
    , Option ['p'] ["passphrase"]
        (ReqArg (\s cfg -> cfg { configPass = Just $ T.pack s }) "PASSPHRASE")
        "Optional mnemonic passphrase when creating wallets"
    , Option ['j'] ["json"]
        (NoArg $ \cfg -> cfg { configFormat = OutputJSON })
        "Format result as JSON"
    , Option ['y'] ["yaml"]
        (NoArg $ \cfg -> cfg { configFormat = OutputYAML })
        "Format result as YAML"
    , Option ['s'] ["socket"]
        (ReqArg (\s cfg -> cfg { configConnect = s }) "URI") $
        "ZeroMQ socket of the server (default: "
            ++ configConnect hardConfig ++ ")"
    , Option ['d'] ["detach"]
        (NoArg $ \cfg -> cfg { configDetach = True }) $
        "Detach the server process (default: "
            ++ show (configDetach hardConfig) ++ ")"
    , Option ['t'] ["testnet"]
        (NoArg $ \cfg -> cfg { configTestnet = True }) $
        "Use Testnet3 network"
    ]

-- Create and change current working directory
setWorkDir :: Config -> IO ()
setWorkDir cfg = do
    let workDir = configDir cfg </> networkName
    _ <- setFileCreationMask $ otherModes `unionFileModes` groupModes
    createDirectoryIfMissing True workDir
    setFileMode workDir ownerModes
    changeWorkingDirectory workDir

getConfig :: [(Config -> Config)] -> IO Config
getConfig fs = do
    home <- fromMaybe (error "HOME environment not set") <$> getEnv "HOME"
    conf <- loadAppSettings [] [configValue] useEnv
    let cfgFile = confFile conf home
    confFileExists <- fileExist cfgFile
    if confFileExists
      then do
        cfg <- loadAppSettings [cfgFile] [configValue] useEnv
        let cfg' = foldr ($) cfg fs
        return cfg' { configDir = workDir cfg' home }
      else do
        let cfg = foldr ($) conf fs
        return cfg { configDir = workDir cfg home }
  where
    confFile conf home
        | isAbsolute (configFile conf) = configFile conf
        | otherwise = workDir conf home </> configFile conf
    workDir conf home
        | isAbsolute (configDir conf) = configDir conf
        | otherwise = home </> configDir conf

clientMain :: IO ()
clientMain = E.getArgs >>= \args -> case getOpt Permute options args of
    (fs, commands, []) -> do
        cfg <- getConfig fs
        when (configTestnet cfg) switchToTestnet3
        setWorkDir cfg
        dispatchCommand cfg commands
    (_, _, msgs) -> forM_ (msgs ++ usage) putStrLn

dispatchCommand :: Config -> [String] -> IO ()
dispatchCommand cfg args = flip R.runReaderT cfg $ case args of
    "start"       : []                     -> cmdStart
    "stop"        : []                     -> cmdStop
    "newwallet"   : mnemonic               -> cmdNewWallet mnemonic
    "getwallet"   : []                     -> cmdGetWallet
    "walletlist"  : []                     -> cmdGetWallets
    "newacc"      : [name]                 -> cmdNewAcc name
    "newms"       : name : m : n : ks      -> cmdNewMS name m n ks
    "newread"     : [name, key]            -> cmdNewRead name key
    "newreadms"   : name : m : n : ks      -> cmdNewReadMS name m n ks
    "addkeys"     : name : ks              -> cmdAddKeys name ks
    "getacc"      : [name]                 -> cmdGetAcc name
    "acclist"     : []                     -> cmdAccList
    "list"        : [name]                 -> cmdList name
    "page"        : name : page            -> cmdPage name page
    "new"         : [name, label]          -> cmdNew name label
    "label"       : [name, index, label]   -> cmdLabel name index label
    "txlist"      : name : []              -> cmdTxList name
    "txpage"      : name : page            -> cmdTxPage name page
    "send"        : name : add : amnt : [] -> cmdSend name add amnt
    "sendmany"    : name : xs              -> cmdSendMany name xs
    "signtx"      : [name, tx]             -> cmdSignTx name tx
    "importtx"    : [name, tx]             -> cmdImportTx name tx
    "getoffline"  : [name, tid]            -> cmdGetOffline name tid
    "signoffline" : [name, offdata]        -> cmdSignOffline name offdata
    "balance"     : [name]                 -> cmdBalance name
    "spendable"   : [name]                 -> cmdSpendable name
    "getprop"     : [name, hash]           -> cmdGetProp name hash
    "gettx"       : [name, hash]           -> cmdGetTx name hash
    "rescan"      : rescantime             -> cmdRescan rescantime
    "decodetx"    : [tx]                   -> cmdDecodeTx tx
    "help"        : []                     -> liftIO $ forM_ usage putStrLn
    "version"     : []                     -> liftIO $ putStrLn haskoinUserAgent
    []                                     -> liftIO $ forM_ usage putStrLn
    _ -> liftIO $ forM_ ("Invalid command" : usage) $ putStrLn

