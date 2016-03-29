
{-# LANGUAGE ScopedTypeVariables, OverloadedStrings #-}
module PeersControlerN where

import qualified Connector as CN (liftEither, makePeers)
import Control.Monad.Except (ExceptT, liftIO, runExceptT)
import qualified Peer as P
-- import qualified StaticQueue as SQ
import qualified Data.Conduit.Network as CN
import Data.Conduit
import qualified Data.ByteString.Char8 as BC
import qualified Data.Conduit.Binary as CB
import Control.Monad.Trans.Resource
import qualified Types as TP


import qualified TubeDSL as T
import qualified Message as M
import qualified InterpretIO as IPIO


main::IO()
main = do result <- runExceptT $ start "tom.torrent"--"ubuntu.torrent"  -- "tom.torrent"--
          print result



start :: String -> ExceptT String IO ()
start tracker =
     do (peers, globalStatus)  <-  CN.makePeers tracker
        liftIO $ print (length peers)
        let peer = peers !! 2
        liftIO $ print peers
        liftIO $ runClient globalStatus peer
        return ()



runClient :: TP.GlobalPiceInfo -> P.Peer -> IO ()
runClient globalStatus peer =
    CN.runTCPClient (CN.clientSettings (P.port peer) (BC.pack $ P.hostName peer)) $ \appData -> do
        let source = CN.appSource appData
            peerSink   = CN.appSink appData
        print "TUBE"

        tube globalStatus peer source peerSink


tube ::
   TP.GlobalPiceInfo
   -> P.Peer
   -> ConduitM () BC.ByteString IO ()
   -> Sink BC.ByteString IO ()
   -> IO ()
tube global peer getFrom sendTo = do
   let infoHash = P.infoHash peer
   print $ "SNDING HS"
   T.sendHandshake infoHash sendTo
   print $ "SNDING HS DONE"


   (nextSource, handshake) <- getFrom $$+ T.recHandshake

   let infoSize   = P.sizeInfo peer

   case handshake of
      Left l ->
         print $ "Bad Handshake : " ++l

      Right (bitFieldLeftOver, hand) -> do
          let gg = transPipe (InterpretIO.interpret global sendTo) ((T.flushLeftOver bitFieldLeftOver)
                =$=  T.decodeMessage M.getMessage
                =$=  T.recMessage peer)
          nextSource $=+ gg $$+- saveToFile


saveToFile :: Sink (String, BC.ByteString) IO ()
saveToFile = do
  awaitForever (liftIO . save)
  where
    save :: (String, BC.ByteString) -> IO()
    save (fN, c) =
       runResourceT $
        (yield c)
        $$ (CB.sinkFile ("downloads/" ++ fN))
