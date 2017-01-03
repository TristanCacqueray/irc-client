{-# LANGUAGE OverloadedStrings  #-}

-- |
-- Module      : Network.IRC.Client
-- Copyright   : (c) 2016 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : experimental
-- Portability : OverloadedStrings
--
-- A simple IRC client library. Typical usage will be of this form:
--
-- > run :: ByteString -> Int -> Text -> IO ()
-- > run host port nick = do
-- >   conn <- connect host port 1
-- >   let cfg = defaultIRCConf nick
-- >   let cfg' = modify handlers (yourCustomEventHandlers:) cfg
-- >   start conn cfg'
--
-- You shouldn't really need to tweak anything other than the event
-- handlers, as everything has been designed to be as simple as
-- possible.
module Network.IRC.Client
  ( -- * Initialisation
    connect
  , connectWithTLS
  , connectWithTLSConfig
  , connectWithTLSVerify
  , start
  , start'

  -- * Logging
  , Origin (..)
  , connect'
  , connectWithTLS'
  , connectWithTLSConfig'
  , connectWithTLSVerify'
  , stdoutLogger
  , fileLogger
  , noopLogger

  -- * Interaction
  , send
  , sendBS
  , disconnect

  -- * Events
  , module Network.IRC.Client.Events

  -- * Lenses
  , module Network.IRC.Client.Lens

  -- * The IRC monad
  , IRC(..)
  , IRCState
  , newIRCState
  , getIrcState
  , ConnectionState(..)
  , getConnectionState
  , ConnectionConfig
  , InstanceConfig
  , defaultIRCConf
  , Timeout(..)

  -- * Utilities
  , module Network.IRC.Client.Utils
  , C.rawMessage
  , C.toByteString
  ) where

import Control.Concurrent.STM     (atomically, newTVar)
import Control.Monad.IO.Class     (MonadIO, liftIO)
import Control.Monad.Trans.Reader (runReaderT)
import Data.ByteString            (ByteString)
import qualified Data.Conduit.Network.TLS as TLS
import Data.Conduit.TMChan (newTBMChanIO)
import Data.Text                  (Text)
import qualified Data.Text as T
import Data.Time.Clock            (NominalDiffTime)
import Data.Version (showVersion)
import qualified Data.X509 as X
import qualified Data.X509.CertificateStore as X
import qualified Data.X509.Validation as X
import Network.Connection as TLS (TLSSettings(..))
import qualified Network.IRC.Conduit as C
import qualified Network.TLS as TLS

import Network.IRC.Client.Events
import Network.IRC.Client.Internal
import Network.IRC.Client.Internal.Types
import Network.IRC.Client.Lens
import Network.IRC.Client.Utils

import qualified Paths_irc_client as Paths

-- * Connecting to an IRC network

-- | Connect to a server without TLS.
connect
  :: ByteString
  -- ^ The hostname
  -> Int
  -- ^ The port
  -> NominalDiffTime
  -- ^ The flood cooldown
  -> ConnectionConfig s
connect = connect' noopLogger

-- | Connect to a server with TLS.
connectWithTLS
  :: ByteString
  -- ^ The hostname
  -> Int
  -- ^ The port
  -> NominalDiffTime
  -- ^ The flood cooldown
  -> ConnectionConfig s
connectWithTLS = connectWithTLS' noopLogger

-- | Connect to a server with TLS using the given TLS config.
connectWithTLSConfig
  :: TLS.TLSClientConfig
  -- ^ The TLS config
  -> NominalDiffTime
  -- ^ The flood cooldown
  -> ConnectionConfig s
connectWithTLSConfig = connectWithTLSConfig' noopLogger

-- | Connect to a server with TLS using the given certificate
-- verifier.
connectWithTLSVerify
  :: (X.CertificateStore -> TLS.ValidationCache -> X.ServiceID -> X.CertificateChain -> IO [X.FailedReason])
  -- ^ The certificate verifier. Returns an empty list if the cert is
  -- good.
  -> ByteString
  -- ^ The hostname
  -> Int
  -- ^ The port
  -> NominalDiffTime
  -- ^ The flood cooldown
  -> ConnectionConfig s
connectWithTLSVerify = connectWithTLSVerify' noopLogger

-- | Connect to a server without TLS, with the provided logging
-- function.
connect'
  :: (Origin -> ByteString -> IO ())
  -- ^ The message logger
  -> ByteString
  -- ^ The hostname
  -> Int
  -- ^ The port
  -> NominalDiffTime
  -- ^ The flood cooldown
  -> ConnectionConfig s
connect' lg host port_ =
  connectInternal (C.ircClient port_ host) defaultOnConnect defaultOnDisconnect lg host port_

-- | Connect to a server with TLS, with the provided logging function.
connectWithTLS'
  :: Origin -> ByteString -> IO ()
  -- ^ The message logger
  -> ByteString
  -- ^ The hostname
  -> Int
  -- ^ The port
  -> NominalDiffTime
  -- ^ The flood cooldown
  -> ConnectionConfig s
connectWithTLS' lg host port_ =
  connectInternal (C.ircTLSClient port_ host) defaultOnConnect defaultOnDisconnect lg host port_

-- | Connect to a server with TLS using the given TLS config, with the
-- provided logging function.
connectWithTLSConfig'
  :: (Origin -> ByteString -> IO ())
  -- ^ The message logger
  -> TLS.TLSClientConfig
  -- ^ The TLS config
  -> NominalDiffTime
  -- ^ The flood cooldown
  -> ConnectionConfig s
connectWithTLSConfig' lg cfg =
  connectInternal (C.ircTLSClient' cfg) defaultOnConnect defaultOnDisconnect lg host port_
  where
    host = TLS.tlsClientHost cfg
    port_ = TLS.tlsClientPort cfg

-- | Connect to a server with TLS using the given certificate
-- verifier, with the provided logging function.
connectWithTLSVerify'
  :: (Origin -> ByteString -> IO ())
  -- ^ The message logger
  -> (X.CertificateStore -> TLS.ValidationCache -> X.ServiceID -> X.CertificateChain -> IO [X.FailedReason])
  -- ^ The certificate verifier. Returns an empty list if the cert is
  -- good.
  -> ByteString
  -- ^ The hostname
  -> Int
  -- ^ The port
  -> NominalDiffTime
  -- ^ The flood cooldown
  -> ConnectionConfig s
connectWithTLSVerify' lg verifier host port_ =
  connectInternal (C.ircTLSClient' cfg) defaultOnConnect defaultOnDisconnect lg host port_
  where
    cfg =
      let cfg0 = C.defaultTLSConfig port_ host
          -- this is a partial pattern match, but because I'm the
          -- author of irc-conduit I can do this.
          TLS.TLSSettings cTLSSettings = TLS.tlsClientTLSSettings cfg0
          cHooks = TLS.clientHooks cTLSSettings
      in cfg0 { TLS.tlsClientTLSSettings = TLS.TLSSettings cTLSSettings
                { TLS.clientHooks = cHooks
                  { TLS.onServerCertificate = verifier }
                }
              }

-- * Starting

-- | Run the event loop for a server, receiving messages and handing
-- them off to handlers as appropriate.
start :: MonadIO m => ConnectionConfig s -> InstanceConfig s -> s -> m ()
start cconf iconf ustate = newIRCState cconf iconf ustate >>= start'

-- | Like 'start', but use the provided initial 'IRCState'.
start' :: MonadIO m => IRCState s -> m ()
start' = liftIO . runReaderT (runIRC runner)

-- * Default configuration

-- | Construct a default IRC configuration from a nick
defaultIRCConf :: Text -> InstanceConfig s
defaultIRCConf n = InstanceConfig
  { _nick     = n
  , _channels = []
  , _version  = T.append "irc-client-" (T.pack $ showVersion Paths.version)
  , _handlers = defaultEventHandlers
  , _ignore   = []
  }

-------------------------------------------------------------------------------
-- State

-- | Construct a new IRC state
newIRCState :: MonadIO m => ConnectionConfig s -> InstanceConfig s -> s -> m (IRCState s)
newIRCState cconf iconf ustate = liftIO $ do
  ustvar <- atomically . newTVar $ ustate
  ictvar <- atomically . newTVar $ iconf
  cstvar <- atomically . newTVar $ Disconnected
  squeue <- newTBMChanIO 16

  pure IRCState
    { _connectionConfig = cconf
    , _userState        = ustvar
    , _instanceConfig   = ictvar
    , _connectionState  = cstvar
    , _sendqueue        = squeue
    }
