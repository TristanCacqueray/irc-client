{-# LANGUAGE CPP #-}

-- |
-- Module      : Network.IRC.Client.Lens
-- Copyright   : (c) 2017 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : experimental
-- Portability : CPP
--
-- 'Lens'es and 'Prism's.
module Network.IRC.Client.Lens where

import Control.Concurrent.STM (TVar)
import Control.Monad.Catch (SomeException)
import Data.ByteString (ByteString)
import Data.Profunctor (Choice (right'), Profunctor (dimap))
import Data.Text (Text)
import Data.Time (NominalDiffTime)

import Network.IRC.Client.Internal.Lens
import Network.IRC.Client.Internal.Types

{-# ANN module ("HLint: ignore Redundant lambda") #-}

-- CPP seem to dislike the first ' on the RHS…
#define PRIME() '

#define LENS(S,F,A) \
    {-# INLINE F #-}; \
    {-| PRIME()Lens' for '_/**/F'. -}; \
    F :: Lens' S A; \
    F = \ afb s -> (\ b -> s {_/**/F = b}) <$> afb (_/**/F s)

#define GETTER(S,F,A) \
    {-# INLINE F #-}; \
    {-| PRIME()Getter' for '_/**/F'. -}; \
    F :: Getter S A; \
    F = \ afb s -> (\ b -> s {_/**/F = b}) <$> afb (_/**/F s)

#define PRISM(S,C,ARG,TUP,A) \
    {-| PRIME()Prism' for 'C'. -}; \
    {-# INLINE _/**/C #-}; \
    _/**/C :: Prism' S A; \
    _/**/C = dimap (\ s -> case s of C ARG -> Right TUP; _ -> Left s) \
        (either pure $ fmap (\ TUP -> C ARG)) . right'


-------------------------------------------------------------------------------
-- * Lenses for 'IRCState'

GETTER((IrcState s),connectionConfig,(ConnectionConfig s))
LENS((IrcState s),userState,(TVar s))
LENS((IrcState s),instanceConfig,(TVar (InstanceConfig s)))
LENS((IrcState s),connectionState,(TVar ConnectionState))


-------------------------------------------------------------------------------
-- * Lenses for 'ConnectionConfig'

GETTER((ConnectionConfig s),server,ByteString)
GETTER((ConnectionConfig s),port,Int)
LENS((ConnectionConfig s),username,Text)
LENS((ConnectionConfig s),realname,Text)
LENS((ConnectionConfig s),password,(Maybe Text))
LENS((ConnectionConfig s),flood,NominalDiffTime)
LENS((ConnectionConfig s),timeout,NominalDiffTime)
LENS((ConnectionConfig s),onconnect,(Irc s ()))
LENS((ConnectionConfig s),ondisconnect,(Maybe SomeException -> Irc s ()))
LENS((ConnectionConfig s),logfunc,(Origin -> ByteString -> IO ()))


-------------------------------------------------------------------------------
-- * Lenses for 'InstanceConfig'

LENS((InstanceConfig s),nick,Text)
LENS((InstanceConfig s),channels,[Text])
LENS((InstanceConfig s),version,Text)
LENS((InstanceConfig s),handlers,[EventHandler s])
LENS((InstanceConfig s),ignore,[(Text, Maybe Text)])


-------------------------------------------------------------------------------
-- * Prisms for 'ConnectionState'

PRISM(ConnectionState,Connected,,(),())
PRISM(ConnectionState,Disconnecting,,(),())
PRISM(ConnectionState,Disconnected,,(),())


-------------------------------------------------------------------------------
-- * Prisms for 'Origin'

PRISM(Origin,FromServer,,(),())
PRISM(Origin,FromClient,,(),())
