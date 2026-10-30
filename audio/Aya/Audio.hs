{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Aya.Audio
  ( module Aya.Audio.Types, Engine, startEngine, closeEngine, setPlan
  , sendTransport, readEngineStatus, audition, auditionKey, releaseAudition, panic
  , runAudioWorker, validateAudioPlan, decodeWave, renderWav
  , runAudioSelfTest, runAudioDeviceTest
  ) where

import Aya.Audio.Types
import Aya.Audio.Plan
import Aya.Audio.Kernel
import qualified Aya.Audio.Native as Native
import Aya.Audio.Wave
import Aya.Audio.Reference
import qualified Aya.Audio.Diagnostics as Diagnostics
import Control.Concurrent (MVar, newMVar, modifyMVar, withMVar, threadDelay, runInBoundThread)
import Control.Exception (SomeException, IOException, bracket, catch, finally, onException, displayException)
import Control.Monad (when, unless, void)
import qualified Data.ByteString as ByteString
import Data.Int
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word
import Foreign (Ptr, nullPtr, alloca, peek, plusPtr, pokeByteOff, peekByteOff, fillBytes, copyBytes, castPtr, free, mallocArray, mallocBytes, peekArray)
import Foreign.C
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing, renameFile, removeFile, doesFileExist)
import System.Environment (getExecutablePath)
import System.FilePath ((</>),takeDirectory)
import System.IO (withBinaryFile, IOMode(WriteMode))
import qualified Data.Vector.Storable as Vector

data Control = Control { acceptedTracks :: !(Set.Set Text), isClosed :: !Bool }
data Engine = Engine
  { mapping :: !(Ptr Native.Mapping)
  , shared :: !(Ptr Word8)
  , child :: !(Ptr Native.Child)
  , control :: !(MVar Control)
  }

audioFailure :: String -> AudioError
audioFailure = AudioError . Text.pack

catchAudio :: IO (Either AudioError a) -> IO (Either AudioError a)
catchAudio action = action `catch` (\(exception :: IOException) -> pure (Left (audioFailure (displayException exception))))

startEngine :: IO (Either AudioError Engine)
startEngine = catchAudio $ do
  process <- Native.processId
  clock <- Native.clockSeconds
  let name = "Local\\Aya-" ++ show process ++ "-" ++ show (floor (clock*1000000) :: Integer)
  mapHandle <- withCString name Native.mapCreate
  if mapHandle == nullPtr then pure (Left (audioFailure "Could not allocate the isolated audio mapping")) else do
    base <- Native.mapData mapHandle
    executable <- getExecutablePath
    childHandle <- ByteString.useAsCString (TextEncoding.encodeUtf8 (Text.pack executable)) $ \exe -> withCString name (Native.spawn exe)
    if childHandle == nullPtr then Native.mapClose mapHandle >> pure (Left (audioFailure "Could not start the native audio worker")) else do
      lock <- newMVar (Control Set.empty False)
      let engine = Engine mapHandle base childHandle lock
      ready <- waitReady engine 500
      case ready of
        Left failure -> closeEngine engine >> pure (Left failure)
        Right () -> pure (Right engine)

waitReady :: Engine -> Int -> IO (Either AudioError ())
waitReady engine remaining = do
  state <- Native.atomicRead32 (shared engine `plusPtr` 24)
  alive <- Native.childAlive (child engine)
  if state == 1 then pure (Right ()) else if state == maxBound || alive == 0 then do
    message <- readMessage (shared engine)
    pure (Left (AudioError (if Text.null message then "Audio worker exited before opening WASAPI" else message)))
  else if remaining <= 0 then pure (Left (audioFailure "Audio worker did not open a device within five seconds"))
  else threadDelay 10000 >> waitReady engine (remaining-1)

closeEngine :: Engine -> IO ()
closeEngine engine@Engine{mapping,shared,child,control} = modifyMVar control $ \state ->
  if isClosed state then pure (state,()) else do
    Native.atomicWrite32 (shared `plusPtr` 32) 1
    ended <- Native.childWait child 2000
    when (ended == 0) (Native.childTerminate child >> void (Native.childWait child 1000))
    Native.childClose child
    Native.mapClose mapping
    let _keepAlive = engine
    pure (state {isClosed=True},())

