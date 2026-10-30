{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
module Aya.Audio.Wave (decodeWave, writeWaveHeader, writePCM24Block) where

import Aya.Audio.Types
import Control.Monad (unless)
import Data.Bits
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import Data.Int
import Data.Word
import Foreign (Ptr, peekElemOff, pokeElemOff)
import GHC.Float (castWord32ToFloat, castWord64ToDouble)
import System.IO (Handle, hPutBuf)
import qualified Data.Vector.Storable as Vector

decodeWave :: ByteString.ByteString -> Either AudioError PCM
decodeWave bytes = do
  check (ByteString.length bytes >= 12 && tag 0 == "RIFF" && tag 8 == "WAVE") "Expected a little-endian RIFF WAVE file"
  check (riffEnd >= 12 && riffEnd <= ByteString.length bytes) "WAV RIFF length is invalid or exceeds the supplied file"
  (formatStart,formatBytes,dataStart,dataBytes) <- chunks 12 Nothing Nothing
  check (formatBytes >= 16) "WAV fmt chunk is truncated"
  let originalFormat = word16 formatStart
      channels = fromIntegral (word16 (formatStart+2))
      rate = fromIntegral (word32 (formatStart+4))
      blockAlign = fromIntegral (word16 (formatStart+12))
      bits = fromIntegral (word16 (formatStart+14)) :: Int
      sampleBytes = bits `quot` 8
  check (channels == 1 || channels == 2) "WAV import supports mono or stereo; convert surround material first"
  check (rate >= 8000 && rate <= 384000) "WAV sample rate must be 8000..384000 Hz"
  format <- if originalFormat == 0xfffe then do
              check (formatBytes >= 40 && word16 (formatStart+16) >= 22) "WAVE_FORMAT_EXTENSIBLE header is truncated"
              check (word16 (formatStart+18) == fromIntegral bits) "Packed WAV valid bits differing from container bits are unsupported"
              check (ByteString.take 12 (ByteString.drop (formatStart+28) bytes) == ByteString.pack [0,0,16,0,128,0,0,170,0,56,155,113]) "WAV extensible subtype GUID is unsupported"
              pure (word16 (formatStart+24))
            else pure originalFormat
  check ((format == 1 && bits `elem` [8,16,24,32]) || (format == 3 && bits `elem` [32,64])) "WAV supports PCM 8/16/24/32-bit or IEEE float 32/64-bit only"
  check (blockAlign == channels * sampleBytes && blockAlign > 0 && dataBytes `rem` blockAlign == 0) "WAV data is not aligned to complete audio frames"
  let frames = dataBytes `quot` blockAlign
      values = frames * channels
  check (frames > 0) "WAV contains no audio frames"
  check (values <= 24 * 1024 * 1024) "Decoded WAV exceeds the 96 MiB audio sample capacity; trim the material"
  let sample index =
        let position = dataStart + index*sampleBytes
        in if format == 3 then
             if bits == 32 then castWord32ToFloat (word32 position)
             else realToFrac (castWord64ToDouble (word64 position))
           else case bits of
             8 -> (fromIntegral (byte position) - 128) / 128
             16 -> fromIntegral (fromIntegral (word16 position) :: Int16) / 32768
             24 -> let raw = fromIntegral (byte position) .|. (fromIntegral (byte (position+1)) `shiftL` 8) .|. (fromIntegral (byte (position+2)) `shiftL` 16) :: Int32
                       signed = if testBit raw 23 then raw .|. complement 0xffffff else raw
                   in fromIntegral signed / 8388608
             _ -> fromIntegral (fromIntegral (word32 position) :: Int32) / 2147483648
      samples = Vector.generate values sample
  check (Vector.all (\value -> not (isNaN value || isInfinite value) && abs value <= 8) samples) "WAV contains nonfinite or excessively loud floating-point samples"
  pure (PCM rate channels frames samples)
  where
    byte = ByteString.index bytes
    riffEnd = fromIntegral (word32 4) + 8
    tag offset = ByteString.take 4 (ByteString.drop offset bytes)
    word16 offset = fromIntegral (byte offset) .|. (fromIntegral (byte (offset+1)) `shiftL` 8) :: Word16
    word32 offset = fromIntegral (word16 offset) .|. (fromIntegral (word16 (offset+2)) `shiftL` 16) :: Word32
    word64 offset = fromIntegral (word32 offset) .|. (fromIntegral (word32 (offset+4)) `shiftL` 32) :: Word64
    check condition message = unless condition (Left (AudioError message))
    chunks position fmt audio
      | position + 8 > riffEnd = case (fmt,audio) of
          (Just (formatStart,formatLength),Just (dataStart,dataLength)) -> Right (formatStart,formatLength,dataStart,dataLength)
          _ -> Left (AudioError "WAV must contain fmt and data chunks")
      | otherwise = do
          let size = fromIntegral (word32 (position+4)) :: Int
              start = position+8
              end = start+size
          check (end >= start && end <= riffEnd) "WAV chunk length exceeds the declared RIFF container"
          let nextFormat = if tag position == "fmt " then Just (start,size) else fmt
              nextAudio = if tag position == "data" then Just (start,size) else audio
          case (nextFormat,nextAudio) of
            (Just (formatStart,formatLength),Just (dataStart,dataLength)) -> Right (formatStart,formatLength,dataStart,dataLength)
            _ -> chunks (end + size `rem` 2) nextFormat nextAudio

writeWaveHeader :: Handle -> Frame -> IO ()
writeWaveHeader handle frames = Lazy.hPut handle $ Builder.toLazyByteString $
  Builder.byteString "RIFF" <> Builder.word32LE (fromIntegral (36 + frames*6)) <>
  Builder.byteString "WAVEfmt " <> Builder.word32LE 16 <> Builder.word16LE 1 <>
  Builder.word16LE 2 <> Builder.word32LE (fromIntegral sampleRate) <>
  Builder.word32LE (fromIntegral (sampleRate*6)) <> Builder.word16LE 6 <>
  Builder.word16LE 24 <> Builder.byteString "data" <> Builder.word32LE (fromIntegral (frames*6))

writePCM24Block :: Handle -> Ptr Float -> Ptr Word8 -> Int -> IO ()
writePCM24Block handle input bytes frames = fill 0 >> hPutBuf handle bytes (frames*6)
  where
    fill !index
      | index >= frames*2 = pure ()
      | otherwise = do
          value <- peekElemOff input index
          let limited = max (-1) (min (1-1/8388608) value)
              sample = round (limited * 8388608) :: Int32
          pokeElemOff bytes (index*3) (fromIntegral sample)
          pokeElemOff bytes (index*3+1) (fromIntegral (sample `shiftR` 8))
          pokeElemOff bytes (index*3+2) (fromIntegral (sample `shiftR` 16))
          fill (index+1)
