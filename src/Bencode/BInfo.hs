{-# LANGUAGE RankNTypes, FlexibleContexts #-}

module Bencode.BInfo
    ( BP.BEncode
    , AnnounceType(..)
    , announceList
    , announce
    , infoHash
    , parseFromFile
    , BP.parse2BEncode
    , peers
    , piceSize
    , torrentSize
    , piecesHashSeq
    , torrentName
    , parsePathAndLenLs
    , makeSizeInfo
    , getAnnounce
    , BP.parseUDPAnnounce) where







import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Crypto.Hash.SHA1 as SHA1 (hash)
import qualified Data.Sequence as Seq
import qualified Bencode.BParser as BP
import qualified Data.Map as Map
import Data.Maybe (isJust)
import Control.Monad (join)
import Control.Monad.Except
import qualified Types as TP



import Types as TP
import Control.Lens


data DicInfo = Announce
             | AnnounceLst
             | PiecesHash
             | Peers
             | PieceSize
             | Info
             | SingleFile
             | Name
             | MultiFiles
             deriving Show


mkLens :: DicInfo -> Prism' BP.BEncode BP.BEncode
mkLens di =
    case di of
        Announce    -> BP.keyL "announce"
        AnnounceLst -> BP.keyL "announce-list"
        Peers       -> BP.keyL "peers"
        Info        -> infoLens
        PiecesHash  -> infoLens . BP.keyL "pieces"
        PieceSize   -> infoLens . BP.keyL "piece length"
        SingleFile  -> infoLens . BP.keyL "length"
        Name        -> infoLens . BP.keyL "name"
        MultiFiles  -> infoLens . BP.keyL "files"
        where
            infoLens :: Prism' BP.BEncode BP.BEncode
            infoLens = BP.keyL "info"


filesLs :: Prism' BP.BEncode BP.BEncode
filesLs = BP.keyL "info" . BP.keyL "files"


genericGet dI lenS dic =
    let ret = dic ^? (mkLens dI) . lenS
        msg = "Bencode parsing error: Missing " ++ show dI ++ " "++ (show dic)
    in maybe (Left msg) Right ret


isSingleFile :: BP.BEncode -> Bool
isSingleFile dic =
    let ret = dic ^? (mkLens SingleFile) . BP.bIntL
    in isJust ret--maybe False (const True) ret

announce :: BP.BEncode -> Either String BC.ByteString--String
announce = genericGet Announce BP.bStrL


--annouce :: BP.BEncode -> Either String BC.ByteString--String
announceLst = genericGet AnnounceLst BP.listL


peers :: BP.BEncode -> Either String BC.ByteString
peers = genericGet Peers BP.bStrL


piecesHash :: BP.BEncode -> Either String BC.ByteString
piecesHash = genericGet PiecesHash BP.bStrL


piceSize :: BP.BEncode -> Either String Int -- TODO type synnym
piceSize = genericGet PieceSize BP.bIntL


torrentSize :: BP.BEncode -> Either String Int
torrentSize = genericGet SingleFile BP.bIntL


infoHash :: BP.BEncode -> Either String String
infoHash dic = fun <$> genericGet Info BP.idL dic
    where
        fun = BC.unpack . SHA1.hash . BP.bencode2ByteString


info :: BP.BEncode -> Either String String
info dic = show <$> genericGet Info BP.idL dic


files :: BP.BEncode -> Either String BP.BEncode
files = genericGet MultiFiles BP.idL


torrentName :: BP.BEncode -> Either String BC.ByteString
torrentName = genericGet Name BP.bStrL


splitEvery :: Int -> BC.ByteString -> HashInfo
splitEvery n bc = if BC.null bc
                     then Seq.empty
                     else s Seq.<| splitEvery n e
                  where (s,e) = BC.splitAt n bc


piecesHashSeq :: BP.BEncode -> Either String HashInfo
piecesHashSeq dic = splitEvery 20 <$> piecesHash dic


multiFiles :: BP.BEncode -> Either String [(BC.ByteString, Int)]
multiFiles dic = do
    filesBencode <- files dic
    let fs =   (sequence . lsWordToPath. toPathLen . children) filesBencode
    maybe (Left "Wrong multi-files section in infodic") Right fs


--parseFromFile :: String ->  ExceptT String IO BP.BEncode

parseFromFile :: (MonadIO m, MonadError String m)
              => String
              ->  m BP.BEncode
parseFromFile path = do content <- liftIO $ B.readFile path
                        TP.tryEither $ BP.parse2BEncode content



data AnnounceType = HTTP  BC.ByteString | UDP  BC.ByteString


getAnnounce :: BC.ByteString -> Either String AnnounceType
getAnnounce st
    | BC.isPrefixOf (BC.pack "http") st =
        return $ HTTP st
    | BC.isPrefixOf (BC.pack "udp") st =
        return $ UDP st
    | otherwise =
        Left "Announce type not recognized"


makeSizeInfo :: [FileInfo]
             -> Int -> SizeInfo
makeSizeInfo fInfo pSize =
       let torrentSize = foldl (\acc fi -> (fSize fi) + acc ) 0 fInfo
           numberOfPieces =
               ceiling $ (fromIntegral torrentSize) / (fromIntegral pSize)
           lps = torrentSize `mod` pSize
           lastPieceSize = if lps == 0 then pSize else lps
        in
           SizeInfo numberOfPieces pSize lastPieceSize


parsePathAndLenLs :: BP.BEncode
                  -> Either String [TP.FileInfo]
parsePathAndLenLs content =
        if isSingleFile content
            then
                do tName <- torrentName content
                   tSize <- torrentSize content
                   return [FileInfo tName tSize]
            else
                fmap (fmap app) (multiFiles content)
                where
                    app = uncurry FileInfo


lsWordToPath ::  [Maybe ([BC.ByteString], Int)]
             ->  [Maybe (BC.ByteString, Int)]
lsWordToPath mLs = fmap (fmap concatPath) mLs
    where
        concatPath (ls, i) = (B.concat ls, i)


toPathLen :: [BP.BEncode] -> [Maybe ([BC.ByteString], Int)]
toPathLen ls =
    let path = BP.keyL "path" . BP.listL . traverse . BP.bStrL
        len  = BP.keyL "length" . BP.bIntL
    in map (\dic -> sequence (dic ^.. path, dic ^? len)) ls


announceList :: BP.BEncode -> Either String [BC.ByteString]
announceList torrentContent = do
    ls <- announceLst torrentContent
    let toLs =  BP.listL . traverse . BP.bStrL
    return $ map (\dic -> (dic ^. toLs)) ls



torrent = "/Users/blaze/Torrent/TorrentFiles/MOS2.torrent"

{--
kk = do
    Right b <- (runExceptT $ parseFromFile torrent)
--    let Right ls = announceLst b
--        l = [BP.BList[BP.BStr $ BC.pack "KK", BP.BStr $ BC.pack "00"]]
    return $ announceList ls
--}