setPlan :: Engine -> AudioPlan -> IO (Either AudioError ())
setPlan engine source = case preparePlan source of
  Left failure -> pure (Left failure)
  Right prepared -> catchAudio $ modifyMVar (control engine) $ \state -> do
    if isClosed state then pure (state,Left (audioFailure "Audio engine is closed")) else do
      alive <- Native.childAlive (child engine)
      if alive == 0 then pure (state,Left (audioFailure "Audio process has stopped; restart the application")) else do
        published <- Native.atomicRead64 (shared engine `plusPtr` 8)
        previous <- waitAcknowledgment engine published 500
        case previous of
          Left failure -> pure (state,Left failure)
          Right () -> do
            let generation = published+1
            writePlan (Native.slotAddress (shared engine) generation) prepared
            Native.atomicWrite32 (shared engine `plusPtr` 136) 0
            Native.atomicWrite64 (shared engine `plusPtr` 8) generation
            acknowledged <- waitAcknowledgment engine generation 500
            case acknowledged of
              Left failure -> pure (state,Left failure)
              Right () -> pure (state {acceptedTracks=Set.fromList (map trackId (planTracks source))},Right ())

waitAcknowledgment :: Engine -> Word64 -> Int -> IO (Either AudioError ())
waitAcknowledgment _ 0 _ = pure (Right ())
waitAcknowledgment engine generation remaining = do
  acknowledged <- Native.atomicRead64 (shared engine `plusPtr` 16)
  alive <- Native.childAlive (child engine)
  ready <- Native.atomicRead32 (shared engine `plusPtr` 24)
  failure <- Native.atomicRead32 (shared engine `plusPtr` 136)
  if failure /= 0 then pure (Left (audioFailure "Audio process rejected the flat execution plan"))
    else if acknowledged == generation then pure (Right ())
    else if alive == 0 || ready == maxBound then Left . AudioError <$> readMessage (shared engine)
    else if remaining <= 0 then pure (Left (audioFailure "Audio plan acknowledgment timed out; the previous or pending plan may still be active"))
    else threadDelay 10000 >> waitAcknowledgment engine generation (remaining-1)

sendTransport :: Engine -> TransportCommand -> IO (Either AudioError ())
sendTransport engine command = case command of
  Play -> enqueue engine Nothing 1 0 0 0 0 0
  Pause -> enqueue engine Nothing 2 0 0 0 0 0
  Stop -> enqueue engine Nothing 3 0 0 0 0 0
  Seek frame | frame < 0 -> pure (Left (audioFailure "Seek frame must be nonnegative"))
             | otherwise -> enqueue engine Nothing 4 0 (fromIntegral frame) 0 0 0

audition :: Engine -> Text -> Double -> Double -> Double -> IO (Either AudioError ())
audition engine identity frequency velocity duration
  | not (validNumber duration) || duration <= 0 || duration > 60 = pure (Left (audioFailure "Audition duration must be finite and 0..60 seconds"))
  | otherwise = do
      clock <- Native.clockSeconds
      let eventId = stableId (Text.pack (show clock) <> identity)
      auditionCommand engine identity eventId frequency velocity (duration*fromIntegral sampleRate) 5

auditionKey :: Engine -> Text -> Text -> Double -> Double -> IO (Either AudioError ())
auditionKey engine eventIdentity identity frequency velocity
  | Text.null eventIdentity = pure (Left (audioFailure "Audition event ID must not be empty"))
  | otherwise = auditionCommand engine identity (stableId eventIdentity) frequency velocity 0 8

releaseAudition :: Engine -> Text -> IO (Either AudioError ())
releaseAudition engine eventIdentity = enqueue engine Nothing 9 0 0 0 0 (stableId eventIdentity)

panic :: Engine -> IO (Either AudioError ())
panic engine = enqueue engine Nothing 6 0 0 0 0 0

