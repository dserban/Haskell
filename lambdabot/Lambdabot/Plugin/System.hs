-- | System module : IRC control functions
module Lambdabot.Plugin.System (theModule) where

import Lambdabot
import Lambdabot.Compat.FreenodeNick
import Lambdabot.IRC
import Lambdabot.Monad
import Lambdabot.Plugin
import Lambdabot.Compat.AltTime

import Control.Monad.State (gets, modify)
import Control.Monad.Trans
import qualified Data.Map as M
import qualified Data.Set as S

type SystemState = (ClockTime, TimeDiff)
type System = ModuleT SystemState LB

theModule :: Module SystemState
theModule = newModule
    { moduleDefState = flip (,) noTimeDiff `fmap` io getClockTime
    , moduleSerialize  = Just stdSerial

    , moduleInit = do
        (_, d) <- readMS
        t      <- io getClockTime
        writeMS (t, d)
    , moduleExit = do
        (initial, d) <- readMS
        now          <- liftIO getClockTime
        writeMS (initial, max d (diffClockTimes now initial))
    
    , moduleCmds = return $
        [ (command "listchans")
            { help = say "Show channels bot has joined"
            , process = \_ -> listKeys (M.mapKeysMonotonic (FreenodeNick . getCN) . ircChannels)
            }
        , (command "listmodules")
            { help = say "listmodules. Show available plugins"
            , process = \_ -> listKeys ircModules
            }
        , (command "listservers")
            { help = say "listservers. Show current servers"
            , process = \_ -> listKeys ircServerMap
            }
        , (command "list")
            { help = say "list [module|command]. Show commands for [module] or the module providing [command]."
            , process = doList
            }
        , (command "echo")
            { help = say "echo <msg>. echo irc protocol string"
            , process = doEcho
            }
        , (command "uptime")
            { help = say "uptime. Show uptime"
            , process = \_ -> do
                (uptime, maxUptime) <- lift getUptime
                say ("uptime: "           ++ timeDiffPretty uptime ++
                     ", longest uptime: " ++ timeDiffPretty maxUptime)
            }
        
        , (command "listall")
            { privileged = True
            , help = say "list all commands"
            , process = \_ -> mapM_ doList . M.keys =<< lb (gets ircModules)
            }
        , (command "join")
            { privileged = True
            , help = say "join <channel>"
            , process = \rest -> do
                chan <- readNick rest
                lb $ send (joinChannel chan)
            }
        , (command "part")
            { privileged = True
            , help = say "part <channel>"
            , aliases = ["leave"]
            , process = \rest -> do
                chan <- readNick rest
                lb $ send (partChannel chan)
            }
        , (command "msg")
            { privileged = True
            , help = say "msg <nick or channel> <msg>"
            , process = \rest -> do
                -- writes to another location:
                let (tgt, txt) = splitFirstWord rest
                tgtNick <- readNick tgt
                lb $ ircPrivmsg tgtNick txt
            }
        , (command "quit")
            { privileged = True
            , help = say "quit [msg], have the bot exit with msg"
            , process = \rest -> do
                server <- getServer
                lb (ircQuit server $ if null rest then "requested" else rest)
            }
        , (command "flush")
            { privileged = True
            , help = say "flush. flush state to disk"
            , process = \_ -> lb flushModuleState
            }
        , (command "admin")
            { privileged = True
            , help = say "admin [+|-] nick. change a user's admin status."
            , process = doAdmin
            }
        , (command "ignore")
            { privileged = True
            , help = say "ignore [+|-] nick. change a user's ignore status."
            , process = doIgnore
            }
        , (command "reconnect")
            { privileged = True
            , help = say "reconnect to server"
            , process = \rest -> do
                server <- getServer
                lb (ircReconnect server $ if null rest then "requested" else rest)
            }
        ]
    }

------------------------------------------------------------------------

doList :: String -> Cmd System ()
doList "" = say "What module?  Try @listmodules for some ideas."
doList m  = say =<< lb (listModule m)

doEcho :: String -> Cmd System ()
doEcho rest = do
    rawMsg <- withMsg (return . show)
    target <- showNick =<< getTarget
    say (concat ["echo; msg:", rawMsg, " target:" , target, " rest:", show rest])

doAdmin :: String -> Cmd System ()
doAdmin = toggleNick $ \op nck s -> s { ircPrivilegedUsers = op nck (ircPrivilegedUsers s) }

doIgnore :: String -> Cmd System ()
doIgnore = toggleNick $ \op nck s -> s { ircIgnoredUsers = op nck (ircIgnoredUsers s) }

------------------------------------------------------------------------

--  | Print map keys
listKeys :: Show k => (IRCRWState -> M.Map k v) -> Cmd System ()
listKeys f = say . showClean . M.keys =<< lb (gets f)

getUptime :: System (TimeDiff, TimeDiff)
getUptime = do
    (loaded, m) <- readMS
    now         <- io getClockTime
    let diff = now `diffClockTimes` loaded
    return (diff, max diff m)

toggleNick :: (Ord a, MonadLB m) =>
    ((a -> S.Set a -> S.Set a) -> Nick -> IRCRWState -> IRCRWState)
    -> String -> Cmd m ()
toggleNick edit rest = do
    let (op, tgt) = splitAt 2 rest
    
    f <- case op of
        "+ " -> return S.insert
        "- " -> return S.delete
        _    -> fail "invalid usage"
    
    nck <- readNick tgt
    lb . modify $ edit f nck

listModule :: String -> LB String
listModule s = withModule s fromCommand printProvides
  where
    fromCommand = withCommand s
        (return $ "No module \""++s++"\" loaded") (const . printProvides)

    -- ghc now needs a type annotation here
    printProvides :: Module st -> ModuleT st LB String
    printProvides m = do
        cmds <- moduleCmds m
        let cmds' = filter (not . privileged) cmds
        name' <- getModuleName
        return . concat $ if null cmds'
                          then [name', " has no visible commands"]
                          else [name', " provides: ", showClean (concatMap cmdNames cmds')]
