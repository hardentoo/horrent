{-# LANGUAGE FlexibleInstances, InstanceSigs, LiberalTypeSynonyms #-}
module Tube where

import Data.Conduit
import qualified Data.Conduit.List as CL

import qualified Message as M
import Control.Monad.IO.Class
import qualified Handshake as H
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.Conduit.Network as CN
import qualified Data.Conduit.Binary as CB
import qualified Data.Bits as Bits
import qualified Peer as P
import qualified Control.Concurrent as CC
import qualified Data.Sequence as Seq
import qualified Types as TP
import qualified Data.Array.MArray as MA
import qualified Control.Concurrent.STM as STM
import qualified Crypto.Hash.SHA1 as SHA1 
import Control.Monad.Trans.Resource
import Data.Maybe
import qualified Data.Binary.Get as G



-- =======================

import qualified Control.Monad.Trans as Trans

import qualified Control.Monad.Writer as WT

import Data.Functor.Identity

          --8192
chunkSize = 16384  

sendHandshake :: Monad m => B.ByteString -> Sink BC.ByteString m () -> m ()  
sendHandshake infoHash peerSink = 
   yield handshake $$ peerSink
   where      
      handshake = H.createHandshake infoHash
      
      
      
recHandshake :: 
   Monad m  
   => Sink BC.ByteString m (TP.Perhaps (BC.ByteString, H.Handshake)) 
recHandshake = 
   await >>= maybe (return $ Left "No handshake") 
                   (return . convertHandshake)                  
   where 
      convertHandshake = H.convertParsedOutput . H.decodeHandshake 
           
             
 
decodeMessage :: G.Decoder M.Message -> Conduit BC.ByteString IO M.Message  
decodeMessage dec = do
   case dec of 
      (G.Fail _ _ _) -> 
         liftIO $ print "ERROR: DECODING FAILURE"   
      
      G.Partial fun -> 
         await >>= maybe (return ()) 
                         (\x -> decodeMessage $ fun (Just x))   
    
      (G.Done lo _ x) -> do
         yield x
         leftover lo
         (decodeMessage M.getMessage)
   
      
      
 
recMessage ::  
   Sink BC.ByteString IO () 
   -> P.Peer 
   -> Conduit M.Message IO (String, BC.ByteString)
recMessage peerSink peer = do
  message <- await 
  
  let pieces = P.pieces peer
      global = P.globalStatus peer
            
  case message of
       Nothing -> do 
            return ()
         
      
       Just (M.Bitfield b) -> do 
            liftIO $ print "BF"
            let pList = P.convertToBits b 
                newPeer = peer {P.pieces = pList}
            liftIO $ sendInterested peerSink
            recMessage peerSink newPeer 
              
           
           
       Just (M.Have b) -> do 
            liftIO $ print "Have"  
            let pList = (P.fromBsToInt b) : P.pieces peer
                newPeer = peer {P.pieces = pList}  
            recMessage peerSink newPeer 
            
            
                                         
       Just M.UnChoke -> do 
            liftIO $  print "UnChoke"
            nextM <- liftIO $ requestNextAndUpdateGlobal pieces global 
            case nextM of
                 Nothing -> 
                      return ()                    
                 Just next -> do          
                      liftIO $ print ("Req "++(show next))
                      liftIO $ sendRequest peerSink (next, 0, chunkSize)
                      liftIO $ setStatus next global  TP.InProgress
            
                      recMessage peerSink peer 
                        
      
         
       Just (M.Piece (idx, offset, chunkBuffer)) -> do     
            let newBuffer = (P.buffer peer) `BC.append` chunkBuffer
                newPeer = peer {P.buffer = newBuffer}  
                size = getSize idx (P.sizeInfo peer)           
            handlePiecie peerSink (idx,offset) size newPeer  
     
     
      
       Just M.Choke -> 
            return ()
      
       Just M.KeepAlive -> do 
            liftIO $ print "KeepAlive" 
            recMessage peerSink peer 
                       
      
       Just y -> do 
            liftIO $ print ("This message should not arrive while downloading " ++ (show y))     
            return ()
                   
      
      
      
          
handlePiecie :: 
   Sink BC.ByteString IO ()
   ->(Int, Int)
   -> Int
   -> P.Peer
   -> ConduitM M.Message (String, BC.ByteString) IO ()               
handlePiecie peerSink (idx, offset) size peer  
  | (offset < size - chunkSize) = do
       liftIO $ print ((show idx) ++ " " ++ (show offset))    
       liftIO $ sendRequest peerSink (idx, offset + chunkSize , chunkSize)
      
       recMessage peerSink peer 
       
       
 | otherwise = do     
      let pieces = P.pieces peer
          global = P.globalStatus peer
  
      nextM <- liftIO $ requestNextAndUpdateGlobal pieces global                 
      case nextM of
            Nothing -> 
                 return ()
            Just next -> do    
                
                 liftIO $ setStatus idx (P.globalStatus peer)  TP.Done 
                 liftIO $ sendRequest peerSink (next, 0 , reqSize next)
                 liftIO $ print ("Next " ++ (show next))      
                 let newBuffer = P.buffer peer
                     hshEq = ((Seq.index (P.peceHashes peer) idx) == SHA1.hash newBuffer)
                 liftIO $ print hshEq
         
                 yield (show idx, newBuffer)
              
                 let newPeer = peer {P.buffer = BC.empty}
                 recMessage peerSink newPeer  
                
      where         
         reqSize next 
            | (last (P.pieces peer) == next) =
                 min (lastS (P.sizeInfo peer)) chunkSize
                 
            | otherwise = 
                 chunkSize      
                 
         lastS (nbOfPieces, normalSize, lastSize) = lastSize 
        
     
       
  
  
getSize next (nbOfPieces, normalSize, lastSize) 
   | (next == nbOfPieces -1) = lastSize
   | otherwise               = normalSize 
  
                                                                  
  
  
  
  
 
  
saveToFile :: Sink (String, BC.ByteString) IO ()
saveToFile = do
  awaitForever (liftIO . save)
  where 
    save :: (String, BC.ByteString) -> IO()
    save (fN, c) =
       runResourceT $ 
        (yield c) 
        $$ (CB.sinkFile ("downloads/" ++ fN))
        
  

flushLeftOver :: BC.ByteString -> Conduit BC.ByteString IO BC.ByteString
flushLeftOver lo 
   | (not . B.null) lo = do
        yield lo
        awaitForever yield     
        
   | otherwise         = awaitForever yield
  
  
                                       
-- let source = (addCleanup (const $ liftIO $ putStrLn "Stopping ---")) $ CN.appSource (appData)
    

tube :: 
   P.Peer
   -> Source IO BC.ByteString 
   -> Sink BC.ByteString IO ()
   -> IO ()  
tube peer getFrom sendTo = do  
   let infoHash = P.infoHash peer
   sendHandshake infoHash sendTo
  
   (nextSource, handshake) <- getFrom $$+ recHandshake
    
   let global     = P.globalStatus peer
       infoSize   = P.sizeInfo peer
       peceHashes = P.peceHashes peer
                
   case handshake of
      Left l -> 
         print l
      Right (bitFieldLeftOver, hand) -> 
         nextSource 
    
         $=+  flushLeftOver bitFieldLeftOver 
      
         =$=  decodeMessage M.getMessage
      
         =$=  recMessage sendTo peer 
      
         $$+- saveToFile  
     
   
   
    
                      
                      
                      
requestNextAndUpdateGlobal :: [Int] -> TP.GlobalPiceInfo -> IO (Maybe Int)
requestNextAndUpdateGlobal pics global =
   STM.atomically $ reqNext pics global
      where
         reqNext :: [Int] -> TP.GlobalPiceInfo -> STM.STM (Maybe Int)  
         reqNext [] _ = return Nothing     
         reqNext (x:xs) global = 
            do pInfo <- MA.readArray global x -- TODO view pattern
               case pInfo of
                  TP.NotHave -> do 
                     MA.writeArray global x TP.InProgress 
                     return $ Just x
                  TP.InProgress -> reqNext xs global
                  TP.Done -> reqNext xs global
                      

                      
   
 

  
setStatusDone :: Int -> TP.GlobalPiceInfo -> IO()
setStatusDone x global = 
  STM.atomically $ MA.writeArray global x TP.Done 


  
setStatus :: Int -> TP.GlobalPiceInfo -> TP.PiceInfo -> IO()
setStatus x global status = 
  STM.atomically $ MA.writeArray global x status 
 
 
 
 
printArray :: TP.GlobalPiceInfo -> IO()                      
printArray global = do 
  k <- STM.atomically $ MA.getElems global
  print $ zip k [0..]
                      
                      
                      
sendInterested :: Sink BC.ByteString IO () -> IO() 
sendInterested peerSink = 
  yield (M.encodeMessage M.Interested) 
  $$ peerSink  

  
  
sendRequest :: Sink BC.ByteString IO () -> (Int, Int, Int) -> IO() 
sendRequest peerSink req = 
  yield (M.encodeMessage $ M.Request req) 
  $$ peerSink 


logMSG :: Conduit BC.ByteString IO BC.ByteString   
logMSG = do
--  liftIO $ print "GOT MSG"
  m <- await
  case m of
       Nothing -> return ()
       Just x -> 
         do liftIO $ print ("REC " ++ (show (B.length x)))
            yield x
            logMSG       


            
{--            
            
main :: IO ()
main = do
    let src = mapM_ yield [1..3 :: Int]
        src2 = mapM_ yield [8..10 :: Int]
        src3 = getZipConduit $ ZipConduit src <* ZipConduit src2
        conduit1 = CL.map (+1)
     --   conduit2 = CL.concatMap (replicate 2)
     --   conduit = getZipConduit $ ZipConduit conduit1 <* ZipConduit conduit2
        sink = CL.mapM_ print
        sink1 = CL.mapM_ (\x -> print ("lala "++(show x)))
        sink3 = getZipConduit $ ZipConduit sink <* ZipConduit sink1
        src3 $$ conduit1 =$ sink3        --}   
            
            
            
            
            
            
 
 
data LogT m a = LogT {run :: m a} 



instance Functor (LogT IO) where
   fmap f (LogT l) = LogT $ fmap f l


instance Applicative (LogT IO) where
  pure = LogT . pure
  (LogT l1) <*> (LogT l2) = LogT $ l1 <*> l2


instance Monad (LogT IO) where
  return = pure
  (LogT l) >>= f = LogT $ do x <- l
                             run (f x)


   
type Writer a = (WT.Writer [a] ())
  



instance Functor (LogT (WT.Writer [a])) where
   fmap f (LogT l) = LogT $ fmap f l


instance Applicative (LogT (WT.Writer [a])) where
  pure = LogT . pure
  (LogT l1) <*> (LogT l2) = LogT $ l1 <*> l2

  
                             
instance Monad (LogT (WT.Writer [a])) where
  return = pure
  (LogT l) >>= f = LogT $ do x <- l
                             run (f x)
                             
                                                       
                             
class  Logger l where
  logg ::  String -> l String


  
instance MonadIO (LogT IO) where
  liftIO :: IO a -> LogT IO a
  liftIO a = LogT a
  
  
   
instance Logger (LogT IO) where
  logg a =  do liftIO $ print a
               return a



             
instance Logger (LogT (WT.Writer [String])) where
  logg a =  LogT (WT.writer (a, [a]))               
  
  
 
instance Logger (LogT []) where
  logg :: (Show a) => a -> LogT [] a
  logg a = LogT [a]
              


src :: (Monad l, Logger l) => Source l Int
src = do Trans.lift $ logg "xxx" 
         yield 1
         yield 2
         
         
si :: (Monad l, Logger l) => Sink Int l ()
si = do
        xM <- await
        case xM of
              Nothing -> do
                Trans.lift $ logg "aaa" 
                return ()
         
              Just x -> do
              si 
          

kk :: IO ()      
kk = run (src $$ si)         
      
ll :: ((), [String])      
ll = runIdentity $ WT.runWriterT $ run (src $$ si)         
               