auditionCommand :: Engine -> Text -> Word64 -> Double -> Double -> Double -> Int32 -> IO (Either AudioError ())
auditionCommand engine identity eventIdentity frequency velocity duration command
  | not (validNumber frequency && validNumber velocity) || frequency < 8 || frequency > 20000 || velocity < 0 || velocity > 1 = pure (Left (audioFailure "Audition needs finite 8..20000 Hz and velocity 0..1"))
  | otherwise = enqueue engine (Just identity) command (stableId identity) frequency velocity duration eventIdentity

validNumber :: Double -> Bool
validNumber value = not (isNaN value || isInfinite value)

enqueue :: Engine -> Maybe Text -> Int32 -> Word64 -> Double -> Double -> Double -> Word64 -> IO (Either AudioError ())
enqueue Engine{shared,child,control} requiredTrack command trackIdentity first second third identity = withMVar control $ \state -> do
  alive <- if isClosed state then pure 0 else Native.childAlive child
  if alive == 0 then pure (Left (audioFailure "Audio process is unavailable"))
    else if Set.null (acceptedTracks state) then pure (Left (audioFailure "Compile a project with a track before playing"))
    else if maybe False (\track -> not (Set.member track (acceptedTracks state))) requiredTrack then pure (Left (audioFailure "Audition track is not in the accepted audio plan"))
    else do
      writeSequence <- Native.atomicRead32 (shared `plusPtr` 768)
      readSequence <- Native.atomicRead32 (shared `plusPtr` 772)
      if writeSequence-readSequence >= fromIntegral Native.commandCapacity then pure (Left (audioFailure "Audio command queue is full; release keys and retry")) else do
        let pointer = shared `plusPtr` (Native.commandBase + fromIntegral (writeSequence `mod` fromIntegral Native.commandCapacity)*Native.commandStride)
        pokeByteOff pointer 0 command; pokeByteOff pointer 8 trackIdentity
        pokeByteOff pointer 16 first; pokeByteOff pointer 24 second; pokeByteOff pointer 32 third
        pokeByteOff pointer 40 identity
        Native.atomicWrite32 (shared `plusPtr` 768) (writeSequence+1)
        pure (Right ())

readEngineStatus :: Engine -> IO EngineStatus
readEngineStatus Engine{shared,child,control} = withMVar control $ \state ->
  if isClosed state then pure emptyStatus else snapshot 10
  where
    snapshot remaining = do
      before <- Native.atomicRead32 (shared `plusPtr` 116)
      ready <- Native.atomicRead32 (shared `plusPtr` 24)
      alive <- Native.childAlive child
      playing <- peekByteOff shared 44 :: IO Int32
      frame <- peekByteOff shared 48
      rate <- peekByteOff shared 36 :: IO Int32
      buffer <- peekByteOff shared 40 :: IO Int32
      peakL <- peekByteOff shared 56 :: IO Float
      peakR <- peekByteOff shared 60 :: IO Float
      underruns <- peekByteOff shared 64
      late <- peekByteOff shared 72
      processed <- peekByteOff shared 80
      maximumTime <- peekByteOff shared 88
      overflows <- peekByteOff shared 120
      clipped <- peekByteOff shared 128
      heartbeat <- peekByteOff shared 104 :: IO Double
      message <- readMessage shared
      now <- Native.clockSeconds
      after <- Native.atomicRead32 (shared `plusPtr` 116)
      if (before /= after || odd before) && remaining > (0 :: Int) then snapshot (remaining-1) else
        pure (EngineStatus (ready == 1 && alive /= 0 && now-heartbeat < 2) (playing /= 0) frame (fromIntegral rate) (fromIntegral buffer) (realToFrac peakL) (realToFrac peakR) underruns late processed maximumTime overflows clipped message)

emptyStatus :: EngineStatus
emptyStatus = EngineStatus False False 0 sampleRate 0 0 0 0 0 0 0 0 0 "Audio engine is closed"

readMessage :: Ptr Word8 -> IO Text
readMessage shared = Text.pack <$> peekCString (castPtr (shared `plusPtr` 256))

