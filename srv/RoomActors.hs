{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module RoomActors (runRoomServer) where

import qualified Network.WebSockets as WS

import Control.Distributed.Process as DP
import Control.Distributed.Process.Node

import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.ByteString as B
import qualified Data.Aeson as AES ((.:), decode)
import Data.Aeson.Types
import Data.Text
import Data.Maybe
import Data.Binary.Get
import qualified Data.Binary as BN
import qualified Data.ByteString.Base64 as B64

import Text.Read
import Control.Exception
import Control.Applicative ((<$>))

import ActorsMessages (FromRoomMsg(..), SocketMsg(..), FromClientMsg(..), RoomToClientMsg(..))
import ActorsCmn (jsonObjectWithType)

data RoomState = RoomState { getRoomURLs :: [String], getSupervisor :: DP.ProcessId, getConnection :: WS.Connection }

-- TODO use Data.ByteString.Base64.Lazy

pid2Str :: DP.ProcessId -> String
pid2Str = BS.unpack . b64encode . BN.encode where
    b64encode str = BS.fromChunks [B64.encode (B.concat $ BS.toChunks str)]

str2Pid :: String -> Either String DP.ProcessId
str2Pid str = undefined

initialRoomState :: DP.ProcessId -> WS.Connection -> RoomState 
initialRoomState = RoomState []

logMessage :: BS.ByteString -> Process (Maybe RoomState)
logMessage msg = do
    say $ "got unhandled string: " ++ BS.unpack msg ++ "\r\n"
    return Nothing

processAddImageCmd :: Object -> RoomState -> Process (Maybe RoomState)
processAddImageCmd json state = do

    -- {"msgType":"ImageAdded","url":"https://pp.vk.me/c624927/v624927433/8eaa/xxCjYjDRAxk.jpg"}
    let addedImage :: Maybe String = parseMaybe (.: "url") json
    case addedImage of
        (Just addedImage) -> do
            self <- getSelfPid
            send (getSupervisor state) (URLAddedMsg self (BS.pack addedImage))
            return Nothing
        Nothing -> do
            say $ "no image in json: " ++ show json
            return Nothing

b64decode :: BS.ByteString -> Maybe BS.ByteString
b64decode str = 
    case res of
        (Right res) -> Just $ BS.fromChunks [res]
        (Left _) -> Nothing
        where
            res = B64.decode (B.concat $ BS.toChunks str)

b64decodeStr :: String -> Maybe String
b64decodeStr str = BS.unpack <$> (b64decode $ BS.pack str)

processNoImageCmd :: Object -> RoomState -> Process (Maybe RoomState)
processNoImageCmd json state = do

    -- {"msgType":"NoRequestedURL","cpid":"pid://127.0.0.1:10501:0:17"}
    let clientStr :: Maybe String = (parseMaybe (.: "cpid") json) >>= b64decodeStr
    case clientStr of
        (Just clientStr) ->
            case res of
                (Right (_, _, client)) -> do
                    say $ "room: send to client NoImageOnWebError: " ++ show client
                    send client NoImageOnWebError
                    return Nothing
                (Left _) -> do
                    say $ "room: invalid client pid in json: " ++ show clientStr
                    return Nothing

                where res = (BN.decodeOrFail (BS.pack clientStr)) 
        Nothing -> do
            say $ "room: no client pid in json: " ++ show json
            return Nothing

processSocketMesssage :: RoomState -> SocketMsg -> Process (Maybe RoomState)
processSocketMesssage state (SocketMsg msg) =
    case jsonObjectWithType msg of
        (Right ("ImageAdded"    , json)) -> processAddImageCmd json state
        (Right ("NoRequestedURL", json)) -> processNoImageCmd  json state
        (Right (cmd, json)) -> do
            -- TODO process command: NoRequestedURL json: fromList [("cpid",String "pid://127.0.0.1:10501:0:17"),("msgType",String "NoRequestedURL")]
            say $ "room got unsupported command: " ++ cmd ++ " json: " ++ show json
            return Nothing
        Left description -> do
            say description
            return Nothing
processSocketMesssage state CloseMsg = do
    self <- getSelfPid
    send (getSupervisor state) (RoomClosedMsg self)
    die ("Socket closed - close room" :: String)
    return Nothing

processClientMsgs :: RoomState -> FromClientMsg -> Process (Maybe RoomState)
processClientMsgs state (RequestOffer client url) = do

    let conn = getConnection state
        clt  = pid2Str client
        cmd  = pack $ "{\"msgType\":\"RequestOffer\",\"url\":\"" ++ BS.unpack url ++ "\",\"cpid\":\"" ++ clt ++ "\"}"
        in do
            -- TODO handle exception on send here ???
            say $ "room: send to socket: " ++ unpack cmd
            liftIO $ WS.sendTextData conn cmd
    return Nothing

roomProcess :: RoomState -> Process ()
roomProcess state = do
    -- Test our matches in order against each message in the queue
    newState <- receiveWait [
        match (processSocketMesssage state),
        match (processClientMsgs state),
        match logMessage ]
    roomProcess $ fromMaybe state newState

roomSocketProcess :: ProcessId -> WS.Connection -> Process ()
roomSocketProcess processId conn = do
    result <- liftIO $ WS.receive conn
    case result of
        (WS.ControlMessage (WS.Close code msg)) -> do
            --say $ "did receiveData command with code: " ++ show code ++ " msg: " ++ BS.unpack msg
            send processId CloseMsg
            return ()
        (WS.DataMessage (WS.Text msg)) -> do
            say $ "room: did receiveData msg: " ++ BS.unpack msg
            send processId (SocketMsg msg)
            roomSocketProcess processId conn
        (WS.DataMessage (WS.Binary msg)) ->
            -- TODO send die to roomProcess
            return ()

roomApplication :: LocalNode -> DP.ProcessId -> WS.PendingConnection -> IO ()
roomApplication node supervisorProcessID pending = do
    conn <- WS.acceptRequest pending

    liftIO $ Prelude.putStrLn "room: got new connection"
    roomProcessID <- forkProcess node (roomProcess $ initialRoomState supervisorProcessID conn)
    runProcess node $ roomSocketProcess roomProcessID conn

    return ()

runRoomServer :: LocalNode -> DP.ProcessId -> IO ()
runRoomServer node supervisor = WS.runServer "127.0.0.1" 27001 $ roomApplication node supervisor
