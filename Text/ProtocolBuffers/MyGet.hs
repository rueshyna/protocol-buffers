{-# LANGUAGE CPP,MagicHash,ScopedTypeVariables,FlexibleInstances,MultiParamTypeClasses,TypeSynonymInstances,RankNTypes #-}
--
-- By Chris Kuklewicz, drawing heavily from binary and binary-strict,
-- but all the bugs are my own.
--
-- This file is under the usual BSD3 licence, copyright 2008.
--
-- There is a sibling to this module (once called "MyGetW") that does have
-- MonadCont instances and machinery, and therefore does not hide the
-- "b" type variable with the forall.
--
-- This started out as an improvement to
-- Data.Binary.Stric.IncrementalGet with slightly better internals.
-- The simplified 'Get', 'runGet', 'Result' trio with the
-- 'Data.Binary.Strict.Class.BinaryParser' instance are an _untested_
-- upgrade from IncrementalGet.  Especially untested are the
-- strictness properties.
--
-- 'Get' usefully implements Applicative and Monad, MonadError,
-- Alternative and MonadPlus.  Unhandled errors are reported along with
-- the number of bytes successfully consumed.
-- 
-- The 'CompGet' monad transformer (with 'runCompGet' and
-- 'CompResult') has those and also useful MonadReader, MonadWriter,
-- and MonadState implementations.  Output to the writer and changes
-- to the user State are thrown away when fail/throwError/mzero is
-- called.  Effects of 'suspend' and 'putAvailable' are visible after
-- fail/throwError/mzero.
--
-- Each time the parser reaches the end of the input it will return a
-- Partial or CPartial wrapped continuation which requests a (Maybe
-- Lazy.ByteString).  Passing (Just bs) will append bs to the input so
-- far and continue processing.  If you pass Nothing to the
-- continuation then you are declaring that there will never be more
-- input and that the parser should never again return a partial
-- contination; it should return failure or finished.
--
-- 'suspendUntilComplete' repeatedly uses a partial continuation to
-- ask for more input until Nothing is passed and then it proceeds
-- with parsing.
--
-- The 'getAvailable' command returns the lazy byte string the parser
-- has remaining before calling 'suspend'.  The 'putAvailable'
-- replaces this input and is a bit fancy: it also replaces the input
-- at the current offset for all the potential catchError/mplus
-- handlers.  This change is _not_ reverted by fail/throwError/mzero.
--
-- The three 'lookAhead' and 'lookAheadM' and 'lookAheadE' functions are
-- the same as the ones in binary's Data.Binary.Get.
--
-- A useful upgrade would be to "reverse the order" of the MonadWriter
-- and MonadSuspend and allow IPartial to carry the monoid-so-far to
-- the caller.  This would allow for reporting of results-to-date when
-- suspending.  Making this work with MonadWriter's 'pass' semantics
-- is hard -- perhaps a simpler Monad should be used in place of
-- MonadWriter to yield a stream of results.
--
module Text.ProtocolBuffers.MyGet
    (Get,runGet,Result(..)
    ,CompGet,runCompGet,CompResult(..)
     -- main primitives
    ,ensureBytes,getStorable,getLazyByteString,suspendUntilComplete
     -- parser state manipulation
    ,getAvailable,putAvailable
     -- lookAhead capabilities
    ,lookAhead,lookAheadM,lookAheadE
     -- below is for implementation of BinaryParser (for Int64 and Lazy bytestrings)
    ,skip,bytesRead,isEmpty,remaining,spanOf
    ,getWord8,getByteString
    ,getWord16be,getWord32be,getWord64be
    ,getWord16le,getWord32le,getWord64le
    ,getWordhost,getWord16host,getWord32host,getWord64host
    ) where

-- The InternalGet monad is an instance of binary-strict's BinaryParser:
import qualified Data.Binary.Strict.Class as P(BinaryParser(..))
-- The InternalGet monad is an instance of all of these library classes:
import Control.Applicative(Applicative(pure,(<*>)),Alternative(empty,(<|>)))
import Control.Monad(MonadPlus(mzero,mplus))
import Control.Monad.Error.Class(MonadError(throwError,catchError),Error(strMsg))
import Control.Monad.Reader.Class(MonadReader(ask,local))
import Control.Monad.State.Class(MonadState(get,put))
import Control.Monad.Trans(MonadTrans(lift),MonadIO(liftIO))
import Control.Monad.Writer.Class(MonadWriter(tell,listen,pass))
-- It can be a MonadCont, but the semantics are too broken without a ton of work.

-- implementation imports
import Control.Monad(liftM,ap)                       -- instead of Functor.fmap; ap for Applicative
import Control.Monad(replicateM,(>=>))               -- XXX testing
import Control.Monad.Identity(Identity,runIdentity)  -- Get is a transformed Identity monad
import Data.Bits(Bits((.|.)))
import qualified Data.ByteString as S(concat,length,null,splitAt)
import qualified Data.ByteString as S(unpack) -- XXX testing
import qualified Data.ByteString.Internal as S(ByteString,toForeignPtr,inlinePerformIO)
import qualified Data.ByteString.Unsafe as S(unsafeIndex)
import qualified Data.ByteString.Lazy as L(take,drop,length,span,toChunks,fromChunks,null)
import qualified Data.ByteString.Lazy as L(pack) -- XXX testing
import qualified Data.ByteString.Lazy.Internal as L(ByteString(..),chunk)
import qualified Data.Foldable as F(foldr,foldr1)    -- used with Seq
import Data.Int(Int64)                               -- index type for L.ByteString
import Data.Monoid(Monoid(mempty,mappend))           -- Writer has a Monoid contraint
import Data.Sequence(Seq,null,(|>))                  -- used for future queue in handler state
import Data.Word(Word,Word8,Word16,Word32,Word64)
import Foreign.ForeignPtr(withForeignPtr)
import Foreign.Ptr(castPtr,plusPtr)
import Foreign.Storable(Storable(peek,sizeOf))
#if defined(__GLASGOW_HASKELL__) && !defined(__HADDOCK__)
import GHC.Base(Int(..),uncheckedShiftL#)
import GHC.Word(Word16(..),Word32(..),Word64(..),uncheckedShiftL64#)
#endif

-- Simple external return type
data Result a = Failed {-# UNPACK #-} !Int64 String
              | Finished {-# UNPACK #-} !L.ByteString {-# UNPACK #-} !Int64 a
              | Partial (Maybe L.ByteString -> Result a)

-- Complex external return type
data CompResult w user m a = CFailed {-# UNPACK #-} !Int64 String
                           | CFinished {-# UNPACK #-} !L.ByteString {-# UNPACK #-} !Int64 w user a
                           | CPartial (Maybe L.ByteString -> m (CompResult w user m a))

-- Internal type, converted to an external type before returning to caller.
data IResult w user m a = IFailed {-# UNPACK #-} !Int64 String
                        | IFinished w {-# UNPACK #-} !(S user) a
                        | IPartial (Maybe L.ByteString -> m (IResult w user m a))

-- Internal state type, not exposed to the user.
data S user = S { top :: {-# UNPACK #-} !S.ByteString
                , current :: {-# UNPACK #-} !L.ByteString
                , consumed :: {-# UNPACK #-} !Int64
                , userField :: user
                }
  deriving Show

-- Private Internal error handling stack type
-- This must NOT be exposed by this module
--
-- The ErrorFrame is the top-level error handler setup when execution begins.
-- It starts with the Bool set to True: meaning suspend can ask for more input.
-- Once suspend get 'Nothing' in reply the Bool is set to False, which means
-- that 'suspend' should no longer ask for input -- the input is finished.
-- Why store the Bool there?  It was handy when I needed to add it.
data FrameStack b e w user m = ErrorFrame (e -> (S user) -> m (IResult w user m b)) -- top level handler
                                          Bool -- True at start, False if Nothing passed to suspend continuation
                             | HandlerFrame ( (S user) -> FrameStack b e w user m
                                              -> e -> m (IResult w user m b) )  -- encapsulated handler
                                       (S user)  -- stored state to pass to handler
                                       (Seq L.ByteString)  -- additional input to hass to handler
                                       (FrameStack b e w user m)  -- earlier/deeper/outer handlers
                             | FutureFrame (S user) (Seq L.ByteString) (FrameStack b e w user m) -- for look ahead

type Success b e r w user m a =
       (a -> r -> w -> (S user) -> FrameStack b e w user m -> m (IResult w user m b))

-- Internal monad type
newtype InternalGet e r w user m a = InternalGet {
  unInternalGet :: forall b.                 -- the forall hides the CPS style (and prevents use of MonadCont)
                   Success b e r w user m a  -- main continuation
                -> r                         -- reader
                -> w                         -- log so far
                -> (S user)                  -- state
                -> FrameStack b e w user m   -- error handler stack
                -> m (IResult w user m b)    -- operation
    }

-- Complex external monad type
type CompGet r w user m = InternalGet String r w user m

-- Simple external monad type
type Get = CompGet () () () Identity


-- These implement the checkponting needed to store and revive the
-- state for lookAhead.  They are fragile because the setCheckpoint
-- must preceed either useCheckpoint or clearCheckpoint but not both.
-- The FutureFrame must be the most recent handler, so the commands
-- must be in the same scope depth.  Because of these constraints, the reader
-- value 'r' does not need to be stored and can be taken from the InternalGet
-- parameter.
--
-- IMPORTANT: Any FutureFrame at the top level(s) is discarded by throwError.
setCheckpoint = InternalGet $ \ sc r w s pc -> sc () r w s (FutureFrame s mempty pc)
useCheckpoint = InternalGet $ \ sc r w (S _ _ _ user) (FutureFrame s future pc) ->
  let (S ss bs n _) = collect s future
  in sc () r w (S ss bs n user) pc
clearCheckpoint = InternalGet $ \ sc r w s (FutureFrame _s _future pc) -> sc () r w s pc

-- | 'lookAhead' runs the @todo@ action and then rewinds only the
-- BinaryParser state.  Any new input from 'suspend' or changes from
-- 'putAvailable' are kept.  Changes to the user state (MonadState)
-- are kept.  The MonadWriter output is retained.
--
-- If an error is thrown then the entire monad state is reset to last
-- catchError as usual.
lookAhead :: (Monad m, Error e) => InternalGet e r w user m a -> InternalGet e r w user m a
lookAhead todo = do
  setCheckpoint
  a <- todo
  useCheckpoint
  return a

-- | 'lookAheadM' runs the @todo@ action. If the action returns 'Nothing' then the 
-- BinaryParser state is rewound (as in 'lookAhead').  If the action return 'Just' then
-- the BinaryParser is not rewound, and lookAheadM acts as an identity.
--
-- If an error is thrown then the entire monad state is reset to last
-- catchError as usual.
lookAheadM :: (Monad m, Error e) => InternalGet e r w user m (Maybe a) -> InternalGet e r w user m (Maybe a)
lookAheadM todo = do
  checkpoint <- setCheckpoint
  a <- todo
  maybe useCheckpoint (\_ -> clearCheckpoint) a
  return a

-- | 'lookAheadE' runs the @todo@ action. If the action returns 'Left' then the 
-- BinaryParser state is rewound (as in 'lookAhead').  If the action return 'Right' then
-- the BinaryParser is not rewound, and lookAheadE acts as an identity.
--
-- If an error is thrown then the entire monad state is reset to last
-- catchError as usual.
lookAheadE :: (Monad m, Error e) => InternalGet e r w user m (Either a b) -> InternalGet e r w user m (Either a b)
lookAheadE todo = do
  checkpoint <- setCheckpoint
  a <- todo
  either (\_ -> useCheckpoint) (\_ -> clearCheckpoint) a
  return a

-- 'collect' is used by 'putCheckpoint' and 'throwError'
collect :: (S user) -> Seq L.ByteString -> (S user)
collect s@(S ss bs n user) future | Data.Sequence.null future = s
                                  | otherwise = S ss (mappend bs (F.foldr1 mappend future)) n user

-- Put the Show instances here

instance (Show a) => Show (Result a) where
  showsPrec _ (Failed n msg) = ("(Failed "++) . shows n . (' ':) . shows msg . (")"++)
  showsPrec _ (Finished bs n a) =
    ("(CFinished ("++) 
    . shows bs . (") ("++)
    . shows n . (") ("++) 
    . shows a . ("))"++)
  showsPrec _ (Partial {}) = ("(Partial <Maybe Data.ByteString.Lazy.ByteString-> Result a)"++)

instance (Show w, Show user, Show a) => Show (CompResult w user m a) where
  showsPrec _ (CFailed n msg) = ("(CFailed "++) . shows n . (' ':). shows msg . (")"++)
  showsPrec _ (CFinished bs n w user a) =
    ("(CFinished ("++) 
    . shows bs . (") "++)
    . shows n . (" ("++) 
    . shows w . (") ("++) 
    . shows user . (") ("++)
    . shows a . ("))"++)
  showsPrec _ (CPartial {}) = ("(CPartial <Maybe Data.ByteString.Lazy.ByteString->IO (CompResult w user m a))"++)

instance (Show user, Show a, Show w) => Show (IResult w user m a) where
  showsPrec _ (IFailed n msg) = ("(IFailed "++) . shows n . (' ':). shows msg . (")"++)
  showsPrec _ (IFinished w s a) =
    ("(IFinished ("++)
    . shows w . (") ("++)
    . shows s . (") ("++)
    . shows a . ("))"++)
  showsPrec _ (IPartial {}) = ("(IPartial <MaybeData.ByteString.Lazy.ByteString->IO (IResult w user m a))"++)

instance Show user => Show (FrameStack b e w user m) where
  showsPrec _ (ErrorFrame _ p) =(++) "(ErrorFrame <e->s->m b> " . shows p . (")"++)
  showsPrec _ (HandlerFrame _ s future pc) = ("(HandlerFrame <> ("++)
                                     . shows s . (") ("++) . shows future . (") ("++)
                                     . shows pc . (")"++)
  showsPrec _ (FutureFrame s future pc) =  ("(FutureFrame <s->FrameStack b e s m->e->m b> ("++)
                                     . shows s . (") ("++) . shows future . (") ("++)
                                     . shows pc . (")"++)

-- | 'runCompGet' is the complex executor
runCompGet :: (Monad m,Monoid w)
            => CompGet r w user m a
            -> r -> user -> L.ByteString
            -> m (CompResult w user m a)
runCompGet g rIn userIn bsIn = liftM convert (unGet g sIn scIn)
  where sIn = case bsIn of L.Empty -> S mempty mempty 0 userIn
                           L.Chunk ss bs -> S ss bs 0 userIn
        scIn a _r w sOut _pc = return (IFinished w sOut a)
        unGet (InternalGet f) s sc = f sc rIn mempty s (ErrorFrame returnError True)
            where returnError msg sOut = return (IFailed (consumed sOut) msg)
        convert :: (Monad m) => IResult w user m a -> CompResult w user m a
        convert (IFailed n msg) = CFailed n msg
        convert (IFinished w (S ss bs n user) a) = CFinished (L.chunk ss bs) n w user a
        convert (IPartial f) = CPartial (\bs -> liftM convert (f bs))

-- | 'runGet' is the simple executor
runGet :: Get a -> L.ByteString -> Result a
runGet g bsIn = convert (runIdentity (unGet g sIn scIn))
  where sIn = case bsIn of L.Empty -> S mempty mempty 0 ()
                           L.Chunk ss bs -> S ss bs 0 ()
        scIn a _r w sOut _pc = return (IFinished w sOut a)
        unGet (InternalGet f) s sc = f sc mempty mempty s (ErrorFrame ec True)
            where ec msg sOut = return (IFailed (consumed sOut) msg)

        convert :: IResult () () Identity a -> Result a
        convert (IFailed n msg) = Failed n msg
        convert (IFinished _ (S ss bs n _) a) = Finished (L.chunk ss bs) n a
        convert (IPartial f) = Partial (\bs -> convert (runIdentity (f bs)))

-- | Get the input currently available to the parser.
getAvailable :: InternalGet e r w user m L.ByteString
getAvailable = InternalGet $ \ sc r w s@(S ss bs _ _) pc -> sc (L.chunk ss bs) r w s pc

-- | 'putAvailable' replaces the bytestream past the current # of read
-- bytes.  This will also affect pending MonadError handler and
-- MonadPlus branches.  I think all pending branches have to have
-- fewer bytesRead than the current one.  If this is wrong then an
-- error will be thrown.
--
-- WARNING : 'putAvailable' is still untested.
putAvailable :: L.ByteString -> InternalGet e r w user m ()
putAvailable bsNew = InternalGet $ \ sc r w (S _ss _bs n user) pc ->
  let s' = case bsNew of
             L.Empty -> S mempty mempty n user
             L.Chunk ss' bs' -> S ss' bs' n user
      rebuild (HandlerFrame catcher (S ss1 bs1 n1 user1) future pc') =
               HandlerFrame catcher sNew mempty (rebuild pc')
        where balance = n - n1
              whole | balance < 0 = error "Impossible? Cannot rebuild HandlerFrame in MyGet.putAvailable: balance is negative!"
                    | otherwise = L.take balance $ L.chunk ss1 bs1 `mappend` F.foldr mappend mempty future
              sNew | balance /= L.length whole = error "Impossible? MyGet.putAvailable.rebuild.sNew HandlerFrame assertion failed."
                   | otherwise = case mappend whole bsNew of
                                   L.Empty -> S mempty mempty n1 user1
                                   L.Chunk ss2 bs2 -> S ss2 bs2 n1 user1
      rebuild (FutureFrame (S ss1 bs1 n1 user1) future pc') =
               FutureFrame sNew mempty (rebuild pc')
        where balance = n - n1
              whole | balance < 0 = error "Impossible? Cannot rebuild FutureFrame in MyGet.putAvailable: balance is negative!"
                    | otherwise = L.take balance $ L.chunk ss1 bs1 `mappend` F.foldr mappend mempty future
              sNew | balance /= L.length whole = error "Impossible? MyGet.putAvailable.rebuild.sNew FutureFrame assertion failed."
                   | otherwise = case mappend whole bsNew of
                                   L.Empty -> S mempty mempty n1 user1
                                   L.Chunk ss2 bs2 -> S ss2 bs2 n1 user1
      rebuild x@(ErrorFrame {}) = x
  in sc () r w s' (rebuild pc)

-- Internal access to full internal state, as helepr functions
getFull :: InternalGet e r w user m (S user)
getFull = InternalGet $ \ sc r w s pc -> sc s r w s pc
putFull :: (S user) -> InternalGet e r w user m ()
putFull s = InternalGet $ \ sc r w _s pc -> sc () r w s pc

-- | Keep calling 'suspend' until Nothing is passed to the 'Partial'
-- continuation.  This ensures all the data has been loaded into the
-- state of the parser.
suspendUntilComplete :: ({-Show user,-} Monad m) => CompGet r w user m ()
suspendUntilComplete = do
  continue <- suspend
  if continue then suspendUntilComplete
    else return ()

-- | Call suspend and throw and error with the provided @msg@ if
-- Nothing has been passed to the 'Partial' continuation.  Otherwise
-- return ().
suspendMsg :: ({-Show user,-} Monad m) => String -> CompGet r w user m ()
suspendMsg msg = do continue <- suspend
                    if continue then return ()
                      else throwError msg

-- | check that there are at least @n@ bytes available in the input.
-- This will suspend if there is to little data.
ensureBytes :: ({-Show user,-} Monad m) => Int64 -> CompGet r w user m ()
ensureBytes n = do
  (S ss bs _read _user) <- getFull
  if n < fromIntegral (S.length ss)
    then return ()
    else do if n == L.length (L.take n (L.chunk ss bs))
              then return ()
              else suspendMsg "ensureBytes failed" >> ensureBytes n
{-# INLINE ensureBytes #-}

-- | Pull @n@ bytes from the unput, as a lazy ByteString.  This will
-- suspend if there is too little data.
getLazyByteString :: ({-Show user,-} Monad m)=> Int64 -> CompGet r w user m L.ByteString
getLazyByteString n | n<=0 = return mempty
                    | otherwise = do
  (S ss bs offset user) <- getFull
  case splitAtOrDie n (L.chunk ss bs) of
    Just (consume,rest) ->do
       case rest of
         L.Empty -> putFull (S mempty mempty (offset + n) user)
         L.Chunk ss' bs' -> putFull (S ss' bs' (offset + n) user)
       return consume
    Nothing -> suspendMsg "getLazyByteString failed" >> getLazyByteString n
{-# INLINE getLazyByteString #-} -- important

-- | 'suspend' is supposed to allow the execution of the monad to be
-- halted, awaiting more input.  The computation is supposed to
-- continue normally if this returns True, and is supposed to halt
-- without calling suspend again if this returns False.  All future
-- calls to suspend will return False automatically and no nothing
-- else.
--
-- These semantics are too specialized to let this escape this module.
class MonadSuspend m where
  suspend :: m Bool

-- The instance here is fairly specific to the stack manipluation done
-- by 'addFuture' to ('S' user) and to the packaging of the resumption
-- function in 'IResult'('IPartial').
instance (({-Show user,-} Monad m)) => MonadSuspend (InternalGet e r w user m) where
    suspend = InternalGet $ \ sc r w sIn pcIn ->
      if checkBool pcIn -- Has Nothing ever been given to a partial continuation?
        then let f Nothing = let pcOut = rememberFalse pcIn
                             in sc False r w sIn pcOut
                 f (Just bs') = let sOut = appendBS sIn bs'
                                    pcOut = addFuture bs' pcIn
                                in sc True r w sOut pcOut
             in return (IPartial f)
        else sc False r w sIn pcIn  -- once Nothing has been given suspend is a no-op
     where appendBS (S ss bs n user) bs' = S ss (mappend bs bs') n user
           -- addFuture puts the new data in 'future' where throwError's collect can find and use it
           addFuture bs (HandlerFrame catcher s future pc) =
                         HandlerFrame catcher s (future |> bs) (addFuture bs pc)
           addFuture bs (FutureFrame s future pc) =
                         FutureFrame s (future |> bs) (addFuture bs pc)
           addFuture _bs x@(ErrorFrame {}) = x
           -- Once suspend is given Nothing, it remembers this and always returns False
           checkBool (ErrorFrame _ b) = b
           checkBool (HandlerFrame _ _ _ pc) = checkBool pc
           checkBool (FutureFrame _ _ pc) = checkBool pc
           rememberFalse (ErrorFrame ec _) = ErrorFrame ec False
           rememberFalse (HandlerFrame catcher s future pc) =
                          HandlerFrame catcher s future (rememberFalse pc)
           rememberFalse (FutureFrame s future pc) =
                          FutureFrame s future (rememberFalse pc)
          
-- A unique sort of command...

-- | 'discardInnerHandler' causes the most recent catchError to be
-- discarded, i.e. this reduces the stack of error handlers by removing
-- the top one.  These are the same handlers which Alternative((<|>)) and
-- MonadPlus(mplus) use.  This is useful to commit to the current branch and let
-- the garbage collector release the suspended handler and its hold on
-- the earlier input.
discardInnerHandler :: ({-Show user,-} Monad m) => InternalGet e r w s m ()
discardInnerHandler = InternalGet $ \ sc r w s pcIn ->
  let pcOut = case pcIn of ErrorFrame {} -> pcIn
                           HandlerFrame _ _ _ pc' -> pc'
                           FutureFrame _ _ pc' -> pc'
  in sc () r w s pcOut
{-# INLINE discardInnerHandler #-}

-- | 'discardAllHandlers' causes all catchError handler to be
-- discarded, i.e. this reduces the stack of error handlers to the top
-- level handler.  These are the same handlers which Alternative((<|>))
-- and MonadPlus(mplus) use.  This is useful to commit to the current
-- branch and let the garbage collector release the suspended handlers
-- and their hold on the earlier input.
discardAllHandlers :: ({-Show user,-} Monad m) => InternalGet e r w s m ()
discardAllHandlers = InternalGet $ \ sc r w s pcIn ->
  let base pc@(ErrorFrame {}) = pc
      base (HandlerFrame _ _ _ pc) = base pc
      base (FutureFrame _ _ pc) = base pc
  in sc () r w s (base pcIn)
{-# INLINE discardAllHandlers #-}

-- The BinaryParser instance:

-- | Discard the next @m@ bytes
skip :: ({-Show user,-} Monad m) => Int64 -> CompGet r w user m ()
skip m | m <=0 = return ()
       | otherwise = do
  ensureBytes m
  (S ss bs n user) <- getFull
  case L.drop m (L.chunk ss bs) of
    L.Empty -> putFull (S mempty mempty (n+m) user)
    L.Chunk ss' bs' -> putFull (S ss' bs' (n+m) user)

-- | Return the number of 'bytesRead' so far.  Initially 0, never negative.
bytesRead :: ({-Show user,-} Monad m) => CompGet r w user m Int64
bytesRead = fmap consumed getFull

-- | Return the number of bytes 'remaining' before the current input
-- runs out and 'suspend' might be called.
remaining :: ({-Show user,-} Monad m) => CompGet r w user m Int64
remaining = do (S ss bs _ _) <- getFull
               return $ fromIntegral (S.length ss) + (L.length bs)

-- | Return True if the number of bytes 'remaining' is 0.  Any futher
-- attempts to read an empty parser will cal 'suspend'.
isEmpty :: ({-Show user,-} Monad m) => CompGet r w user m Bool
isEmpty = do (S ss bs _n _user) <- getFull
             return $ (S.null ss) && (L.null bs)

spanOf :: ({-Show user,-} Monad m) => (Word8 -> Bool) ->  CompGet r w user m (L.ByteString)
spanOf f = do let loop = do (S ss bs n user) <- getFull
                            let (pre,post) = L.span f (L.chunk ss bs)
                            case post of
                              L.Empty -> putFull (S mempty mempty (n + L.length pre) user)
                              L.Chunk ss' bs' -> putFull (S ss' bs' (n + L.length pre) user)
                            if L.null post
                              then fmap ((L.toChunks pre)++) $ do
                                     continue <- suspend
                                     if continue then loop
                                       else return (L.toChunks pre)
                              else return (L.toChunks pre)
              fmap L.fromChunks loop
{-# INLINE spanOf #-}

-- | Pull @n@ bytes from the input, as a strict ByteString.  This will
-- suspend if there is too little data.  If the result spans multiple
-- lazy chunks then the result occupies a freshly allocated strict
-- bytestring, otherwise it fits in a single chunk and refers to the
-- same immutable memory block as the whole chunk.
getByteString :: ({-Show user,-} Monad m) => Int -> CompGet r w user m S.ByteString
getByteString nIn | nIn <= 0 = return mempty
                  | otherwise = do
  (S ss bs n user) <- getFull
  if nIn < S.length ss
    then do let (pre,post) = S.splitAt nIn ss
            putFull (S post bs (n+fromIntegral nIn) user)
            return pre
    -- Expect nIn to be less than S.length ss the vast majority of times
    -- so do not worry about doing anything fancy here.
    else fmap (S.concat . L.toChunks) (getLazyByteString (fromIntegral nIn))
{-# INLINE getByteString #-} -- important

getWordhost :: ({-Show user,-} Monad m) => CompGet r w user m Word
getWordhost = getStorable
{-# INLINE getWordhost #-}

getWord8 :: ({-Show user,-} Monad m) => CompGet r w user m Word8
getWord8 = getPtr 1
{-# INLINE getWord8 #-}

getWord16be,getWord16le,getWord16host :: ({-Show user,-} Monad m) => CompGet r w user m Word16
getWord16be = do
    s <- getByteString 2
    return $! (fromIntegral (s `S.unsafeIndex` 0) `shiftl_w16` 8) .|.
              (fromIntegral (s `S.unsafeIndex` 1))
{-# INLINE getWord16be #-}
getWord16le = do
    s <- getByteString 2
    return $! (fromIntegral (s `S.unsafeIndex` 1) `shiftl_w16` 8) .|.
              (fromIntegral (s `S.unsafeIndex` 0) )
{-# INLINE getWord16le #-}
getWord16host = getStorable
{-# INLINE getWord16host #-}

getWord32be,getWord32le,getWord32host :: ({-Show user,-} Monad m) => CompGet r w user m Word32
getWord32be = do
    s <- getByteString 4
    return $! (fromIntegral (s `S.unsafeIndex` 0) `shiftl_w32` 24) .|.
              (fromIntegral (s `S.unsafeIndex` 1) `shiftl_w32` 16) .|.
              (fromIntegral (s `S.unsafeIndex` 2) `shiftl_w32`  8) .|.
              (fromIntegral (s `S.unsafeIndex` 3) )
{-# INLINE getWord32be #-}
getWord32le = do
    s <- getByteString 4
    return $! (fromIntegral (s `S.unsafeIndex` 3) `shiftl_w32` 24) .|.
              (fromIntegral (s `S.unsafeIndex` 2) `shiftl_w32` 16) .|.
              (fromIntegral (s `S.unsafeIndex` 1) `shiftl_w32`  8) .|.
              (fromIntegral (s `S.unsafeIndex` 0) )
{-# INLINE getWord32le #-}
getWord32host = getStorable
{-# INLINE getWord32host #-}


getWord64be,getWord64le,getWord64host :: ({-Show user,-} Monad m) => CompGet r w user m Word64
getWord64be = do
    s <- getByteString 8
    return $! (fromIntegral (s `S.unsafeIndex` 0) `shiftl_w64` 56) .|.
              (fromIntegral (s `S.unsafeIndex` 1) `shiftl_w64` 48) .|.
              (fromIntegral (s `S.unsafeIndex` 2) `shiftl_w64` 40) .|.
              (fromIntegral (s `S.unsafeIndex` 3) `shiftl_w64` 32) .|.
              (fromIntegral (s `S.unsafeIndex` 4) `shiftl_w64` 24) .|.
              (fromIntegral (s `S.unsafeIndex` 5) `shiftl_w64` 16) .|.
              (fromIntegral (s `S.unsafeIndex` 6) `shiftl_w64`  8) .|.
              (fromIntegral (s `S.unsafeIndex` 7) )
{-# INLINE getWord64be #-}
getWord64le = do
    s <- getByteString 8
    return $! (fromIntegral (s `S.unsafeIndex` 7) `shiftl_w64` 56) .|.
              (fromIntegral (s `S.unsafeIndex` 6) `shiftl_w64` 48) .|.
              (fromIntegral (s `S.unsafeIndex` 5) `shiftl_w64` 40) .|.
              (fromIntegral (s `S.unsafeIndex` 4) `shiftl_w64` 32) .|.
              (fromIntegral (s `S.unsafeIndex` 3) `shiftl_w64` 24) .|.
              (fromIntegral (s `S.unsafeIndex` 2) `shiftl_w64` 16) .|.
              (fromIntegral (s `S.unsafeIndex` 1) `shiftl_w64`  8) .|.
              (fromIntegral (s `S.unsafeIndex` 0) )
{-# INLINE getWord64le #-}
getWord64host = getStorable
{-# INLINE getWord64host #-}

instance ({-Show user,-} Monad m) => P.BinaryParser (CompGet r w user m) where
  skip = skip . fromIntegral
  bytesRead = fmap fromIntegral bytesRead
  remaining = fmap fromIntegral remaining
  isEmpty = isEmpty
  spanOf = fmap (S.concat . L.toChunks) . spanOf

  getByteString = getByteString
  getWordhost = getWordhost
  getWord8 = getWord8

  getWord16be = getWord16be
  getWord32be = getWord32be
  getWord64be = getWord64be

  getWord16le = getWord16le
  getWord32le = getWord32le
  getWord64le = getWord64le

  getWord16host = getWord16host
  getWord32host = getWord32host
  getWord64host = getWord64host

-- Below here are the class instances
    
instance ({-Show user,-} Monad m,Error e) => Functor (InternalGet e r w user m) where
  fmap f m = InternalGet (\sc -> unInternalGet m (sc . f))
  {-# INLINE fmap #-}

instance ({-Show user,-} Monad m,Error e) => Monad (InternalGet e r w user m) where
  return a = InternalGet (\sc -> sc a)
  {-# INLINE return #-}
  m >>= k  = InternalGet (\sc -> unInternalGet m (\a -> unInternalGet (k a) sc))
  {-# INLINE (>>=) #-}
  fail msg = throwError (strMsg msg)

instance MonadTrans (InternalGet e r w s) where
  lift m = InternalGet (\sc r w s pc -> m >>= \a -> sc a r w s pc)

instance ({-Show user,-} MonadIO m,Error e) => MonadIO (InternalGet e r w user m) where
  liftIO = lift . liftIO

instance ({-Show user,-} Monad m,Error e) => MonadError e (InternalGet e r w user m) where
  throwError msg = InternalGet $ \_sc _r _w s pcIn ->
    let go (ErrorFrame ec _) = ec msg s
        go (HandlerFrame catcher s1 future pc1) = catcher (collect s1 future) pc1 msg
        go (FutureFrame _ _ pc1) = go pc1 -- discard FutureFrame(s) between inner scope and a handler or error frame
    in go pcIn

  catchError mayFail handler = InternalGet $ \sc r w s pc ->
    let pcWithHandler = let catcher s1 pc1 e1 = unInternalGet (handler e1) sc r w s1 pc1
                        in HandlerFrame catcher s mempty pc
        actionWithCleanup = mayFail >>= \a -> discardInnerHandler >> return a
    in unInternalGet actionWithCleanup sc r w s pcWithHandler

instance ({-Show user,-} Monad m, Error e, Monoid w) => MonadWriter w (InternalGet e r w user m) where
  tell w'  = InternalGet (\sc r w -> sc () r (mappend w w'))
  listen m = InternalGet (\sc r w -> let sc' a r' w'= sc (a,w') r' (mappend w w')
                                     in unInternalGet m sc' r mempty)
  pass m   = InternalGet (\sc r w s pc -> let sc' (a,f) r' w' s' pc' = sc a r' (mappend w (f w')) s' pc'
                                          in unInternalGet m sc' r mempty s pc)

instance ({-Show user,-} Monad m, Error e) => MonadReader r (InternalGet e r w user m) where
  ask = InternalGet (\sc r -> sc r r)
  local f m = InternalGet (\sc r -> let scReplaceReader a _ = sc a r
                                    in unInternalGet m scReplaceReader (f r))
              
instance ({-Show user,-} Monad m,Error e) => MonadState user (InternalGet e r w user m) where
  get   = InternalGet (\sc r w s -> sc (userField s) r w s)
  put u = InternalGet (\sc r w s -> let s' = s {userField=u}
                              in sc () r w s')

instance ({-Show user,-} Monad m, Error e) => MonadPlus (InternalGet e r w user m) where
  mzero = throwError (strMsg "[mzero:no message]")
  mplus m1 m2 = catchError m1 (const m2)

instance ({-Show user,-} Monad m,Error e) => Applicative (InternalGet e r w user m) where
  pure = return
  (<*>) = ap

instance ({-Show user,-} Monad m,Error e) => Alternative (InternalGet e r w user m) where
  empty = mzero
  (<|>) = mplus

-- | I use "splitAt" without tolerating too few bytes, so write a Maybe version.
-- This is the only place I invoke L.Chunk as constructor instead of pattern matching.
-- I claim that the first argument cannot be empty.
splitAtOrDie :: Int64 -> L.ByteString -> Maybe (L.ByteString, L.ByteString)
splitAtOrDie i ps | i <= 0 = Just (L.Empty, ps)
splitAtOrDie i L.Empty = Nothing
splitAtOrDie i (L.Chunk x xs) | i < len = let (pre,post) = S.splitAt (fromIntegral i) x
                                          in Just (L.Chunk pre L.Empty
                                                  ,L.Chunk post xs)
                              | otherwise = case splitAtOrDie (i-len) xs of
                                              Nothing -> Nothing
                                              Just (y1,y2) -> Just (L.Chunk x y1,y2)
  where len = fromIntegral (S.length x)
{-# INLINE splitAtOrDie #-}

------------------------------------------------------------------------
-- getPtr copied from binary's Get.hs

-- helper, get a raw Ptr onto a strict ByteString copied out of the
-- underlying lazy byteString. So many indirections from the raw parser
-- state that my head hurts...

getPtr :: ({-Show user,-} Monad m,Storable a) => Int -> CompGet r w user m a
getPtr n = do
    (fp,o,_) <- fmap S.toForeignPtr (getByteString n)
    return . S.inlinePerformIO $ withForeignPtr fp $ \p -> peek (castPtr $ p `plusPtr` o)
{-# INLINE getPtr #-}

-- I pushed the sizeOf into here (uses ScopedTypeVariables)
getStorable :: forall r w user m a. ({-Show user,-} Monad m,Storable a) => CompGet r w user m a
getStorable = do
    (fp,o,_) <- fmap S.toForeignPtr (getByteString (sizeOf (undefined :: a)))
    return . S.inlinePerformIO $ withForeignPtr fp $ \p -> peek (castPtr $ p `plusPtr` o)
{-# INLINE getStorable #-}

------------------------------------------------------------------------
------------------------------------------------------------------------
-- Unchecked shifts copied from binary's Get.hs

shiftl_w16 :: Word16 -> Int -> Word16
shiftl_w32 :: Word32 -> Int -> Word32
shiftl_w64 :: Word64 -> Int -> Word64

#if defined(__GLASGOW_HASKELL__) && !defined(__HADDOCK__)
shiftl_w16 (W16# w) (I# i) = W16# (w `uncheckedShiftL#`   i)
shiftl_w32 (W32# w) (I# i) = W32# (w `uncheckedShiftL#`   i)

#if WORD_SIZE_IN_BITS < 64
shiftl_w64 (W64# w) (I# i) = W64# (w `uncheckedShiftL64#` i)

#if __GLASGOW_HASKELL__ <= 606
-- Exported by GHC.Word in GHC 6.8 and higher
foreign import ccall unsafe "stg_uncheckedShiftL64"
    uncheckedShiftL64#     :: Word64# -> Int# -> Word64#
#endif

#else
shiftl_w64 (W64# w) (I# i) = W64# (w `uncheckedShiftL#` i)
#endif

#else
shiftl_w16 = shiftL
shiftl_w32 = shiftL
shiftl_w64 = shiftL
#endif

------------------------------------------------------------------------
{- TESTING -}
------------------------------------------------------------------------

chomp :: CompGet () String () IO ()
chomp = getByteString 1 >>= \w -> tell (map (toEnum . fromEnum) (S.unpack w))

feed :: (Monad t) => Word8 -> CompResult t1 t2 t t3 -> t (CompResult t1 t2 t t3)
feed x (CPartial q) = q (Just (L.pack [x]))
feed _x y = return y

test :: (Monoid w, Monad m) => CompGet () w () m a -> [Word8] -> m (CompResult w () m a)
test g bs = runCompGet g () () (L.pack bs)

test10 :: IO (CompResult String () IO [()])
test10 = test (mplus (pr "go" >> replicateM 5 chomp >> pr "die" >> mzero) (pr "reborn" >> replicateM 10 chomp)) [1] >>= feed 2 >>= feed 3 >>= feed 4 >>= feed 5 >>= feed 6 >>= feed 7 >>=feed 8 >>= feed 9 >>= feed 10

pr :: (Show a) => a -> CompGet () String () IO ()
pr = liftIO . Prelude.print

countPC :: ({-Show user,-} Monad m) => CompGet r w user m Int
countPC = InternalGet $ \ sc r w s pc ->
  let go (ErrorFrame {}) i = i
      go (HandlerFrame _ _ _ pc') i = go pc' $! succ i
      go (FutureFrame _ _ pc') i = go pc' $! succ i
  in sc (go pc 0) r w s pc

{- testDepth result on my machine:

*Text.ProtocolBuffers.MyGet> testDepth
("stack depth",0,"bytes read",0,"bytes remaining",0,"begin")
("feed1",[48,49])
("stack depth",1,"bytes read",1,"bytes remaining",1,"mayFail")
("stack depth",2,"bytes read",1,"bytes remaining",1,"depth2")
("feed1",[50,51])
("stack depth",2,"bytes read",4,"bytes remaining",0,"about to mzero")
("stack depth",1,"bytes read",1,"bytes remaining",3,"middle")
("stack depth",1,"bytes read",2,"bytes remaining",2,"about to mzero again")
("stack depth",0,"bytes read",1,"bytes remaining",3,"handler")
("feed1",[52,53])
("feed1",[54,55])
("stack depth",0,"bytes read",7,"bytes remaining",1,"got 6, now suspendUntilComplete")
("feed1",[56,57])
("feed1",[58,59])
("feed1",[60,61])
("stack depth",0,"bytes read",7,"bytes remaining",7,"end")
(CFinished (Chunk "7" (Chunk "89" (Chunk ":;" (Chunk "<=" Empty)))) 7 ("0") (()) ("123456"))

The first chomp tell's "0".
All other tell's are thrown away by the error handling.
The stack depth returns to 0 as it should.
The "bytes read" is reset along with the input on each throwError/mzero/fail.
The (getByteString 6) reads "123456", leaving the "7" chunk on the input.
suspendUntilComplete loads the rest of the "89" ":;" and "<=" chunks.

-}

-- Ensure the stack fixing in catchError play words well:
testDepth :: IO (CompResult String () IO S.ByteString)
testDepth = test depth [] >>= feed12 >>= feedNothing where
  p s = countPC >>= \d -> bytesRead >>= \ b -> remaining >>= \r ->
         pr ("stack depth",d,"bytes read",b,"bytes remaining",r,s)
  depth = do
    p "begin"
    chomp
    catchError ( p "mayFail" >>
                 ((p "depth2" >> replicateM 3 chomp >> p "about to mzero" >> mzero) <|> return ()) >>
                 p "middle" >>
                 chomp >> p "about to mzero again" >> mzero)
               (\_ -> p "handler")
    a <- getByteString 6
    p "got 6, now suspendUntilComplete"
    suspendUntilComplete
    p "end"
    return a

feed12 :: CompResult w user IO a -> IO (CompResult w user IO a)
feed12 = foldr1 (>=>) . map feeds $ [ [2*i,2*i+1]  | i <- [24..30]]
  where feeds x (CPartial q) = print ("feed1",x)  >> q (Just (L.pack x))
        feeds _x y = return y

feedNothing :: (Monad t) => CompResult t1 t2 t t3 -> t (CompResult t1 t2 t t3)
feedNothing (CPartial q) = q Nothing
feedNothing x = return x