writeMessage :: Ptr Word8 -> String -> IO ()
writeMessage shared message = do
  fillBytes (shared `plusPtr` 256) 0 512
  withCStringLen (take 500 message) $ \(bytes,count) -> copyBytes (shared `plusPtr` 256) bytes count

runAudioWorker :: String -> IO ()
runAudioWorker name = runInBoundThread $ withCString name Native.mapOpen >>= \mapHandle ->
  when (mapHandle /= nullPtr) $ finally (worker mapHandle) (Native.mapClose mapHandle)
  where
    worker mapHandle = do
      base <- Native.mapData mapHandle
      let failWorker message = do
            writeMessage base message
            Native.atomicWrite32 (base `plusPtr` 24) maxBound
      (withRuntime $ \runtime -> alloca $ \errorPointer -> do
        device <- Native.deviceOpen errorPointer
        if device == nullPtr then do
          failure <- peek errorPointer
          failWorker ("WASAPI could not open the default output (HRESULT 0x" ++ showHex (fromIntegral failure :: Word32) "")
        else finally (runDevice mapHandle base runtime device) (Native.deviceClose device))
        `catch` (\(exception :: SomeException) -> failWorker ("Audio process: " ++ displayException exception))

runDevice :: Ptr Native.Mapping -> Ptr Word8 -> Runtime -> Ptr Native.Device -> IO ()
runDevice mapHandle base runtime device = do
  frames <- Native.deviceFrames device
  pokeByteOff base 36 (fromIntegral sampleRate :: Int32)
  pokeByteOff base 40 (fromIntegral frames :: Int32)
  writeMessage base "WASAPI shared/event; native GHC DSP; 48 kHz stereo"
  initial <- Native.deviceBegin device
  when (initial > 0) $ do
    output <- Native.deviceBuffer device
    fillBytes output 0 (fromIntegral initial*8)
    void (Native.deviceEnd device)
  started <- Native.deviceStart device
  if started < 0 then failDevice started else do
    Native.clockSeconds >>= pokeByteOff base 104
    Native.atomicWrite32 (base `plusPtr` 24) 1
    loop 0 nullPtr 0 0 0
  where
    failDevice :: Int32 -> IO ()
    failDevice code = do
      writeMessage base ("WASAPI device error (HRESULT 0x" ++ showHex (fromIntegral code :: Word32) "); restart audio after restoring the output device")
      Native.atomicWrite32 (base `plusPtr` 24) maxBound
    loop !generation !plan !processed !late !maximumTime = do
      shutdown <- Native.atomicRead32 (base `plusPtr` 32)
      alive <- Native.parentAlive mapHandle
      unless (shutdown /= 0 || alive == 0) $ do
        signaled <- Native.deviceWait device 100
        if signaled < 0 then failDevice (-1) else do
          start <- Native.clockSeconds
          published <- Native.atomicRead64 (base `plusPtr` 8)
          (nextGeneration,nextPlan) <- if published == generation || published == 0 then pure (generation,plan) else do
            let candidate = Native.slotAddress base published
            valid <- checkFlatPlan candidate
            if not valid then Native.atomicWrite32 (base `plusPtr` 136) 1 >> pure (generation,plan) else do
              installPlan runtime candidate
              Native.atomicWrite64 (base `plusPtr` 16) published
              pure (published,candidate)
          when (nextPlan /= nullPtr) (drainCommands base runtime nextPlan)
          count <- Native.deviceBegin device
          if count < 0 then Native.deviceError device >>= failDevice else do
            when (count > 0) $ do
              output <- Native.deviceBuffer device
              if nextPlan == nullPtr then fillBytes output 0 (fromIntegral count*8)
                else processBlock runtime nextPlan output (fromIntegral count)
            ended <- if count > 0 then Native.deviceEnd device else pure 0
            finish <- Native.clockSeconds
            let duration = (finish-start)*1000000
                newLate = late + if count > 0 && duration > fromIntegral count/fromIntegral sampleRate*1000000 then 1 else 0
                newMaximum = max maximumTime duration
                newProcessed = processed + if count > 0 then 1 else 0
            publishStatus base runtime device newProcessed newLate newMaximum duration finish
            if ended < 0 then failDevice ended else loop nextGeneration nextPlan newProcessed newLate newMaximum

