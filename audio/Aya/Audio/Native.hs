{-# LANGUAGE ForeignFunctionInterface #-}
module Aya.Audio.Native where

import Data.Int
import Data.Bits ((.&.))
import Data.Word
import Foreign (Ptr, plusPtr)
import Foreign.C

data Mapping
data Device
data Child

foreign import ccall unsafe "aya_map_create" mapCreate :: CString -> IO (Ptr Mapping)
foreign import ccall unsafe "aya_map_open" mapOpen :: CString -> IO (Ptr Mapping)
foreign import ccall unsafe "aya_map_data" mapData :: Ptr Mapping -> IO (Ptr Word8)
foreign import ccall unsafe "aya_map_close" mapClose :: Ptr Mapping -> IO ()
foreign import ccall unsafe "aya_parent_alive" parentAlive :: Ptr Mapping -> IO CInt
foreign import ccall unsafe "aya_atomic_read32" atomicRead32 :: Ptr a -> IO Word32
foreign import ccall unsafe "aya_atomic_write32" atomicWrite32 :: Ptr a -> Word32 -> IO ()
foreign import ccall unsafe "aya_atomic_read64" atomicRead64 :: Ptr a -> IO Word64
foreign import ccall unsafe "aya_atomic_write64" atomicWrite64 :: Ptr a -> Word64 -> IO ()
foreign import ccall unsafe "aya_process_id" processId :: IO Word32
foreign import ccall safe "aya_spawn" spawn :: CString -> CString -> IO (Ptr Child)
foreign import ccall unsafe "aya_child_alive" childAlive :: Ptr Child -> IO CInt
foreign import ccall safe "aya_child_wait" childWait :: Ptr Child -> CInt -> IO CInt
foreign import ccall unsafe "aya_child_terminate" childTerminate :: Ptr Child -> IO ()
foreign import ccall unsafe "aya_child_close" childClose :: Ptr Child -> IO ()
foreign import ccall unsafe "aya_clock" clockSeconds :: IO Double
foreign import ccall safe "aya_device_open" deviceOpen :: Ptr Int32 -> IO (Ptr Device)
foreign import ccall safe "aya_device_close" deviceClose :: Ptr Device -> IO ()
foreign import ccall unsafe "aya_device_frames" deviceFrames :: Ptr Device -> IO CInt
foreign import ccall unsafe "aya_device_start" deviceStart :: Ptr Device -> IO Int32
foreign import ccall safe "aya_device_wait" deviceWait :: Ptr Device -> CInt -> IO CInt
foreign import ccall unsafe "aya_device_begin" deviceBegin :: Ptr Device -> IO CInt
foreign import ccall unsafe "aya_device_buffer" deviceBuffer :: Ptr Device -> IO (Ptr Float)
foreign import ccall unsafe "aya_device_end" deviceEnd :: Ptr Device -> IO Int32
foreign import ccall unsafe "aya_device_starvation" deviceStarvation :: Ptr Device -> IO Word64
foreign import ccall unsafe "aya_device_error" deviceError :: Ptr Device -> IO Int32

headerBytes, slotBytes, commandBase, commandStride, commandCapacity :: Int
headerBytes = 4096
slotBytes = 128 * 1024 * 1024
commandBase = 1024
commandStride = 48
commandCapacity = 64

slotAddress :: Ptr Word8 -> Word64 -> Ptr Word8
slotAddress base generation = base `plusPtr` (headerBytes + fromIntegral (generation .&. 1) * slotBytes)
