module System.Console.Haskeline(
                    -- * Main functions
                    --
                    -- $maindoc
                    InputT,
                    runInputT,
                    runInputTWithPrefs,
                    getInputLine,
                    putOutputStr,
                    putOutputStrLn,
                    -- * Settings
                    Settings(..),
                    defaultSettings,
                    setComplete,
                    -- * Ctrl-C handling
                    Interrupt(..),
                    handleInterrupt,
                    module System.Console.Haskeline.Completion,
                    module System.Console.Haskeline.Prefs,
                    module System.Console.Haskeline.MonadException)
                     where

import System.Console.Haskeline.LineState
import System.Console.Haskeline.Command
import System.Console.Haskeline.Command.History
import System.Console.Haskeline.Vi
import System.Console.Haskeline.Emacs
import System.Console.Haskeline.Prefs
import System.Console.Haskeline.Monads
import System.Console.Haskeline.MonadException
import System.Console.Haskeline.InputT
import System.Console.Haskeline.Term
import System.Console.Haskeline.Backend
import System.Console.Haskeline.Completion

import System.IO
import Data.Char (isSpace)
import Control.Monad
import qualified Control.Exception as Exception
import Data.Dynamic



{- $maindoc


An example use of this library for a simple read-eval-print loop is the
following.

> import System.Console.Haskeline
> import Control.Monad.Trans
> 
> main :: IO ()
> main = runInputT defaultSettings loop
>    where 
>        loop :: InputT IO ()
>        loop = do
>            minput <- getInputLine "% "
>            case minput of
>                Nothing -> return ()
>                Just "quit" -> return ()
>                Just input -> do putOutputStrLn $ "Input was: " ++ input
>                                 loop

-}


-- | A useful default.  In particular:
--
-- @
-- defaultSettings = Settings {
--           complete = completeFilename,
--           historyFile = Nothing,
--           handleSigINT = False
--           }
-- @
defaultSettings :: MonadIO m => Settings m
defaultSettings = Settings {complete = completeFilename,
                        historyFile = Nothing,
                        handleSigINT = False}

-- NOTE: If we set stdout to NoBuffering, there can be a flicker effect when many
-- characters are printed at once.  We'll keep it buffered here, and let the Draw
-- monad manually flush outputs that don't print a newline.
wrapTerminalOps:: MonadException m => m a -> m a
wrapTerminalOps =
    bracketSet (hGetBuffering stdin) (hSetBuffering stdin) NoBuffering
    . bracketSet (hGetBuffering stdout) (hSetBuffering stdout) LineBuffering
    . bracketSet (hGetEcho stdout) (hSetEcho stdout) False

bracketSet :: (Eq a, MonadException m) => IO a -> (a -> IO ()) -> a -> m b -> m b
bracketSet getState set newState f = do
    oldState <- liftIO getState
    if oldState == newState
        then f
        else finally (liftIO (set newState) >> f) (liftIO (set oldState))


-- | Write a string to the console output.  Allows cross-platform display of
-- Unicode characters.
putOutputStr :: MonadIO m => String -> InputT m ()
putOutputStr xs = do
    run :: RunTerm (InputCmdT IO) <- liftIO myRunTerm
    liftIO $ putStrTerm run xs

-- | Write a string to the console output, followed by a newline.  Allows
-- cross-platform display of Unicode characters.
putOutputStrLn :: MonadIO m => String -> InputT m ()
putOutputStrLn xs = putOutputStr (xs++"\n")

{- | Read one line of input from the user, with a rich line-editing
user interface.  Returns 'Nothing' if the user presses Ctrl-D when the input
text is empty.  Otherwise, it returns the input line with the final newline
removed.  
 
If 'stdin' is not connected to a terminal (for example, piped from
another process), then this function is equivalent to 'getLine', except that
it returns 'Nothing' if an EOF is encountered before any characters are
read.

If signal handling is enabled in the 'Settings', then 'getInputLine' will
throw an 'Interrupt' exception when the user presses Ctrl-C.

-}
getInputLine :: forall m . MonadException m => String -- ^ The input prompt
                            -> InputT m (Maybe String)
