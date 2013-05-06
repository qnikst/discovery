{-# LANGUAGE DeriveDataTypeable #-}
-- | Module: Network.Heartbeat
--  Author: Alexander Vershilov <alexander.vershilov@gmail.com> 
--  LICENCE: BSD
--
-- Provide a basic service discovery and heartbeat interface, using 
-- broadcast UDP packets.
--
--
-- Service discrovery. Is looking service instances in local network
-- it has 2 types of discovering:
--  
--    * 'OneWay' - every node broadcasting it's information to the 
--        network, client listenes and stores information. 
--
--    * 'ReqRep' - new client sends a broadcast event to the network
--        and each service reply with information about this service.
--
-- N.B. Req-rep service is not implemented yet
--
-- N.B. IPV6 protocols is not currently ready as IPV6 has no broadcast 
--  support and multicast (ff02::1) address should be used instread
--
module Network.Discovery
  ( -- * Datatypes 
    Discovery(..)
  , DiscoveryHost
  , mkBroadcast
    -- * Higher level wrappers
  , discovery
  , discoveryServer
  , lookupServerT
    -- * Internal function
  , oneWayClient 
  )
  where

import Data.Bits
import Data.Binary
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as S8
import Data.Time
import Data.Typeable

import Network.Socket hiding (recvFrom, sendTo)
import Network.Socket.ByteString
import Control.Applicative
import Control.Concurrent
import Control.Exception
import Control.Monad (forever, replicateM_)

import System.Time.Monotonic

data DiscoverySignal = DiscoveryStop
                    deriving (Show, Typeable)

-- | DiscoveryHost abracts over different type of broadcast hosts
-- Either an IPv4 broadcast address or IPv6 multicast
data DiscoveryHost  = HostV4 Word32

instance Exception DiscoverySignal

-- | Discovery algorithm
data Discovery = OneWay {
                    disInterval :: DiffTime,            -- ^ ping interval
                    disData :: IO ByteString            -- ^ data to send
                 }
               | ReqRep {
                   disData :: IO ByteString
                }

data DiscoveryClient a = OneWayC  (ByteString -> a)       -- ^ data decoding


-- | High level server wrapper 
discoveryServer :: Discovery                              -- ^ discovery algorithm
                -> DiscoveryHost                          -- ^ broadcast address
                -> Int                                    -- ^ broadcast port
                -> IO ()
discoveryServer (OneWay interval dat_) bcast port = onSocket bcast port $
               \a s -> oneWayServer dat_ interval s a
discoveryServer _ _ _ = error  "not yet implemented"

-- | Higher level wrapper for client server application
discovery ::  Discovery                                   -- ^ discoverty
          -> (ByteString -> SockAddr -> IO ())            -- ^ message event
          -> DiscoveryHost                                -- ^ discovery address
          -> Int                                          -- ^ discovery port
          -> IO ()
discovery (OneWay interval dat_) event bcast port = onSocket bcast port $ 
               \a s -> bracket (forkIO $ oneWayServer dat_ interval s a)
                               (killThread)
                               (const . forever $ recvFrom s 1024 >>= uncurry event)
discovery (ReqRep dat_) event bcast port = reqRepServer dat_ bcast port event 

-- | Searches for server for the given amount of time
lookupServerT :: (Eq a) => DiscoveryClient a              -- ^ discovery client
              -> Int                                      -- ^ broadcast port
              -> DiffTime                                 -- ^ time to wait
              -> IO [(a, ByteString, SockAddr)]
lookupServerT (OneWayC parse) port interval = do
    bracket (socketPrepare >>= bindBcast (HostV4 undefined) port)                      -- TODO remove stupid hardcoding
            (sClose)
            (\sock -> do
              box <- newEmptyMVar
              t <- forkIO $ oneWayClient sock parse >>= putMVar box
              delay interval 
              throwTo t DiscoveryStop
              takeMVar box)

-- | run one way server on already created sockets
oneWayServer :: (IO ByteString) -> DiffTime -> Socket -> SockAddr -> IO ()
oneWayServer getData interval sock addr = forever $  
    getData >>= \d -> sendTo sock d addr >> delay interval


reqRepServer :: (IO ByteString) -> DiscoveryHost -> Int -> (ByteString -> SockAddr -> IO ()) -> IO ()
reqRepServer getData bcast port event = do
    _ <- forkIO $ onSocket bcast port $ \addr sock -> do
        _ <- forkIO $ replicateM_  10 (getData >>= \d -> sendTo sock d addr >> delay 2)
        forever $ recvFrom sock 1024 >>= \(data_,addr') -> do 
           event data_ addr'
           bracket (do socket AF_INET Stream defaultProtocol)
                   (sClose) 
                   (\s -> do connect s addr'
                             sendAll s =<< getData
                   )
    bracket (do sock <- socket AF_INET Stream defaultProtocol
                return sock)
            (sClose) 
            (\s -> do listen s 1 
                      sockHandler s
            )
  where 
    sockHandler sock = do
      (s, _) <- accept sock -- FIXMENOW 2nd 3rd param
      _ <- forkIO $ communicate s 
      sockHandler sock
    communicate s = do
      (data_, addr) <- recvFrom s 1024
      event data_ addr

      
            

-- | run one way client
oneWayClient :: Eq a 
             => Socket                                        -- ^ Socket to listen on
             -> (ByteString -> a)                             -- ^ name resolve function
             -> IO [(a, ByteString, SockAddr)]
oneWayClient sock parse = do
    let go acc = (tryD (recvFrom sock 1024)) >>= \x -> -- TODO remove data len hardcoding
          case x of
            Left _ -> return acc
            Right (msg,b) -> go $! insert' (parse msg, msg, b) acc
    go []
 where 
    insert' v [] = [v]
    insert' v@(a0,_,_) y@(x@(a1,_,_):xs) | a0 == a1  = y
                                         | otherwise = x : insert' v xs


-- | Prepare socket for receiving
socketPrepare :: IO Socket
socketPrepare = do
   sock <- socket AF_INET Datagram defaultProtocol
   setSocketOption sock Broadcast 1
   setSocketOption sock ReuseAddr 1
   return sock

-- | Prepare recieving bcast addresses 
bindBcast ::DiscoveryHost -> Int -> Socket -> IO Socket
bindBcast (HostV4 _) port sock = bind sock (SockAddrInet (fromIntegral port) iNADDR_ANY) >> return sock

tryD :: IO a -> IO (Either DiscoverySignal a)
tryD = try

-- | Create ipv4 broadcast port
mkBroadcast :: ByteString                 -- ^ IP address
            -> Int                        -- ^ network mask
            -> IO DiscoveryHost
mkBroadcast host m = 
    let m' = complement (2^m - 1)
    in (\x -> HostV4 (x .|. m')) <$> inet_addr (S8.unpack host)

addrFromHost :: DiscoveryHost -> Int -> SockAddr
addrFromHost (HostV4 b) port = SockAddrInet (fromIntegral port) b
--                HostV6 fi ha6 sc  -> SockAddrInet6 (fromIntegral port) fi ha6 sc      -- TODO support IPV6

onSocket :: DiscoveryHost -> Int -> (SockAddr -> Socket -> IO a) -> IO a
onSocket host port f = 
  let addr = addrFromHost host port
  in bracket (socketPrepare >>= bindBcast host port)
             (sClose)
             (f addr)
