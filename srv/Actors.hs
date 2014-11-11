{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module Actors (createAndInitActors) where

import Control.Distributed.Process as DP
import Control.Distributed.Process.Node
import Control.Distributed.Process.Serializable
import Network.Transport.TCP

import Control.Monad.IO.Class (liftIO)
import Control.Concurrent

import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.Map  as M
import qualified Data.List as L

import RoomActors
import ActorsMessages (FromRoomMsg(..))

data SupervisorState = SupervisorState {
    getProcessesByURL :: M.Map BS.ByteString [DP.ProcessId],
    getURLsByProcess  :: M.Map DP.ProcessId  [BS.ByteString] -- Ordered
    } deriving (Show)

initialSupervisorState :: SupervisorState
initialSupervisorState = SupervisorState M.empty M.empty

logMessage :: BS.ByteString -> Process (Maybe SupervisorState)
logMessage msg = do
    say $ "got unhandled string: " ++ BS.unpack msg ++ "\r\n"
    return Nothing

addIfNoExists :: Eq a => a -> [a] -> [a]
addIfNoExists newEl arr = maybe (newEl:arr) (\_ -> arr) (L.find (\el -> el == newEl) arr)

putImage :: SupervisorState -> (DP.ProcessId, BS.ByteString) -> SupervisorState
putImage state (owner, url) =
        let processesByURL = getProcessesByURL state
            urlsByProcess  = getURLsByProcess  state

            processes = M.findWithDefault [] url   processesByURL
            urls      = M.findWithDefault [] owner urlsByProcess

            newProcesses = addIfNoExists owner processes
            newUrls      = addIfNoExists url   urls
        
        in SupervisorState (M.insert url newProcesses processesByURL) (M.insert owner newUrls urlsByProcess)

-- data FromRoomMsg = URLAddedMsg { getURLOwner :: DP.ProcessId, getURL :: BS.ByteString }
--     | RoomClosedMsg { getURLOwner :: DP.ProcessId }
--     deriving (Show, Typeable {-!, Binary !-})

removePids :: DP.ProcessId -> [BS.ByteString] -> SupervisorState -> SupervisorState
removePids _ _ _ = undefined

removeRoom :: SupervisorState -> DP.ProcessId -> SupervisorState
removeRoom state roomPid =
    let urlsByProcess    = maybe [] id (M.lookup roomPid (getURLsByProcess state))
        removedPidsState = removePids roomPid urlsByProcess state

    in SupervisorState (getProcessesByURL removedPidsState) (M.delete roomPid (getURLsByProcess removedPidsState))

processAddImage :: SupervisorState -> FromRoomMsg -> Process (Maybe SupervisorState)
processAddImage state (URLAddedMsg owner url) = do
    let newState = putImage state (owner, url)
    say $ "+ newState: " ++ show newState
    return $ Just newState
processAddImage state (RoomClosedMsg closedRoom) = do
    let newState = removeRoom state closedRoom
    say $ "- newState: " ++ show newState
    return $ Just newState

supervisorProcess :: SupervisorState -> Process ()
supervisorProcess state = do
    newState <- receiveWait [match (processAddImage state), match logMessage]
    supervisorProcess $ maybe state id newState

createAndInitActors = do
    Right t <- createTransport "127.0.0.1" "10501" defaultTCPParameters
    node <- newLocalNode t initRemoteTable

    supervisorProcessID <- forkProcess node $ supervisorProcess initialSupervisorState

    forkIO $ runRoomServer node supervisorProcessID

    return ()