drainCommands :: Ptr Word8 -> Runtime -> Ptr Word8 -> IO ()
drainCommands base runtime plan = do
  readSequence <- Native.atomicRead32 (base `plusPtr` 772)
  writeSequence <- Native.atomicRead32 (base `plusPtr` 768)
  let consume !sequenceNumber
        | sequenceNumber == writeSequence = pure ()
        | otherwise = do
            let pointer = base `plusPtr` (Native.commandBase + fromIntegral (sequenceNumber `mod` fromIntegral Native.commandCapacity)*Native.commandStride)
            command <- peekByteOff pointer 0; trackIdentity <- peekByteOff pointer 8
            first <- peekByteOff pointer 16; second <- peekByteOff pointer 24; third <- peekByteOff pointer 32
            identity <- peekByteOff pointer 40
            applyCommand runtime plan command trackIdentity first second third identity
            Native.atomicWrite32 (base `plusPtr` 772) (sequenceNumber+1)
            consume (sequenceNumber+1)
  consume readSequence

publishStatus :: Ptr Word8 -> Runtime -> Ptr Native.Device -> Int64 -> Int64 -> Double -> Double -> Double -> IO ()
publishStatus base runtime device processed late maximumTime duration now = do
  sequenceNumber <- Native.atomicRead32 (base `plusPtr` 116)
  Native.atomicWrite32 (base `plusPtr` 116) (sequenceNumber+1)
  playing <- runtimePlaying runtime; frame <- runtimePosition runtime
  (left,right) <- runtimePeaks runtime
  underruns <- Native.deviceStarvation device
  overflows <- runtimeOverflows runtime; clipped <- runtimeClips runtime
  pokeByteOff base 44 (if playing then 1 else 0 :: Int32)
  pokeByteOff base 48 frame
  pokeByteOff base 56 (realToFrac left :: Float); pokeByteOff base 60 (realToFrac right :: Float)
  pokeByteOff base 64 (fromIntegral underruns :: Int64); pokeByteOff base 72 late
  pokeByteOff base 80 processed; pokeByteOff base 88 maximumTime
  pokeByteOff base 96 duration; pokeByteOff base 104 now
  pokeByteOff base 120 overflows; pokeByteOff base 128 clipped
  Native.atomicWrite32 (base `plusPtr` 116) (sequenceNumber+2)

renderWav :: FilePath -> AudioPlan -> Maybe Text -> IO (Either AudioError RenderReport)
renderWav outputPath original stem = catchAudio $ do
  let source = original { planLoop=Nothing, planTracks=map selectTrack (planTracks original) }
      selectTrack track = track {trackMuted=trackMuted track || maybe False (/= trackId track) stem}
      total = planLengthFrames source + planTailFrames source
  case preparePlan source of
    Left failure -> pure (Left failure)
    Right prepared
      | maybe False (\identity -> all ((/=identity) . trackId) (planTracks original)) stem -> pure (Left (audioFailure "Stem track does not exist"))
      | total*6+36 > 4294967295 -> pure (Left (audioFailure "WAV exceeds the RIFF 4 GiB limit; export a shorter region"))
      | otherwise -> do
          createDirectoryIfMissing True (takeDirectory outputPath)
          let temporary = outputPath ++ ".partial"
          report <- (withRuntime $ \runtime -> bracket (mallocBytes (preparedBytes prepared)) free $ \plan -> do
            writePlan plan prepared
            installPlan runtime plan
            applyCommand runtime plan 1 0 0 0 0 0
            bracket (mallocArray (4096*2)) free $ \buffer -> bracket (mallocBytes (4096*6)) free $ \bytes ->
              withBinaryFile temporary WriteMode $ \handle -> do
                writeWaveHeader handle total
                let blocks !remaining !peak
                      | remaining <= 0 = do
                          clipped <- runtimeClips runtime
                          pure (RenderReport outputPath total (fromIntegral total/fromIntegral sampleRate) peak clipped)
                      | otherwise = do
                          let count = fromIntegral (min remaining 4096)
                          processBlock runtime plan buffer count
                          (left,right) <- runtimePeaks runtime
                          writePCM24Block handle buffer bytes count
                          blocks (remaining-fromIntegral count) (max peak (max left right))
                blocks total 0) `onException` removeIfExists temporary
          renameFile temporary outputPath
          pure (Right report)

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
  exists <- doesFileExist path
  when exists (removeFile path)

