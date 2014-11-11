{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE DeriveDataTypeable #-}

module ActorsMessages (FromRoomMsg(..), SocketMsg(..)) where

import Control.Distributed.Process as DP

import Data.Binary
import Data.Typeable
import qualified Data.ByteString.Lazy.Char8 as BS
import Data.DeriveTH

data FromRoomMsg = URLAddedMsg { getURLOwner :: DP.ProcessId, getURL :: BS.ByteString }
    | RoomClosedMsg { getURLOwner :: DP.ProcessId }
    deriving (Show, Typeable {-!, Binary !-})

$( derive makeBinary ''FromRoomMsg )

data SocketMsg = SocketMsg BS.ByteString | CloseMsg deriving (Show, Typeable {-!, Binary !-})
$( derive makeBinary ''SocketMsg )