getInputLine prefix = do
    isTerm <- liftIO $ hIsTerminalDevice stdin
    if isTerm
        then getInputCmdLine prefix
        else do
            atEOF <- liftIO $ hIsEOF stdin
            if atEOF
                then return Nothing
                else liftM Just $ liftIO $ hGetLine stdin

getInputCmdLine :: forall m . MonadException m => String -> InputT m (Maybe String)
getInputCmdLine prefix = do
-- TODO: Cache the terminal, actions
    emode <- asks (\prefs -> case editMode prefs of
                    Vi -> viActions
                    Emacs -> emacsCommands)
    settings :: Settings m <- ask
    wrapTerminalOps $ do
        let ls = emptyIM
        run@RunTerm {withGetEvent = withGetEvent', runTerm=runTerm'} <- liftIO $ myRunTerm
        layout <- liftIO $ getLayout run
        result <- runInputCmdT layout $ do
                    runTerm' $ withGetEvent' (handleSigINT settings) 
                        $ \getEvent -> do
                            drawLine prefix ls 
                            repeatTillFinish getEvent prefix ls emode
        case result of 
            Just line | not (all isSpace line) -> addHistory line
            _ -> return ()
        return result

repeatTillFinish :: forall m s d 
    . (MonadTrans d, Term (d m), MonadIO m, LineState s, MonadReader Prefs m)
            => d m Event -> String -> s -> KeyMap m s 
            -> d m (Maybe String)
repeatTillFinish getEvent prefix = loop
    where 
        -- NOTE: since the functions in this mutually recursive binding group do not have the 
        -- same contexts, we need the -XGADTs flag (or -fglasgow-exts)
        loop :: forall t . LineState t => t -> KeyMap m t -> d m (Maybe String)
        loop s processor = do
                event <- getEvent
                case event of
                    SigInt -> do
                        moveToNextLine s
                        liftIO $ Exception.evaluate (Exception.throwDyn Interrupt)
                    WindowResize newLayout -> 
                        withReposition newLayout (loop s processor)
                    KeyInput k -> case lookupKM processor k of
                        Nothing -> actBell >> loop s processor
                        Just g -> case g s of
                            Left r -> moveToNextLine s >> return r
                            Right f -> do
                                        KeyAction effect next <- lift f
                                        drawEffect prefix s effect
                                        loop (effectState effect) next

{-- 
Note why it is necessary to integrate ctrl-c handling with this module:
if the user is in the middle of a few wrapped lines, we want to clean up
by moving the cursor to the start of the following line.
--}

data Interrupt = Interrupt
                deriving (Show,Typeable,Eq)

-- | Catch and handle an exception of type 'Interrupt'.
handleInterrupt :: MonadException m => m a 
                        -- ^ Handler to run if Ctrl-C is pressed
                     -> m a -- ^ Computation to run
                     -> m a
handleInterrupt f = handle $ \e -> case Exception.dynExceptions e of
                    Just dyn | Just Interrupt <- fromDynamic dyn -> f
                    _ -> throwIO e



drawEffect :: (LineState s, LineState t, Term (d m), 
                MonadTrans d, MonadReader Prefs m) 
    => String -> s -> Effect t -> d m ()
drawEffect prefix s (Redraw shouldClear t) = if shouldClear
    then clearLayout >> drawLine prefix t
    else clearLine prefix s >> drawLine prefix t
drawEffect prefix s (Change t) = drawLineDiff prefix s t
drawEffect prefix s (PrintLines ls t) = do
    if isTemporary s
        then clearLine prefix s
        else moveToNextLine s
    printLines ls
    drawLine prefix t
drawEffect _ _ (RingBell _) = actBell

drawLine :: (LineState s, Term m) => String -> s -> m ()
drawLine prefix s = drawLineDiff prefix Cleared s

clearLine :: (LineState s, Term m) => String -> s -> m ()
clearLine prefix s = drawLineDiff prefix s Cleared
        
actBell :: (Term (d m), MonadTrans d, MonadReader Prefs m) => d m ()
actBell = do
    style <- lift (asks bellStyle)
    case style of
        NoBell -> return ()
        VisualBell -> ringBell False
        AudibleBell -> ringBell True
