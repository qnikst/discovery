{-# LANGUAGE MultiParamTypeClasses, ScopedTypeVariables, DeriveDataTypeable #-}
-- | Module: Network.Heartbeat
--   Author: Alexander Vershilov <alexander.vershilov@gmail.com>
--   LICENCE: BSD
--
--   Provide a basic service discovery and heartbeat interface, using 
--   broadcast UDP packets.
--
--
--   Service discrovery. Is looking service instances in local network
--   it has 2 types of discovering:
--    
--      * One Way - every node broadcasting it's information to the 
--          network, client listenes and stores information. This 
--          protocol has built in heartbeat module, i.e. keep track 
--          of alive hosts.
--      * Req-Rep - new client sends a broadcast event to the network
--          and each service reply with information about this service.
--          This module has no heartbeat functionallity, and 
--          heartbeating should be performent on data connection level
--
--   N.B. Req-rep service is not implemented yet
--
--   N.B. IPV6 protocols is not currently ready as IPV6 has no broadcast 
--    support and multicast (ff02::1) address should be used instread
--
module Network.Heartbeat
  where

import Data.Bits
import Data.Binary
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as S8
import Data.Default
import Data.List
import Data.Time
import Data.Typeable
import Data.Function

import Network.Socket hiding (recvFrom, sendTo)
import Network.Socket.ByteString
import Control.Applicative
import Control.Concurrent
import Control.Exception
import Control.Monad (forever, when)

import System.Time.Monotonic


data Discovery = OneWay {
                    disInterval :: DiffTime,
                    disData :: IO ByteString
                 }

data DiscoveryClient a = OneWayC 
        { dicData :: ByteString -> a
        }

discoveryServer :: Discovery -> Word32 -> Int -> IO ()
discoveryServer (OneWay interval getData) bcast port = 
    let addr = SockAddrInet (fromIntegral port) bcast     -- TODO support IPV6
    in bracket (socketPrepare port)
               (sClose)
               (\s -> forever (getData >>= \d -> sendTo s d addr >> delay interval))

discoveryClient :: (Eq a) => DiscoveryClient a -> Int -> DiffTime -> IO [(a, SockAddr)]
discoveryClient (OneWayC parseData) port interval = do
    bracket (socketPrepare port)
            (sClose)
            (\sock -> do
                clock <- newClock
                cur <- clockGetTime clock
                let finish = cur+interval
                    go acc = do
                        ctime <- clockGetTime clock
                        c <- timeoutf (finish - ctime) (recvFrom sock 1024) -- TODO remove data len hardcoding
                        case c of 
                          Nothing -> return acc
                          Just (msg, b) -> go $! insert' (parseData msg, b) acc
                go [])
    where 
      insert' v [] = [v]
      insert' v b@(x:xs) | v == x    = b
                         | otherwise = x : insert' v xs


{-
-- | Start network discovery server on specified interface
discoveryServer :: DiscoveryType -> Int -> IO ThreadId
discoveryServer (OneWay interval) port = 
  let addr = SockAddrIter (fromIntegal port) bcast
  in bracket (socketPrepare) 
             (sClose) 
             (\s -> forever (dsName >>= \n -> sendTo s n addr >> delay interval))
discoveryServer _ _ = error "not implemented yet"
-}

{-
data Heartbeat = Heartbeat 
      { hbEvent :: ByteString -> IO ()
      , hbBorn  :: HbIdentifier -> IO ()
      , hbDeath :: ByteString -> IO ()
      }

instance Default Heartbeat where
  def = Heartbeat (\_ -> return ()) 
                  (\_ -> return ())
                  (\_ -> return ())

-- | Type that is used for identifying a node
type HbIdentifier = ByteString

type HbItem = (DiffTime, HbIdentifier)
type HbStorage = [HbItem]

newtype HeartbeatHandle = HeartbeatHandle { unHeartbeatHandle :: ThreadId }
                        deriving (Show, Eq)

heartbeatCancel :: HeartbeatHandle -> IO ()
heartbeatCancel = undefined

-- | heartbeat implements simple UDP discovery and heartbeat system
-- TODO: safely accure-release socket
-- TODO: setSocketOption for reuse
-- TODO: set addresses that are listened
heartbeat :: ByteString -> Word32 -> Int -> DiffTime -> DiffTime -> Heartbeat -> IO HeartbeatHandle
heartbeat name bcast port pause timeout hb = do
   sock <- socketPrepare
   clock <- newClock
   let cleanInterval = timeout / 2
   HeartbeatHandle <$>
      (forkIO $ bracket 
                (forkIO $ writer sock)
                (killThread)
                (const $ 
                     let go store = do
                         c <- timeoutf cleanInterval (recvFrom sock 4)     -- TODO remove data len hardcoding
                         ctime <- clockGetTime clock
                         store' <- case c of 
                                    Nothing -> return store
                                    Just (msg, b) -> do
                                          let name = msg                      -- TODO decode name
                                              (n, r) = lupdate (ctime + timeout, name) store
                                          when n $ hbBorn hb name
                                          return r
                         let (expired, living) = partition (\(a,_) -> a < ctime) store'
                         mapM_ ((hbDeath hb) . snd) expired
                         go living
                     in go []
                )
      )
  where
    writer sock = forever $ sendTo sock name (SockAddrInet (fromIntegral port) bcast) >> delay pause
    lupdate :: HbItem -> HbStorage -> (Bool, HbStorage)
    lupdate = go []
      where go acc n     [] = (True, n:acc)
            go acc (n,v) (x:xs) | snd x == v = (False, (n,v):acc)
                                | otherwise  = go (x:acc) (n,v) xs
-}




-- | run function with timeout
-- TODO: use STM ?
timeoutf t f | t < 0 = return Nothing
             | otherwise = do
  box <- newEmptyMVar
  t <- forkIO $ bracket (forkIO $ putMVar box =<< Just <$> f)
                        (killThread)
                        (\th -> delay t >> tryPutMVar box Nothing >> return ())
  ret <- takeMVar box
  killThread t
  return ret

bcastFromAddr :: ByteString -> Int -> IO Word32
bcastFromAddr host mask =
    let m = complement (2^mask - 1)
    in (.|. m) <$> inet_addr (S8.unpack host)

socketPrepare port = do
   sock <- socket AF_INET Datagram defaultProtocol
   setSocketOption sock Broadcast 1
   setSocketOption sock ReuseAddr 1
   bind sock $ SockAddrInet (fromIntegral port) iNADDR_ANY  -- TODO remove iNADDR_ANY hardcoding
   return sock

