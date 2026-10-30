{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE NamedFieldPuns #-}
module Aya.Audio.Kernel
  ( Runtime, withRuntime, installPlan, applyCommand, processBlock
  , runtimePosition, runtimePlaying, runtimePeaks, runtimeOverflows, runtimeClips
  , resetRuntime
  , VoiceSnapshot(..), voiceSnapshot
  ) where

import Aya.Audio.Layout
import Aya.Audio.Plan
import Aya.Audio.Types (Frame, sampleRate)
import Control.Exception (bracket)
import Control.Monad (when)
import Data.Bits
import Data.Int
import Data.Word
import Foreign (Ptr, mallocBytes, callocBytes, mallocArray, free, plusPtr, castPtr, fillBytes, peekByteOff, pokeByteOff, peekElemOff, pokeElemOff)

data Runtime = Runtime
  { transport :: !(Ptr Word8)
  , voices :: !(Ptr Word8)
  , tracks :: !(Ptr Word8)
  , delays :: !(Ptr Float)
  , trackSlots :: !(Ptr Int32)
  , sineTable :: !(Ptr Double)
  }

sineSize :: Int
sineSize = 8192

withRuntime :: (Runtime -> IO a) -> IO a
withRuntime action =
  bracket (callocBytes 128) free $ \transport ->
  bracket (callocBytes (maxVoices*voiceBytes)) free $ \voices ->
  bracket (callocBytes (maxTracks*stateBytes)) free $ \tracks ->
  bracket (mallocBytes delayBytes) free $ \delays ->
  bracket (callocBytes (maxTracks*4)) free $ \trackSlots ->
  bracket (mallocArray (sineSize+1)) free $ \sineTable -> do
    fillBytes delays 0 delayBytes
    let initialize !index | index > sineSize = pure ()
                          | otherwise = pokeElemOff sineTable index (sin (2*pi*fromIntegral index/fromIntegral sineSize)) >> initialize (index+1)
    initialize 0
    action Runtime{transport,voices,tracks,delays,trackSlots,sineTable}
  where delayBytes = maxTracks*delayCapacity*2*4

readD :: Ptr Word8 -> Int -> IO Double
readD = peekByteOff
{-# INLINE readD #-}
writeD :: Ptr Word8 -> Int -> Double -> IO ()
writeD = pokeByteOff
{-# INLINE writeD #-}
readI :: Ptr Word8 -> Int -> IO Int32
readI = peekByteOff
{-# INLINE readI #-}
writeI :: Ptr Word8 -> Int -> Int32 -> IO ()
writeI = pokeByteOff
{-# INLINE writeI #-}
readF :: Ptr Word8 -> Int -> IO Int64
readF = peekByteOff
{-# INLINE readF #-}
writeF :: Ptr Word8 -> Int -> Int64 -> IO ()
writeF = pokeByteOff
{-# INLINE writeF #-}
readId :: Ptr Word8 -> Int -> IO Word64
readId = peekByteOff
{-# INLINE readId #-}
writeId :: Ptr Word8 -> Int -> Word64 -> IO ()
writeId = pokeByteOff
{-# INLINE writeId #-}

voiceAt :: Runtime -> Int -> Ptr Word8
voiceAt Runtime{voices} index = voices `plusPtr` (index*voiceBytes)
{-# INLINE voiceAt #-}
trackState :: Runtime -> Int -> Ptr Word8
trackState Runtime{tracks} index = tracks `plusPtr` (index*stateBytes)
{-# INLINE trackState #-}

runtimePosition :: Runtime -> IO Frame
runtimePosition Runtime{transport} = readF transport transportFrame
runtimePlaying :: Runtime -> IO Bool
runtimePlaying Runtime{transport} = (==1) <$> readI transport transportMode
runtimePeaks :: Runtime -> IO (Double,Double)
runtimePeaks Runtime{transport} = (,) <$> readD transport transportPeakL <*> readD transport transportPeakR
runtimeOverflows :: Runtime -> IO Int64
runtimeOverflows Runtime{transport} = readF transport transportOverflows
runtimeClips :: Runtime -> IO Int64
runtimeClips Runtime{transport} = readF transport transportClips

data VoiceSnapshot = VoiceSnapshot
  { snapshotAge :: !Frame
  , snapshotGate :: !Frame
  , snapshotPhase :: !Double
  , snapshotFrequency :: !Double
  , snapshotReleaseAge :: !Frame
  , snapshotEnvelope :: !Double
  , snapshotSamplePosition :: !Double
  } deriving (Eq,Show)

voiceSnapshot :: Runtime -> Word64 -> IO (Maybe VoiceSnapshot)
voiceSnapshot runtime identity = find 0
  where
    find !index
      | index >= maxVoices = pure Nothing
      | otherwise = do
          let voice = voiceAt runtime index
          active <- readI voice voiceActive
          found <- readId voice voiceId
          if active /= 0 && found == identity then
            Just <$> (VoiceSnapshot <$> readF voice voiceAge <*> readF voice voiceGateFrames <*>
              readD voice voicePhase <*> readD voice voiceFrequency <*> readF voice voiceReleaseAge <*> readD voice voiceEnvelopeLevel <*> readD voice voiceSamplePosition)
            else find (index+1)

resetRuntime :: Runtime -> IO ()
resetRuntime runtime@Runtime{transport} = do
  beginTransition transport
  fillBytes (voices runtime) 0 (maxVoices*voiceBytes)
  let clearTrack !index
        | index >= maxTracks = pure ()
        | otherwise = do
            let state = trackState runtime index
            writeI state stateDelayWrite 0; writeI state stateDelayAge 0
            writeD state stateMixL 0; writeD state stateMixR 0
            clearTrack (index+1)
  clearTrack 0

beginTransition :: Ptr Word8 -> IO ()
beginTransition transport = do
  readD transport transportLastL >>= writeD transport transportTransitionL
  readD transport transportLastR >>= writeD transport transportTransitionR
  writeD transport transportFade 0
{-# INLINE beginTransition #-}

installPlan :: Runtime -> Ptr Word8 -> IO ()
installPlan runtime@Runtime{trackSlots,transport} plan = do
  count <- readI plan flatTrackCount
  position <- readF transport transportFrame
  let markInactive !slot
        | slot >= maxTracks = pure ()
        | otherwise = writeI (trackState runtime slot) stateActive 0 >> markInactive (slot+1)
      findExisting !identity !slot
        | slot >= maxTracks = pure (-1)
        | otherwise = do
            found <- readId (trackState runtime slot) stateTrackId
            if found == identity then pure slot else findExisting identity (slot+1)
      findVacant !slot
        | slot >= maxTracks = pure (-1)
        | otherwise = do
            active <- readI (trackState runtime slot) stateActive
            identity <- readId (trackState runtime slot) stateTrackId
            retained <- if identity == 0 then pure False else trackPresent identity 0
            if active == 0 && not retained then pure slot else findVacant (slot+1)
      trackPresent !identity !index
        | index >= fromIntegral count = pure False
        | otherwise = do
            found <- readId (trackAt plan index) flatTrackId
            if found == identity then pure True else trackPresent identity (index+1)
      assign !index
        | index >= fromIntegral count = pure ()
        | otherwise = do
            let track = trackAt plan index
            identity <- readId track flatTrackId
            existing <- findExisting identity 0
            slot <- if existing >= 0 then pure existing else findVacant 0
            when (slot >= 0) $ do
              let state = trackState runtime slot
              when (existing < 0) $ do
                fillBytes state 0 stateBytes
                writeId state stateTrackId identity
                gain <- readD track flatGain; pan <- readD track flatPan; cutoff <- readD track flatCutoff
                muted <- readI track flatMuted
                writeD state stateGain (if muted /= 0 then 0 else gain)
                writeD state statePan pan; writeD state stateCutoff cutoff
                let g = tan (pi*cutoff/fromIntegral sampleRate)
                writeD state stateFilterG g
                writeD state stateTargetFilterG g
                writeD state stateTargetGain (if muted /= 0 then 0 else gain)
                writeD state stateTargetPan pan
                resonance <- readD track flatResonance
                writeD state stateFilterDamping (2-1.9*resonance)
                delayFrames <- readI track flatDelayFrames
                writeD state stateDelayFrames (fromIntegral delayFrames)
              writeI state statePlanIndex (fromIntegral index); writeI state stateActive 1
              pokeElemOff trackSlots index (fromIntegral slot)
            assign (index+1)
      migrateVoice !index
        | index >= maxVoices = pure ()
        | otherwise = do
            let voice = voiceAt runtime index
            active <- readI voice voiceActive
            when (active /= 0) $ do
              slot <- readI voice voiceTrackSlot
              retained <- readI (trackState runtime (fromIntegral slot)) stateActive
              if retained == 0 then writeI voice voiceActive 0 else do
                kind <- readI voice voiceOrigin
                when (kind == 0) $ do
                  identity <- readId voice voiceId
                  noteIndex <- lookupNote plan identity
                  if noteIndex < 0 then forceRelease voice else do
                    note <- noteAt plan noteIndex
                    start <- readF note flatNoteStart; end <- readF note flatNoteEnd
                    age <- readF voice voiceAge
                    newTrack <- readI note flatNoteTrack
                    newSlot <- peekElemOff trackSlots (fromIntegral newTrack)
                    writeI voice voiceTrackSlot newSlot
                    readId (trackAt plan (fromIntegral newTrack)) flatTrackId >>= writeId voice voiceTrackId
                    if start <= position && position < end
                      then writeF voice voiceGateFrames (age+end-position)
                      else forceRelease voice
                    readD note flatNoteFrequency >>= writeD voice voiceTargetFrequency
                    readD note flatNoteVelocity >>= writeD voice voiceVelocity
            migrateVoice (index+1)
      retireTracks !slot !retired
        | slot >= maxTracks = pure retired
        | otherwise = do
            let state = trackState runtime slot
            active <- readI state stateActive
            identity <- readId state stateTrackId
            if active == 0 && identity /= 0
              then writeId state stateTrackId 0 >> retireTracks (slot+1) True
              else retireTracks (slot+1) retired
  markInactive 0
  assign 0
  migrateVoice 0
  retired <- retireTracks 0 False
  when retired (beginTransition transport)
  next <- lowerBoundNote plan position
  writeI transport transportNextNote (fromIntegral next)
  mode <- readI transport transportMode
  when (mode == 1) (chaseNotes runtime plan position)

lowerBoundNote :: Ptr Word8 -> Frame -> IO Int
lowerBoundNote plan frame = do
  count <- readI plan flatNoteCount
  let search !lo !hi
        | lo >= hi = pure lo
        | otherwise = do
            let middle = (lo+hi) `quot` 2
            pointer <- noteAt plan middle
            start <- readF pointer flatNoteStart
            if start < frame then search (middle+1) hi else search lo middle
  search 0 (fromIntegral count)

forceRelease :: Ptr Word8 -> IO ()
forceRelease voice = do
  released <- readF voice voiceReleaseAge
  when (released < 0) $ do
    readD voice voiceEnvelopeLevel >>= writeD voice voiceReleaseLevel
    writeF voice voiceReleaseAge 0

applyCommand :: Runtime -> Ptr Word8 -> Int32 -> Word64 -> Double -> Double -> Double -> Word64 -> IO ()
applyCommand runtime@Runtime{transport} plan command trackIdentity first second third identity = case command of
  1 -> do
    lengthFrames <- readF plan flatLength
    frame <- readF transport transportFrame
    when (frame >= lengthFrames) (writeF transport transportFrame 0 >> resetRuntime runtime)
    writeI transport transportMode 1
    position <- readF transport transportFrame
    lowerBoundNote plan position >>= writeI transport transportNextNote . fromIntegral
    chaseNotes runtime plan position
  2 -> writeI transport transportMode 0 >> resetRuntime runtime
  3 -> do
    writeI transport transportMode 0; writeF transport transportFrame 0; writeI transport transportNextNote 0
    resetRuntime runtime
  4 -> do
    lengthFrames <- readF plan flatLength
    let frame = max 0 (min lengthFrames (round first))
    resetRuntime runtime
    writeF transport transportFrame frame
    lowerBoundNote plan frame >>= writeI transport transportNextNote . fromIntegral
    mode <- readI transport transportMode
    when (mode == 1) (chaseNotes runtime plan frame)
  5 -> addAudition runtime plan trackIdentity identity first second (max 1 (round third))
  6 -> resetRuntime runtime
  8 -> addAudition runtime plan trackIdentity identity first second maxBound
  9 -> releaseKey 0
  _ -> pure ()
  where
    releaseKey !index
      | index >= maxVoices = pure ()
      | otherwise = do
          let voice = voiceAt runtime index
          found <- readId voice voiceId
          kind <- readI voice voiceOrigin
          when (found == identity && kind == 1) (forceRelease voice)
          releaseKey (index+1)

addAudition :: Runtime -> Ptr Word8 -> Word64 -> Word64 -> Double -> Double -> Frame -> IO ()
addAudition runtime plan identity eventIdentity frequency velocity duration = do
  count <- readI plan flatTrackCount
  let findTrack !index
        | index >= fromIntegral count = pure ()
        | otherwise = do
            found <- readId (trackAt plan index) flatTrackId
            if found == identity then do
              slot <- peekElemOff (trackSlots runtime) index
              startVoice runtime eventIdentity (fromIntegral slot) 1 duration 0 frequency velocity
            else findTrack (index+1)
  findTrack 0

chaseNotes :: Runtime -> Ptr Word8 -> Frame -> IO ()
chaseNotes runtime plan frame = do
  offset <- readF plan flatIntervalsOffset
  count <- readI plan flatNoteCount
  let tree = castPtr (plan `plusPtr` fromIntegral offset) :: Ptr Int64
      visit !node !start !width = do
        latestEnd <- peekElemOff tree node
        when (latestEnd > frame && start < fromIntegral count) $
          if width == 1 then do
            note <- noteAt plan start
            onset <- readF note flatNoteStart
            when (onset < frame) (triggerNote runtime plan note (frame-onset))
          else do
            let half = width `quot` 2
            visit (node*2) start half
            middle <- noteAt plan (min (fromIntegral count-1) (start+half))
            middleStart <- readF middle flatNoteStart
            when (middleStart <= frame) (visit (node*2+1) (start+half) half)
  when (count > 0) (visit 1 0 32768)

triggerNote :: Runtime -> Ptr Word8 -> Ptr Word8 -> Frame -> IO ()
triggerNote runtime _plan note age = do
  identity <- readId note flatNoteId
  trackIndex <- readI note flatNoteTrack
  slot <- peekElemOff (trackSlots runtime) (fromIntegral trackIndex)
  start <- readF note flatNoteStart; end <- readF note flatNoteEnd
  frequency <- readD note flatNoteFrequency; velocity <- readD note flatNoteVelocity
  when (velocity > 0) (startVoice runtime identity (fromIntegral slot) 0 (end-start) age frequency velocity)

startVoice :: Runtime -> Word64 -> Int -> Int32 -> Frame -> Frame -> Double -> Double -> IO ()
startVoice runtime@Runtime{transport} identity slot kind duration age frequency velocity = find 0 (-1)
  where
    find !index !vacant
      | index >= maxVoices = if vacant < 0 then do
          overflows <- readF transport transportOverflows
          writeF transport transportOverflows (overflows+1)
        else initialize vacant
      | otherwise = do
          let voice = voiceAt runtime index
          active <- readI voice voiceActive
          found <- readId voice voiceId
          origin <- readI voice voiceOrigin
          if active /= 0 && found == identity && kind == origin then do
            releasing <- readF voice voiceReleaseAge
            existingAge <- readF voice voiceAge
            existingGate <- readF voice voiceGateFrames
            when (releasing >= 0 || existingAge >= existingGate) (initialize index)
          else find (index+1) (if active == 0 && vacant < 0 then index else vacant)
    initialize index = do
      let voice = voiceAt runtime index
      fillBytes voice 0 voiceBytes
      writeId voice voiceId identity
      readId (trackState runtime slot) stateTrackId >>= writeId voice voiceTrackId
      writeI voice voiceActive 1; writeI voice voiceTrackSlot (fromIntegral slot); writeI voice voiceOrigin kind
      writeF voice voiceGateFrames duration; writeF voice voiceAge age
      writeD voice voiceFrequency frequency; writeD voice voiceTargetFrequency frequency
      writeD voice voiceVelocity velocity
      let mixedSeed = identity `xor` 0x9e3779b97f4a7c15
      writeId voice voiceNoiseSeed (if mixedSeed == 0 then 1 else mixedSeed)
      writeF voice voiceReleaseAge (-1)
      writeD voice voiceSamplePosition (fromIntegral age)
      let phase = wrapPhase (fromIntegral age*frequency/fromIntegral sampleRate)
      writeD voice voicePhase phase; writeD voice voiceSecondPhase (wrapPhase (phase*1.003)); writeD voice voiceThirdPhase (wrapPhase (phase*0.997))

processBlock :: Runtime -> Ptr Word8 -> Ptr Float -> Int -> IO ()
processBlock runtime@Runtime{transport} plan output frameCount = do
  writeD transport transportPeakL 0; writeD transport transportPeakR 0
  let frames !index
        | index >= frameCount = pure ()
        | otherwise = do
            frame <- prepareFrame runtime plan
            controlTick <- readI transport transportControlTick
            when ((controlTick .&. 31) == 0) (updateControls runtime plan frame)
            renderVoices runtime plan 0
            (left,right) <- mixTracks runtime plan 0 0 0
            master <- readD plan flatMaster
            ramp <- readD transport transportFade
            let nextRamp = min 1 (ramp + 1/128)
            transitionLeft <- readD transport transportTransitionL
            transitionRight <- readD transport transportTransitionR
            let rawLeft = left*master*nextRamp+transitionLeft*(1-nextRamp)
                rawRight = right*master*nextRamp+transitionRight*(1-nextRamp)
                safeLeft = finiteClip rawLeft
                safeRight = finiteClip rawRight
            pokeElemOff output (index*2) (realToFrac safeLeft)
            pokeElemOff output (index*2+1) (realToFrac safeRight)
            writeD transport transportLastL safeLeft
            writeD transport transportLastR safeRight
            peakLeft <- readD transport transportPeakL; peakRight <- readD transport transportPeakR
            writeD transport transportPeakL (max peakLeft (abs rawLeft)); writeD transport transportPeakR (max peakRight (abs rawRight))
            when (abs rawLeft > 1 || abs rawRight > 1) $ do
              clipped <- readF transport transportClips
              let clippedChannels = (if abs rawLeft > 1 then 1 else 0) + (if abs rawRight > 1 then 1 else 0)
              writeF transport transportClips (clipped+clippedChannels)
            writeD transport transportFade nextRamp
            writeI transport transportControlTick (controlTick+1)
            mode <- readI transport transportMode
            when (mode == 1) (writeF transport transportFrame (frame+1))
            frames (index+1)
  frames 0
{-# NOINLINE processBlock #-}

prepareFrame :: Runtime -> Ptr Word8 -> IO Frame
prepareFrame runtime@Runtime{transport} plan = do
  mode <- readI transport transportMode
  frame <- readF transport transportFrame
  if mode /= 1 then pure frame else do
    loopStart <- readF plan flatLoopStart; loopEnd <- readF plan flatLoopEnd
    lengthFrames <- readF plan flatLength
    position <- if loopStart >= 0 && frame >= loopEnd then do
                  resetRuntime runtime
                  writeF transport transportFrame loopStart
                  lowerBoundNote plan loopStart >>= writeI transport transportNextNote . fromIntegral
                  chaseNotes runtime plan loopStart
                  pure loopStart
                else pure frame
    if position >= lengthFrames then writeI transport transportMode 2 >> pure lengthFrames else do
      count <- readI plan flatNoteCount
      next <- readI transport transportNextNote
      let trigger !index
            | index >= fromIntegral count = pure index
            | otherwise = do
                note <- noteAt plan index
                onset <- readF note flatNoteStart
                if onset <= position then triggerNote runtime plan note (position-onset) >> trigger (index+1)
                  else pure index
      after <- trigger (fromIntegral next)
      writeI transport transportNextNote (fromIntegral after)
      pure position
{-# INLINE prepareFrame #-}

updateControls :: Runtime -> Ptr Word8 -> Frame -> IO ()
updateControls runtime plan frame = walk 0
  where
    walk !slot
      | slot >= maxTracks = pure ()
      | otherwise = do
          let state = trackState runtime slot
          active <- readI state stateActive
          when (active /= 0) $ do
            index <- readI state statePlanIndex
            let track = trackAt plan (fromIntegral index)
            gain <- readD track flatGain; pan <- readD track flatPan; cutoff <- readD track flatCutoff
            !targetGain <- automationValue plan track 0 frame gain
            !targetPan <- automationValue plan track 1 frame pan
            !targetCutoff <- automationValue plan track 2 frame cutoff
            muted <- readI track flatMuted
            writeD state stateTargetGain (if muted /= 0 then 0 else targetGain)
            writeD state stateTargetPan targetPan
            writeD state stateTargetFilterG (tan (pi*targetCutoff/fromIntegral sampleRate))
            resonance <- readD track flatResonance
            writeD state stateFilterDamping (2-1.9*resonance)
          walk (slot+1)

{-# INLINE updateControls #-}

renderVoices :: Runtime -> Ptr Word8 -> Int -> IO ()
renderVoices runtime plan = walk
  where
    walk !index
      | index >= maxVoices = pure ()
      | otherwise = do
          let voice = voiceAt runtime index
          active <- readI voice voiceActive
          when (active /= 0) (renderVoice runtime plan voice)
          walk (index+1)
{-# INLINE renderVoices #-}

renderVoice :: Runtime -> Ptr Word8 -> Ptr Word8 -> IO ()
renderVoice runtime plan voice = do
  slot <- readI voice voiceTrackSlot
  let state = trackState runtime (fromIntegral slot)
  trackIndex <- readI state statePlanIndex
  let track = trackAt plan (fromIntegral trackIndex)
  age <- readF voice voiceAge; duration <- readF voice voiceGateFrames
  forcedRelease <- readF voice voiceReleaseAge
  frozenLevel <- readD voice voiceReleaseLevel
  releaseSeconds <- readD track flatRelease; attackSeconds <- readD track flatAttack
  let attackFrames = attackSeconds*fromIntegral sampleRate
      releaseFrames = releaseSeconds*fromIntegral sampleRate
      naturalReleaseAge = max 0 (age-duration)
      releaseAge = if forcedRelease >= 0 then forcedRelease else naturalReleaseAge
      heldLevel = min 1 (fromIntegral (min (age+1) duration)/attackFrames)
      releaseLevel = if forcedRelease >= 0 then frozenLevel else heldLevel
      envelope = releaseLevel * max 0 (1-fromIntegral releaseAge/releaseFrames)
  if (age >= duration || forcedRelease >= 0) && fromIntegral releaseAge >= releaseFrames then writeI voice voiceActive 0 else do
    frequency <- readD voice voiceFrequency; targetFrequency <- readD voice voiceTargetFrequency
    velocity <- readD voice voiceVelocity
    tone <- readD track flatTone
    instrument <- readI track flatInstrument
    let nextFrequency = frequency + 0.003*(targetFrequency-frequency)
    (sourceLeft,sourceRight) <- instrumentSample runtime plan track voice instrument age nextFrequency tone
    g <- readD state stateFilterG; damping <- readD state stateFilterDamping
    filteredLeft <- filterSample voice voiceFilterLowL voiceFilterBandL g damping (sourceLeft*envelope*velocity)
    filteredRight <- filterSample voice voiceFilterLowR voiceFilterBandR g damping (sourceRight*envelope*velocity)
    left <- readD state stateMixL; right <- readD state stateMixR
    writeD state stateMixL (left+filteredLeft); writeD state stateMixR (right+filteredRight)
    writeD voice voiceFrequency nextFrequency; writeF voice voiceAge (age+1)
    writeD voice voiceEnvelopeLevel envelope
    when (forcedRelease >= 0) (writeF voice voiceReleaseAge (forcedRelease+1))
{-# INLINE renderVoice #-}

filterSample :: Ptr Word8 -> Int -> Int -> Double -> Double -> Double -> IO Double
filterSample voice lowOffset bandOffset g damping input = do
  previousLow <- readD voice lowOffset; previousBand <- readD voice bandOffset
  let band = (previousBand + g*(input-previousLow)) / (1+g*(g+damping))
      low = previousLow + g*band
  writeD voice bandOffset (2*band-previousBand)
  writeD voice lowOffset (2*low-previousLow)
  pure low
{-# INLINE filterSample #-}

instrumentSample :: Runtime -> Ptr Word8 -> Ptr Word8 -> Ptr Word8 -> Int32 -> Frame -> Double -> Double -> IO (Double,Double)
instrumentSample runtime plan track voice instrument age frequency tone = do
  phase <- readD voice voicePhase; phase2 <- readD voice voiceSecondPhase; phase3 <- readD voice voiceThirdPhase
  let seconds = fromIntegral age/fromIntegral sampleRate
      dt = min 0.45 (frequency/fromIntegral sampleRate)
      saw = 2*phase-1-polyBlep phase dt
      square = (if phase < 0.5 then 1 else -1) + polyBlep phase dt - polyBlep (wrapPhase (phase+0.5)) dt
      decay rate = exp (negate (seconds*rate))
      advance first second third = do
        writeD voice voicePhase (wrapPhase (phase+first))
        writeD voice voiceSecondPhase (wrapPhase (phase2+second))
        writeD voice voiceThirdPhase (wrapPhase (phase3+third))
      mono value = pure (value,value)
  case instrument of
    0 -> do
      fundamental <- sineAt runtime phase
      sub <- sineAt runtime phase2
      advance dt (dt*0.5) dt
      mono (0.22*((0.3+0.4*tone)*saw + 0.55*fundamental+0.45*sub))
    1 -> do
      let secondSaw = 2*phase2-1-polyBlep phase2 (dt*1.003)
          thirdSaw = 2*phase3-1-polyBlep phase3 (dt*0.997)
      fundamental <- sineAt runtime phase
      advance dt (dt*1.003) (dt*0.997)
      pure (0.13*(0.55*saw+0.7*secondSaw+0.25*fundamental),0.13*(0.55*saw+0.7*thirdSaw+0.25*fundamental))
    2 -> do
      modulator <- sineAt runtime phase2
      carrier <- sineAt runtime (wrapPhase (phase+(0.08+tone*0.45)*decay 2.8*modulator))
      fundamental <- sineAt runtime phase
      advance dt (min 0.49 (dt*2.756)) dt
      mono (0.32*decay (1.2+tone*2)*(0.8*carrier+0.2*fundamental))
    3 -> do
      advance dt (dt*1.001) dt
      let bright = (0.75*saw+0.25*square)*(0.7+tone)
      mono (0.30*bright/(1+abs bright))
    4 -> do
      fundamental <- sineAt runtime phase
      let triangle = 1-4*abs (phase-0.5)
      advance dt dt dt
      mono (0.36*decay (2.2+tone*3.0)*(0.45*triangle+0.35*fundamental+0.2*saw))
    5 -> do
      body <- sineAt runtime phase
      noise <- nextNoise voice
      let pitchRatio = frequency/261.6255653005986
          kickHz = pitchRatio*(45+110*decay 45)
      advance (min 0.45 (kickHz/fromIntegral sampleRate)) dt dt
      mono (0.68*(body*decay 8.5+0.2*noise*decay 180))
    6 -> do
      noise <- nextNoise voice
      body <- sineAt runtime phase
      overtone <- sineAt runtime phase2
      advance (180/fromIntegral sampleRate) (331/fromIntegral sampleRate) dt
      mono (0.43*((0.65+tone*0.25)*noise*decay 18+0.3*body*decay 27+0.12*overtone*decay 35))
    7 -> do
      noise <- nextNoise voice
      let metal1 = if phase < 0.5 then 1 else -1
          metal2 = if phase2 < 0.5 then 1 else -1
          metal3 = if phase3 < 0.5 then 1 else -1
          signal = noise*0.65 + (metal1+metal2+metal3)*0.11
      advance (5731/fromIntegral sampleRate) (8123/fromIntegral sampleRate) (10391/fromIntegral sampleRate)
      mono (0.24*signal*decay (35+tone*55)*(1-decay 1700))
    _ -> samplePCMFrame plan track voice frequency
{-# INLINE instrumentSample #-}

samplePCMFrame :: Ptr Word8 -> Ptr Word8 -> Ptr Word8 -> Double -> IO (Double,Double)
samplePCMFrame plan track voice frequency = do
  sampleIndex <- readI track flatSampleIndex
  if sampleIndex < 0 then pure (0,0) else do
    offset <- readF plan flatSamplesOffset
    let sample = plan `plusPtr` (fromIntegral offset+fromIntegral sampleIndex*sampleStride)
    sourceRate <- readI sample flatSampleRate; channels <- readI sample flatSampleChannels
    sourceFrames <- readF sample flatSampleFrames; dataOffset <- readF sample flatSampleData
    previousPosition <- readD voice voiceSamplePosition
    initialized <- readI voice voiceSampleInitialized
    age <- readF voice voiceAge
    let positionScale = fromIntegral sourceRate/fromIntegral sampleRate*frequency/261.6255653005986
        base = castPtr (plan `plusPtr` fromIntegral dataOffset) :: Ptr Float
        sourcePosition = if initialized == 0 then fromIntegral age*positionScale else previousPosition
        index = floor sourcePosition :: Int
        fraction = sourcePosition-fromIntegral index
    writeD voice voiceSamplePosition (sourcePosition+positionScale)
    writeI voice voiceSampleInitialized 1
    if index >= fromIntegral sourceFrames || index < 0 then pure (0,0) else do
      let next = min (fromIntegral sourceFrames-1) (index+1)
          channel channelIndex = do
            first <- peekElemOff base (index*fromIntegral channels+channelIndex)
            second <- peekElemOff base (next*fromIntegral channels+channelIndex)
            pure (realToFrac first+(realToFrac second-realToFrac first)*fraction)
      left <- channel 0
      right <- if channels == 1 then pure left else channel 1
      pure (left,right)
{-# INLINE samplePCMFrame #-}

sineAt :: Runtime -> Double -> IO Double
sineAt Runtime{sineTable} phase = do
  let position = wrapPhase phase*fromIntegral sineSize
      index = min (sineSize-1) (floor position)
      fraction = position-fromIntegral index
  first <- peekElemOff sineTable index; second <- peekElemOff sineTable (index+1)
  pure (first+(second-first)*fraction)
{-# INLINE sineAt #-}

nextNoise :: Ptr Word8 -> IO Double
nextNoise voice = do
  previous <- readId voice voiceNoiseSeed
  let first = previous `xor` (previous `shiftL` 13)
      second = first `xor` (first `shiftR` 7)
      next = second `xor` (second `shiftL` 17)
  writeId voice voiceNoiseSeed next
  pure (fromIntegral (next `shiftR` 11)*(1/9007199254740992)*2-1)
{-# INLINE nextNoise #-}

polyBlep :: Double -> Double -> Double
polyBlep phase dt
  | phase < dt = let t = phase/dt in t+t-t*t-1
  | phase > 1-dt = let t = (phase-1)/dt in t*t+t+t+1
  | otherwise = 0
{-# INLINE polyBlep #-}

wrapPhase :: Double -> Double
wrapPhase phase = phase-fromIntegral (floor phase :: Int)
{-# INLINE wrapPhase #-}

finiteClip :: Double -> Double
finiteClip value | isNaN value || isInfinite value = 0
                 | otherwise = max (-1) (min 1 value)
{-# INLINE finiteClip #-}

mixTracks :: Runtime -> Ptr Word8 -> Int -> Double -> Double -> IO (Double,Double)
mixTracks runtime plan = walk
  where
    walk !slot !accumulatedLeft !accumulatedRight
      | slot >= maxTracks = pure (accumulatedLeft,accumulatedRight)
      | otherwise = do
          let state = trackState runtime slot
          active <- readI state stateActive
          if active == 0 then walk (slot+1) accumulatedLeft accumulatedRight else do
            index <- readI state statePlanIndex
            let track = trackAt plan (fromIntegral index)
            currentGain <- readD state stateGain; targetGain <- readD state stateTargetGain
            currentPan <- readD state statePan; targetPan <- readD state stateTargetPan
            currentG <- readD state stateFilterG; targetG <- readD state stateTargetFilterG
            sourceLeft <- readD state stateMixL; sourceRight <- readD state stateMixR
            let gain = currentGain+0.004*(targetGain-currentGain)
                pan = currentPan+0.004*(targetPan-currentPan)
                left = sourceLeft*gain*sqrt ((1-pan)*0.5)
                right = sourceRight*gain*sqrt ((1+pan)*0.5)
                nextG = currentG+0.004*(targetG-currentG)
            writeD state stateGain gain; writeD state statePan pan; writeD state stateFilterG nextG
            writeD state stateMixL 0; writeD state stateMixR 0
            writeIndex <- readI state stateDelayWrite; age <- readI state stateDelayAge
            delayTarget <- readI track flatDelayFrames
            currentDelay <- readD state stateDelayFrames
            let nextDelay = currentDelay + max (-1) (min 1 (fromIntegral delayTarget-currentDelay))
                delayFrames = max 1 (min delayCapacity (round nextDelay))
                readIndex = (fromIntegral writeIndex-delayFrames+delayCapacity) `rem` delayCapacity
                base = delays runtime `plusPtr` (slot*delayCapacity*2*4) :: Ptr Float
            delayedLeft <- if fromIntegral age < delayFrames then pure 0 else realToFrac <$> peekElemOff base (readIndex*2)
            delayedRight <- if fromIntegral age < delayFrames then pure 0 else realToFrac <$> peekElemOff base (readIndex*2+1)
            feedback <- readD track flatDelayFeedback; send <- readD track flatDelaySend
            let delayLeft = max (-8) (min 8 (left*send+delayedRight*feedback))
                delayRight = max (-8) (min 8 (right*send+delayedLeft*feedback))
            pokeElemOff base (fromIntegral writeIndex*2) (realToFrac delayLeft)
            pokeElemOff base (fromIntegral writeIndex*2+1) (realToFrac delayRight)
            writeI state stateDelayWrite (if writeIndex+1 >= fromIntegral delayCapacity then 0 else writeIndex+1)
            writeI state stateDelayAge (min (fromIntegral delayCapacity) (age+1))
            writeD state stateDelayFrames nextDelay
            muted <- readI track flatMuted
            let wetGain = if muted /= 0 then 0 else 1
            walk (slot+1) (accumulatedLeft+left+delayedLeft*wetGain) (accumulatedRight+right+delayedRight*wetGain)
{-# INLINE mixTracks #-}