-- The diagnostics use the production plan encoder, migration and DSP and compare
-- against the independent direct-form/FIFO reference before touching a device.
runAudioSelfTest :: FilePath -> IO (Either AudioError Text)
runAudioSelfTest directory = catchAudio $ do
  createDirectoryIfMissing True directory
  stateChecks <- Diagnostics.kernelChecks
  let count = 18000
      swapAt = 3000
      source = impulsePlan
      specification = ImpulseReference sampleRate 17000 0.001 0.005 225 0.65 0.08
      reference = referenceImpulse specification count
      damaged = referenceWithDelayReset specification swapAt count
  result <- withRuntime $ \runtime -> bracket (mallocBytes Native.slotBytes) free $ \first -> bracket (mallocBytes Native.slotBytes) free $ \second -> bracket (mallocArray (count*2)) free $ \buffer -> do
    case (preparePlan source,preparePlan (source {planTracks=reverse (planTracks source)})) of
      (Right firstPlan,Right secondPlan) -> do
        writePlan first firstPlan; writePlan second secondPlan
        installPlan runtime first; applyCommand runtime first 1 0 0 0 0 0
        processBlock runtime first buffer swapAt
        installPlan runtime second
        processBlock runtime second (buffer `plusPtr` (swapAt*8)) (count-swapAt)
        samples <- peekArray (count*2) buffer
        let expected = concatMap (\(left,right) -> [left,right]) reference
            faulty = concatMap (\(left,right) -> [left,right]) damaged
            errorMaximum = foldl' max 0 (zipWith (\a b -> abs (realToFrac a-realToFrac b :: Double)) samples expected)
            rejectedError = foldl' max 0 (zipWith (\a b -> abs (realToFrac a-realToFrac b :: Double)) samples faulty)
        pure (Right (errorMaximum,rejectedError))
      (Left failure,_) -> pure (Left failure)
      (_,Left failure) -> pure (Left failure)
  case result of
    Left failure -> pure (Left failure)
    Right (maximumError,damagedError)
      | maximumError > 2e-7 || damagedError < 1e-7 -> pure (Left (audioFailure ("Independent sample/state comparison failed: " ++ show (maximumError,damagedError))))
      | otherwise -> do
          rendered <- renderWav (directory </> "haskell-dsp-impulse.wav") source Nothing
          pure $ case rendered of
            Left failure -> Left failure
            Right report -> Right (stateChecks <> "\n" <> Text.pack ("independent_reference_max_error=" ++ show maximumError ++ "\nreset_fault_error=" ++ show damagedError ++ "\n" ++ show report))

runAudioDeviceTest :: FilePath -> IO (Either AudioError Text)
runAudioDeviceTest directory = catchAudio $ do
  createDirectoryIfMissing True directory
  Right <$> Diagnostics.deviceReferenceProbe directory

impulsePlan :: AudioPlan
impulsePlan = AudioPlan 400 12000 0.08 Nothing [silentTrack,impulseTrack] [AudioNote "impulse-note" "impulse" 0 1 261.6255653005986 1] [AudioSample "impulse-pcm" (PCM sampleRate 1 1 (Vector.singleton 1))]
  where
    patch = AudioPatch 0.001 0.005 17000 0 0.5 1 0.03125 0.65
    silentTrack = AudioTrack "silent" Bass 0 0 True patch Nothing []
    impulseTrack = AudioTrack "impulse" Sample 1 0 False patch (Just "impulse-pcm") []
