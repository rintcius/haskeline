module System.Console.Haskeline.Backend.Win32(
                win32Term
                )where


import System.IO
import qualified System.IO.UTF8 as UTF8
import Foreign.Ptr
import Foreign.Storable
import Foreign.Marshal.Alloc
import Foreign.Marshal.Array
import Foreign.C.Types
import Foreign.Marshal.Utils
import System.Win32.Types
import Graphics.Win32.Misc(getStdHandle, sTD_INPUT_HANDLE, sTD_OUTPUT_HANDLE)
import System.Win32.File
import Data.List(intercalate)
import Control.Concurrent hiding (throwTo)
import Control.Concurrent.STM
import Data.Bits

import System.Console.Haskeline.Key
import System.Console.Haskeline.Monads
import System.Console.Haskeline.LineState
import System.Console.Haskeline.Term

#include "win_console.h"

foreign import stdcall "windows.h ReadConsoleInputW" c_ReadConsoleInput
    :: HANDLE -> Ptr () -> DWORD -> Ptr DWORD -> IO Bool
    
foreign import stdcall "windows.h WaitForSingleObject" c_WaitForSingleObject
    :: HANDLE -> DWORD -> IO DWORD

getEvent :: HANDLE -> IO Event
getEvent h = newTChanIO >>= keyEventLoop eventIntoChan
  where
    eventIntoChan tchan = eventLoop h >>= atomically . writeTChan tchan

