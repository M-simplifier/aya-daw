{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Aya.Audio
import Control.Concurrent (threadDelay)
import Control.Exception (finally)
import Control.Exception (evaluate)
import Control.Monad (forM_,void,when)
import qualified Data.Vector.Storable as Vector
import System.Mem (performGC)
import System.Environment (getArgs)
import System.Exit (die)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--audio-worker",name] -> runAudioWorker name
    ["--device"] -> deviceTest
    ["--device-reference",directory] -> runAudioDeviceTest directory >>= either (die . show) Text.putStrLn
    ["--stress"] -> stressTest
    ["--selftest",directory] -> runAudioSelfTest directory >>= either (die . show) Text.putStrLn
    _ -> runAudioSelfTest ".work/audio-tests" >>= either (die . show) Text.putStrLn

deviceTest :: IO ()
deviceTest = do
  opened <- startEngine
  case opened of
    Left failure -> die (show failure)
    Right engine -> flip finally (closeEngine engine) $ do
      let patch = defaultPatch {patchDelaySend=0.2,patchRelease=0.2}
          instruments = [Bass,Pad,Bell,Lead,Pluck,Kick,Snare,Hat]
          tracks = [AudioTrack (Text.pack (show instrument)) instrument 0.35 0 False patch Nothing [] | instrument <- instruments]
          notes = [AudioNote (Text.pack ("note-" ++ show index)) (Text.pack (show instrument)) (fromIntegral index*12000) 8000 (if instrument == Bass then 110 else 261.6255653005986) 0.7 | (index,instrument) <- zip [0::Int ..] instruments]
          plan = AudioPlan 120 144000 0.12 Nothing tracks notes []
      setPlan engine plan >>= either (die . show) pure
      sendTransport engine Play >>= either (die . show) pure
      forM_ [1::Int .. 4] $ \_ -> threadDelay 1000000 >> readEngineStatus engine >>= print
      void (sendTransport engine Stop)
      threadDelay 100000

stressTest :: IO ()
stressTest = do
  opened <- startEngine
  case opened of
    Left failure -> die (show failure)
    Right engine -> flip finally (closeEngine engine) $ do
      let family index = toEnum (index `mod` 8)
          patch = defaultPatch {patchAttack=0.001,patchRelease=0.02,patchDelaySend=0.1,patchDelayBeats=0.125}
          tracks = [AudioTrack (Text.pack ("track-" ++ show index)) (family index) 0.25 (fromIntegral (index `mod` 7)/3-1) False patch Nothing [] | index <- [0::Int ..31]]
          notes = [AudioNote (Text.pack ("note-" ++ show trackIndex ++ "-" ++ show voiceIndex)) (trackId track) 0 288000 (90+fromIntegral trackIndex*23.125+fromIntegral voiceIndex*13.333333) 0.6 | (trackIndex,track) <- zip [0::Int ..] tracks,voiceIndex <- [0::Int ..7]]
          plan = AudioPlan 120 384000 0.002 (Just (0,384000)) tracks notes []
      setPlan engine plan >>= either (die . show) pure
      sendTransport engine Play >>= either (die . show) pure
      forM_ [1::Int ..12] $ \iteration -> do
        forM_ [1::Int ..5] $ \seed -> do
          void (evaluate (Vector.sum (Vector.generate 1000000 (\index -> sin (fromIntegral (index+seed)*0.001)) :: Vector.Vector Double)))
          performGC
        setPlan engine (plan {planTracks=if even iteration then tracks else reverse tracks}) >>= either (die . show) pure
        threadDelay 500000
        status <- readEngineStatus engine
        print status
        when (not (engineAvailable status) || engineVoiceOverflows status /= 0) (die "Native stress lost availability or voices")
        when (engineLateBuffers status /= 0 || engineUnderruns status /= 0) (die "Native stress observed a missed deadline or an empty endpoint buffer; inspect the timing report")
      void (sendTransport engine Stop)
      threadDelay 100000
