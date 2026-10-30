{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
module Aya.Audio.Diagnostics (kernelChecks, deviceReferenceProbe) where

import Aya.Audio.Types
import Aya.Audio.Plan
import Aya.Audio.Kernel
import Aya.Audio.Reference
import qualified Aya.Audio.Native as Native
import Aya.Audio.Wave
import Control.Concurrent (runInBoundThread)
import Control.Exception (bracket,finally)
import Control.Monad (forM_,when,unless)
import Data.Int (Int32)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import Data.Word (Word8)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector.Storable as Vector
import Foreign (Ptr, mallocBytes, mallocArray, free, plusPtr, peekArray, peekElemOff, nullPtr, alloca, peek, fillBytes, copyBytes)
import GHC.Conc (getAllocationCounter)
import System.FilePath ((</>))
import System.IO (withBinaryFile,IOMode(WriteMode))

withPlan :: AudioPlan -> (Ptr Word8 -> IO a) -> IO a
withPlan source action = case preparePlan source of
  Left failure -> fail (show failure)
  Right prepared -> bracket (mallocBytes (preparedBytes prepared)) free $ \plan -> do
    writePlan plan prepared
    valid <- checkFlatPlan plan
    assert "serialized plan dimensions admitted by worker" valid
    action plan

assert :: String -> Bool -> IO ()
assert name condition = unless condition (fail ("Audio assertion: " ++ name))

fixtureTrack :: AudioTrack
fixtureTrack = AudioTrack "voice" Lead 0.5 0 False (defaultPatch {patchAttack=1,patchRelease=0.2,patchDelaySend=0}) Nothing []

fixtureNote :: AudioNote
fixtureNote = AudioNote "held" "voice" 0 24000 220.125 0.6

fixturePlan :: AudioPlan
fixturePlan = AudioPlan 120 48000 0.1 Nothing [fixtureTrack] [fixtureNote] []

kernelChecks :: IO Text
kernelChecks = do
  withPlan fixturePlan $ \original -> bracket (mallocArray (48000*2)) free $ \buffer -> do
    let snapshot runtime = voiceSnapshot runtime (stableId "held") >>= maybe (fail "Expected a sounding note") pure
        render runtime plan count = processBlock runtime plan buffer count
        start runtime = installPlan runtime original >> applyCommand runtime original 1 0 0 0 0 0 >> render runtime original 512
    withRuntime $ \runtime -> do
      start runtime
      before <- snapshot runtime
      withPlan (fixturePlan {planNotes=[fixtureNote {noteFrequency=223.333333333}]}) $ \pitched -> do
        installPlan runtime pitched
        after <- snapshot runtime
        assert "pitch edit retains exact phase/age/filter lifetime" (snapshotPhase before == snapshotPhase after && snapshotAge before == snapshotAge after && snapshotEnvelope before == snapshotEnvelope after)
        render runtime pitched 16
        evolved <- snapshot runtime
        let frequencies = drop 1 (scanl (\frequency _ -> frequency+0.003*(223.333333333-frequency)) (snapshotFrequency before) [1::Int ..16])
            expectedPhase = snapshotPhase before+sum frequencies/fromIntegral sampleRate
        assert "fractional Hz phase follows independent smoothed recurrence" (abs (snapshotPhase evolved-(expectedPhase-fromIntegral (floor expectedPhase :: Int))) < 1e-12)
    withRuntime $ \runtime -> do
      start runtime
      withPlan (fixturePlan {planNotes=[fixtureNote {noteStartFrame=12000,noteDurationFrames=12000}]}) $ \moved -> do
        installPlan runtime moved
        after <- snapshot runtime
        assert "moving a held note into the future releases old onset" (snapshotReleaseAge after == 0)
        assert "fault retaining old gate is rejected" (not (snapshotReleaseAge after < 0))
        render runtime moved 11000
        absent <- voiceSnapshot runtime (stableId "held")
        assert "old onset has ended before future onset" (absent == Nothing)
        render runtime moved 489
        future <- snapshot runtime
        assert "moved note retriggers at exact future onset" (snapshotAge future == 1)
    withRuntime $ \runtime -> do
      start runtime
      withPlan (fixturePlan {planNotes=[fixtureNote {noteDurationFrames=700}]}) $ \shortened -> do
        installPlan runtime shortened
        after <- snapshot runtime
        assert "shortened live note uses new end, not old duration" (snapshotGate after == 700)
        render runtime shortened 200
        releasing <- snapshot runtime
        assert "shortened gate reached" (snapshotAge releasing > snapshotGate releasing)
      withPlan (fixturePlan {planNotes=[]}) $ \deleted -> do
        installPlan runtime deleted
        after <- snapshot runtime
        assert "deleting a live note begins release" (snapshotReleaseAge after == 0)
    withRuntime $ \runtime -> do
      installPlan runtime original
      applyCommand runtime original 8 (stableId "voice") 220.125 0.7 0 (stableId "key")
      render runtime original 2400
      before <- voiceSnapshot runtime (stableId "key") >>= maybe (fail "Missing audition") pure
      applyCommand runtime original 9 0 0 0 0 (stableId "key")
      render runtime original 1200
      after <- voiceSnapshot runtime (stableId "key") >>= maybe (fail "Missing release") pure
      let expected = snapshotEnvelope before*(1-1199/9600)
      assert "early keyup freezes attack level then releases" (snapshotEnvelope after < snapshotEnvelope before && abs (snapshotEnvelope after-expected) < 1e-12)
      lastLeft <- peekElemOff buffer (1199*2)
      applyCommand runtime original 6 0 0 0 0 0
      render runtime original 128
      firstLeft <- peekElemOff buffer 0
      endLeft <- peekElemOff buffer 254
      assert "panic fades last output without a discontinuous zero" (abs (firstLeft-lastLeft) <= abs lastLeft/127+1e-9 && endLeft == (0::Float))
    withRuntime $ \runtime -> do
      start runtime
      applyCommand runtime original 4 0 12000 0 0 0
      after <- snapshot runtime
      assert "seek resets and chases interval age" (snapshotAge after == 12000)
      withPlan (fixturePlan {planLoop=Just (480,960)}) $ \looped -> do
        installPlan runtime looped
        applyCommand runtime looped 4 0 800 0 0 0
        render runtime looped 400
        frame <- runtimePosition runtime
        assert "loop performs exact reset/chase at boundary" (frame == 720)
    withRuntime $ \runtime -> do
      start runtime
      render runtime original 32
      allocationBefore <- getAllocationCounter
      render runtime original 4800
      allocationAfter <- getAllocationCounter
      assert "steady sample path has only a bounded block entry allocation" (allocationBefore-allocationAfter <= 512)
      putStrLn ("steady_4800_frame_allocation_bytes=" ++ show (allocationBefore-allocationAfter))
  let duplicate = fixturePlan {planTracks=[fixtureTrack,fixtureTrack]}
      oversized = fixturePlan {planNotes=[fixtureNote {noteId=Text.pack (show index)} | index <- [1::Int ..257]]}
  assert "duplicate identities rejected" (isLeft (validateAudioPlan duplicate))
  assert "257 overlapping voices rejected before replacement" (isLeft (validateAudioPlan oversized))
  assert "NaN rejected" (isLeft (validateAudioPlan (fixturePlan {planMasterGain=0/0})))
  deterministicPartitionCheck
  waveChecks
  pure "live_move/shorten/delete/pitch/keyup/panic/seek/loop/capacity/partition=pass"
  where isLeft (Left _) = True
        isLeft _ = False

waveChecks :: IO ()
waveChecks = do
  let cases =
        [(1,8,Builder.word8 0 <> Builder.word8 255,[-1,127/128]),
         (1,16,Builder.int16LE (-32768) <> Builder.int16LE 16384,[-1,0.5]),
         (1,24,Builder.byteString (ByteString.pack [0,0,128,0,0,64]),[-1,0.5]),
         (1,32,Builder.int32LE minBound <> Builder.int32LE 1073741824,[-1,0.5]),
         (3,32,Builder.floatLE (-0.25) <> Builder.floatLE 0.375,[-0.25,0.375]),
         (3,64,Builder.doubleLE (-0.25) <> Builder.doubleLE 0.375,[-0.25,0.375])]
      wave format bits payload =
        let samples = Builder.toLazyByteString payload
        in Lazy.toStrict $ Builder.toLazyByteString $
          Builder.byteString "RIFF" <> Builder.word32LE (36+fromIntegral (Lazy.length samples)) <>
          Builder.byteString "WAVEfmt " <> Builder.word32LE 16 <> Builder.word16LE format <>
          Builder.word16LE 1 <> Builder.word32LE 48000 <>
          Builder.word32LE (48000*fromIntegral bits `quot` 8) <> Builder.word16LE (bits `quot` 8) <>
          Builder.word16LE bits <> Builder.byteString "data" <> Builder.word32LE (fromIntegral (Lazy.length samples)) <>
          Builder.lazyByteString samples
  forM_ cases $ \(format,bits,payload,expected) -> case decodeWave (wave format bits payload) of
    Left failure -> fail ("Expected supported WAV " ++ show (format,bits,failure))
    Right pcm -> assert ("WAV normalized decoding " ++ show (format,bits)) (pcmFrames pcm == 2 && pcmSampleRate pcm == sampleRate && Vector.toList (pcmSamples pcm) == expected)
  let nanWave = wave 3 32 (Builder.floatLE (0/0) <> Builder.floatLE 0)
      compressed = wave 6 16 (Builder.int16LE 0 <> Builder.int16LE 0)
      truncated = ByteString.take 42 (wave 1 16 (Builder.int16LE 0 <> Builder.int16LE 0))
  forM_ [nanWave,compressed,truncated,ByteString.pack [82,73,70,70,0,0,0,0,87,65,86,69]] $ \invalid ->
    assert "invalid/NaN/compressed WAV rejected" (case decodeWave invalid of Left _ -> True; Right _ -> False)

deterministicPartitionCheck :: IO ()
deterministicPartitionCheck = do
  let instruments = [Bass,Pad,Bell,Lead,Pluck,Kick,Snare,Hat,Sample]
      source = AudioPlan 120 8000 0.1 Nothing
        [AudioTrack (Text.pack (show instrument)) instrument 0.2 (fromIntegral index/4-1) False
          (defaultPatch {patchAttack=0.001,patchRelease=0.08,patchDelayBeats=0.03125,patchDelaySend=0.3})
          (if instrument == Sample then Just "pcm" else Nothing)
          [Automation Gain [(0,0.2),(4000,0.4),(8000,0.1)],Automation Cutoff [(0,12000),(8000,500)]]
          | (index,instrument) <- zip [0::Int ..] instruments]
        [AudioNote (Text.pack (show instrument)) (Text.pack (show instrument)) (fromIntegral index*67) 6000 (220.125+fromIntegral index*37.777) 0.7 | (index,instrument) <- zip [0::Int ..] instruments]
        [AudioSample "pcm" (PCM 44100 2 1000 (Vector.generate 2000 (\index -> realToFrac (sin (fromIntegral index*0.03)*0.1 :: Double))))]
      count = 16000
  withPlan source $ \plan -> bracket (mallocArray (count*2)) free $ \whole -> bracket (mallocArray (count*2)) free $ \partitioned -> do
    withRuntime $ \runtime -> do
      installPlan runtime plan; applyCommand runtime plan 1 0 0 0 0 0
      processBlock runtime plan whole count
    withRuntime $ \runtime -> do
      installPlan runtime plan; applyCommand runtime plan 1 0 0 0 0 0
      processBlock runtime plan partitioned 1024
      before <- getAllocationCounter
      processBlock runtime plan partitioned 4096
      after <- getAllocationCounter
      assert "active automation/sample/synth inner path has bounded block entry allocation" (before-after <= 512)
      putStrLn ("nine_instruments_automation_4096_frame_allocation_bytes=" ++ show (before-after))
    withRuntime $ \runtime -> do
      installPlan runtime plan; applyCommand runtime plan 1 0 0 0 0 0
      let walk !offset sizes
            | offset >= count = pure ()
            | otherwise = case sizes of
                [] -> walk offset [1,31,33,64,511,97]
                size:rest -> do
                  let amount = min size (count-offset)
                  processBlock runtime plan (partitioned `plusPtr` (offset*8)) amount
                  walk (offset+amount) rest
      walk 0 []
    first <- peekArray (count*2) whole
    second <- peekArray (count*2) partitioned
    assert "all nine instruments, PCM pitch, automation and delay are block-partition deterministic" (first == second && any (/=0) first && all (\value -> not (isNaN value || isInfinite value)) first)

deviceReferenceProbe :: FilePath -> IO Text
deviceReferenceProbe directory = runInBoundThread $ withPlan impulse $ \first -> withPlan reordered $ \second -> withRuntime $ \runtime ->
  bracket (mallocArray (count*2)) free $ \capture -> alloca $ \errorPointer -> do
    device <- Native.deviceOpen errorPointer
    when (device == nullPtr) (peek errorPointer >>= \code -> fail ("WASAPI probe open failed: " ++ show (code::Int32)))
    flip finally (Native.deviceClose device) $ do
      installPlan runtime first; applyCommand runtime first 1 0 0 0 0 0
      initial <- Native.deviceBegin device
      when (initial > 0) $ do
        buffer <- Native.deviceBuffer device
        fillBytes buffer 0 (fromIntegral initial*8)
        Native.deviceEnd device >>= \code -> assert "prime native device" (code >= 0)
      Native.deviceStart device >>= \code -> assert "start native device" (code >= 0)
      let supply !offset !swapped !maximumTime !late !packets
            | offset >= count = pure (maximumTime,late,packets)
            | otherwise = do
                signaled <- Native.deviceWait device 1000
                assert "native event arrived" (signaled == 1)
                start <- Native.clockSeconds
                available <- Native.deviceBegin device
                assert "native render buffer acquired" (available >= 0)
                if available == 0 then supply offset swapped maximumTime late packets else do
                  buffer <- Native.deviceBuffer device
                  let amount = min (fromIntegral available) (count-offset)
                      beforeSwap = max 0 (min amount (swapAt-offset))
                  if not swapped && offset+amount > swapAt then do
                    when (beforeSwap > 0) (processBlock runtime first buffer beforeSwap)
                    installPlan runtime second
                    processBlock runtime second (buffer `plusPtr` (beforeSwap*8)) (amount-beforeSwap)
                  else processBlock runtime (if swapped then second else first) buffer amount
                  copyBytes (capture `plusPtr` (offset*8)) buffer (amount*8)
                  when (amount < fromIntegral available) (fillBytes (buffer `plusPtr` (amount*8)) 0 ((fromIntegral available-amount)*8))
                  Native.deviceEnd device >>= \code -> assert "native samples supplied" (code >= 0)
                  finish <- Native.clockSeconds
                  let micros = (finish-start)*1e6
                      deadline = fromIntegral available/fromIntegral sampleRate*1e6
                  supply (offset+amount) (swapped || offset+amount > swapAt) (max maximumTime micros) (late+if micros > deadline then 1 else 0) (packets+1)
      (maximumTime,late,packets) <- supply 0 False 0 (0::Int) (0::Int)
      starvation <- Native.deviceStarvation device
      supplied <- peekArray (count*2) capture
      let expected = concatMap (\(left,right) -> [left,right]) (referenceImpulse specification count)
          maxError = foldl' max 0 (zipWith (\a b -> abs (realToFrac a-realToFrac b :: Double)) supplied expected)
          faulty = concatMap (\(left,right) -> [left,right]) (referenceWithDelayReset specification swapAt count)
          faultyError = foldl' max 0 (zipWith (\a b -> abs (realToFrac a-realToFrac b :: Double)) supplied faulty)
      assert "ACTUAL supplied WASAPI samples match independent reference" (maxError <= 2e-7 && faultyError > 1e-7)
      withBinaryFile (directory </> "wasapi-supplied-reference.wav") WriteMode $ \handle -> bracket (mallocBytes (count*6)) free $ \bytes -> do
        writeWaveHeader handle (fromIntegral count)
        writePCM24Block handle capture bytes count
      pure (Text.pack ("wasapi_supplied_frames=" ++ show count ++ " packets=" ++ show packets ++ " max_reference_error=" ++ show maxError ++ " rejected_reset_fault=" ++ show faultyError ++ " max_processing_us=" ++ show maximumTime ++ " late=" ++ show late ++ " observed_starvation=" ++ show starvation))
  where
    count = 18000
    swapAt = 3000
    specification = ImpulseReference sampleRate 17000 0.001 0.005 225 0.65 0.08
    patch = AudioPatch 0.001 0.005 17000 0 0.5 1 0.03125 0.65
    silent = AudioTrack "silent" Bass 0 0 True patch Nothing []
    sounding = AudioTrack "impulse" Sample 1 0 False patch (Just "pcm") []
    impulse = AudioPlan 400 12000 0.08 Nothing [silent,sounding] [AudioNote "impulse" "impulse" 0 1 261.6255653005986 1] [AudioSample "pcm" (PCM sampleRate 1 1 (Vector.singleton 1))]
    reordered = impulse {planTracks=reverse (planTracks impulse)}