eventLoop :: HANDLE -> IO Event
eventLoop h = do
    let waitTime = 500 -- milliseconds
    ret <- c_WaitForSingleObject h waitTime
    yield -- otherwise, the above foreign call causes the loop to never 
          -- respond to the killThread
    if ret /= (#const WAIT_OBJECT_0)
        then eventLoop h
        else do
            e <- readEvent h
            case eventToKey e of
	        Just k -> return (KeyInput k)
    	        Nothing -> eventLoop h
                       
getConOut :: IO (Maybe HANDLE)
getConOut = handle (\(_::IOException) -> return Nothing) $ fmap Just
    $ createFile "CONOUT$" (gENERIC_READ .|. gENERIC_WRITE)
                        (fILE_SHARE_READ .|. fILE_SHARE_WRITE) Nothing
                    oPEN_EXISTING 0 Nothing


eventToKey :: InputEvent -> Maybe Key
eventToKey KeyEvent {keyDown = True, unicodeChar = c, virtualKeyCode = vc,
                    controlKeyState = cstate}
        = let modifier = if isMeta then Key (Just Meta) else simpleKey
          in fmap modifier maybeKey
  where
    maybeKey = if c /= '\NUL' 
                    then Just (KeyChar c)
                    else keyFromCode vc
    isMeta = 0 /= (cstate .&. (#const RIGHT_ALT_PRESSED
                                    .|. #const LEFT_ALT_PRESSED) )
eventToKey _ = Nothing

keyFromCode :: WORD -> Maybe BaseKey
keyFromCode (#const VK_BACK) = Just Backspace
keyFromCode (#const VK_LEFT) = Just LeftKey
keyFromCode (#const VK_RIGHT) = Just RightKey
keyFromCode (#const VK_UP) = Just UpKey
keyFromCode (#const VK_DOWN) = Just DownKey
keyFromCode (#const VK_DELETE) = Just Delete
keyFromCode (#const VK_HOME) = Just Home
keyFromCode (#const VK_END) = Just End
-- TODO: KillLine
keyFromCode _ = Nothing
    
data InputEvent = KeyEvent {keyDown :: BOOL,
                          repeatCount :: WORD,
                          virtualKeyCode :: WORD,
                          virtualScanCode :: WORD,
                          unicodeChar :: Char,
                          controlKeyState :: DWORD}
            -- TODO: WINDOW_BUFFER_SIZE_RECORD
            -- I cant figure out how the user generates them.
           | OtherEvent
                        deriving Show

readEvent :: HANDLE -> IO InputEvent
readEvent h = allocaBytes (#size INPUT_RECORD) $ \pRecord -> 
                        alloca $ \numEventsPtr -> do
    failIfFalse_ "ReadConsoleInput" 
        $ c_ReadConsoleInput h pRecord 1 numEventsPtr
    -- useful? numEvents <- peek numEventsPtr
    eventType :: WORD <- (#peek INPUT_RECORD, EventType) pRecord
    let eventPtr = (#ptr INPUT_RECORD, Event) pRecord
    case eventType of
        (#const KEY_EVENT) -> getKeyEvent eventPtr
        _ -> return OtherEvent
        
getKeyEvent :: Ptr () -> IO InputEvent
getKeyEvent p = do
    kDown' <- (#peek KEY_EVENT_RECORD, bKeyDown) p
    repeat' <- (#peek KEY_EVENT_RECORD, wRepeatCount) p
    keyCode <- (#peek KEY_EVENT_RECORD, wVirtualKeyCode) p
    scanCode <- (#peek KEY_EVENT_RECORD, wVirtualScanCode) p
    char :: CWchar <- (#peek KEY_EVENT_RECORD, uChar) p
    state <- (#peek KEY_EVENT_RECORD, dwControlKeyState) p
    return KeyEvent {keyDown = kDown',
                            repeatCount = repeat',
                            virtualKeyCode = keyCode,
                            virtualScanCode = scanCode,
                            unicodeChar = toEnum (fromEnum char),
                            controlKeyState = state}

data Coord = Coord {coordX, coordY :: Int}
                deriving Show
                
instance Storable Coord where
    sizeOf _ = (#size COORD)
    alignment = undefined -- ???
    peek p = do
        x :: CShort <- (#peek COORD, X) p
        y :: CShort <- (#peek COORD, Y) p
        return Coord {coordX = fromEnum x, coordY = fromEnum y}
    poke p c = do
        (#poke COORD, X) p (toEnum (coordX c) :: CShort)
        (#poke COORD, Y) p (toEnum (coordY c) :: CShort)
                
                            
foreign import ccall "SetPosition"
    c_SetPosition :: HANDLE -> Ptr Coord -> IO Bool
    
setPosition :: HANDLE -> Coord -> IO ()
setPosition h c = with c $ failIfFalse_ "SetConsoleCursorPosition" 
                    . c_SetPosition h
                    
foreign import stdcall "windows.h GetConsoleScreenBufferInfo"
    c_GetScreenBufferInfo :: HANDLE -> Ptr () -> IO Bool
    
getPosition :: HANDLE -> IO Coord
getPosition = withScreenBufferInfo $ 
    (#peek CONSOLE_SCREEN_BUFFER_INFO, dwCursorPosition)

withScreenBufferInfo :: (Ptr () -> IO a) -> HANDLE -> IO a
withScreenBufferInfo f h = allocaBytes (#size CONSOLE_SCREEN_BUFFER_INFO)
                                $ \infoPtr -> do
        failIfFalse_ "GetConsoleScreenBufferInfo"
            $ c_GetScreenBufferInfo h infoPtr
        f infoPtr

getBufferSize :: HANDLE -> IO Layout
getBufferSize = withScreenBufferInfo $ \p -> do
    c <- (#peek CONSOLE_SCREEN_BUFFER_INFO, dwSize) p
    return Layout {width = coordX c, height = coordY c}

foreign import stdcall "windows.h WriteConsoleW" c_WriteConsoleW
    :: HANDLE -> Ptr TCHAR -> DWORD -> Ptr DWORD -> Ptr () -> IO Bool

writeConsole :: HANDLE -> String -> IO ()
-- For some reason, Wine returns False when WriteConsoleW is called on an empty
-- string.  Easiest fix: just don't call that function.
writeConsole _ "" = return ()
writeConsole h str = withArray tstr $ \t_arr -> alloca $ \numWritten -> do
    failIfFalse_ "WriteConsole" 
        $ c_WriteConsoleW h t_arr (toEnum $ length str) numWritten nullPtr
  where
    tstr = map (toEnum . fromEnum) str

foreign import stdcall "windows.h MessageBeep" c_messageBeep :: UINT -> IO Bool

messageBeep :: IO ()
messageBeep = c_messageBeep (-1) >> return ()-- intentionally ignore failures.

----------------------------
-- Drawing

newtype Draw m a = Draw {runDraw :: ReaderT HANDLE m a}
    deriving (Monad,MonadIO,MonadException, MonadReader HANDLE)

instance MonadTrans Draw where
    lift = Draw . lift

instance MonadReader Layout m => MonadReader Layout (Draw m) where
    ask = lift ask
    local r = Draw . local r . runDraw

getPos :: MonadIO m => Draw m Coord
getPos = ask >>= liftIO . getPosition
    
setPos :: MonadIO m => Coord -> Draw m ()
setPos c = do
    h <- ask
    liftIO (setPosition h c)

printText :: MonadIO m => String -> Draw m ()
printText txt = do
    h <- ask
    liftIO (writeConsole h txt)
    
printAfter :: MonadLayout m => String -> Draw m ()
printAfter str = do
    p <- getPos
    printText str
    setPos p
    
drawLineDiffWin :: MonadLayout m => LineChars -> LineChars -> Draw m ()
drawLineDiffWin (xs1,ys1) (xs2,ys2) = case matchInit xs1 xs2 of
    ([],[])     | ys1 == ys2            -> return ()
    (xs1',[])   | xs1' ++ ys1 == ys2    -> movePos $ negate $ length xs1'
    ([],xs2')   | ys1 == xs2' ++ ys2    -> movePos $ length xs2'
    (xs1',xs2')                         -> do
        movePos (negate $ length xs1')
        let m = length xs1' + length ys1 - (length xs2' + length ys2)
        let deadText = replicate m ' '
        printText xs2'
        printAfter (ys2 ++ deadText)

movePos :: MonadLayout m => Int -> Draw m ()
movePos n = do
    Coord {coordX = x, coordY = y} <- getPos
    w <- asks width
    let (h,x') = divMod (x+n) w
    setPos Coord {coordX = x', coordY = y+h}

crlf :: String
crlf = "\r\n"

instance (MonadException m, MonadLayout m) => Term (Draw m) where
    drawLineDiff = drawLineDiffWin
    reposition _ _ = return () -- TODO when we capture resize events.

    printLines [] = return ()
    printLines ls = printText $ intercalate crlf ls ++ crlf
    
    clearLayout = do
        lay <- ask
        setPos (Coord 0 0)
        printText (replicate (width lay * height lay) ' ')
        setPos (Coord 0 0)
    
    moveToNextLine s = do
        movePos (lengthToEnd s)
        printText "\r\n" -- make the console take care of creating a new line
    
    ringBell True = liftIO messageBeep
    ringBell False = return () -- TODO

win32Term :: IO RunTerm
win32Term = do
    inIsTerm <- hIsTerminalDevice stdin
    putter <- putOut
    if not inIsTerm
        then fileRunTerm
        else do
            oterm <- getConOut
            case oterm of
                Nothing -> fileRunTerm
                Just h -> return RunTerm {
                            putStrOut = putter,
                            wrapInterrupt = withCtrlCHandler,
                            termOps = Just TermOps {
                                            getLayout = getBufferSize h,
                                            runTerm = consoleRunTerm h},
                            closeTerm = closeHandle h}

consoleRunTerm :: HANDLE -> RunTermType
consoleRunTerm conOut f = do
    inH <- liftIO $ getStdHandle sTD_INPUT_HANDLE
    runReaderT' conOut $ runDraw $ f $ liftIO $ getEvent inH

-- stdin is not a terminal, but we still need to check the right way to output unicode to stdout.
fileRunTerm :: IO RunTerm
fileRunTerm = do
    putter <- putOut
    return RunTerm {termOps = Nothing,
                    closeTerm = return (),
                    putStrOut = putter,
                    wrapInterrupt = withCtrlCHandler}

-- On Windows, Unicode written to the console must be written with the WriteConsole API call.
-- And to make the API cross-platform consistent, Unicode to a file should be UTF-8.
putOut :: IO (String -> IO ())
putOut = do
    outIsTerm <- hIsTerminalDevice stdout
    if outIsTerm
        then do
            h <- getStdHandle sTD_OUTPUT_HANDLE
            return (writeConsole h)
        else return $ \str -> UTF8.putStr str >> hFlush stdout
                
    

type Handler = DWORD -> IO BOOL

foreign import ccall "wrapper" wrapHandler :: Handler -> IO (FunPtr Handler)

foreign import stdcall "windows.h SetConsoleCtrlHandler" c_SetConsoleCtrlHandler
    :: FunPtr Handler -> BOOL -> IO BOOL

-- sets the tv to True when ctrl-c is pressed.
withCtrlCHandler :: MonadException m => m a -> m a
withCtrlCHandler f = bracket (liftIO $ do
                                    tid <- myThreadId
                                    fp <- wrapHandler (handler tid)
                                    c_SetConsoleCtrlHandler fp True
                                    return fp)
                                (\fp -> liftIO $ c_SetConsoleCtrlHandler fp False)
                                (const f)
  where
    handler tid (#const CTRL_C_EVENT) = do
        throwTo tid Interrupt
        return True
    handler _ _ = return False
