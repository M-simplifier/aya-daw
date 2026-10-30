{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
module Aya.Audio.Plan
  ( PreparedPlan, preparePlan, validateAudioPlan, writePlan, checkFlatPlan
  , stableId, maxTracks, maxNotes, maxVoices, maxSongVoices, delayCapacity
  , trackStride, noteStride, sampleStride, planHeaderBytes, noteAt, trackAt
  , planTailFrames, preparedSource, preparedBytes, lookupNote, automationValue
  ) where

import Aya.Audio.Native (slotBytes)
import Aya.Audio.Layout
import Aya.Audio.Types
import Control.Monad (forM_, unless, foldM)
import Data.Bits (xor, (.&.))
import qualified Data.ByteString as ByteString
import Data.Int
import Data.List (sortOn, mapAccumL)
import qualified Data.Map.Strict as Map
import qualified Data.IntMap.Strict as IntMap
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word
import Foreign (Ptr, plusPtr, castPtr, fillBytes, copyBytes, peekElemOff, pokeElemOff, peekByteOff, pokeByteOff)
import qualified Data.Vector.Storable as Vector

maxTracks, maxNotes, maxVoices, maxSongVoices, delayCapacity :: Int
maxTracks = 32
maxNotes = 32768
maxSongVoices = 256
maxVoices = maxSongVoices + 32
delayCapacity = 4 * sampleRate

trackStride, noteStride, sampleStride, planHeaderBytes, hashCapacity :: Int
trackStride = 192
noteStride = 48
sampleStride = 32
planHeaderBytes = 128
hashCapacity = 65536

data PreparedPlan = PreparedPlan
  { preparedSourceValue :: !AudioPlan
  , sortedNotes :: ![AudioNote]
  , flattenedAutomation :: ![(Frame, Double)]
  , automationRanges :: ![[(Int, Int)]]
  , sampleOffsets :: ![Int]
  , layoutNotes :: !Int
  , layoutAutomation :: !Int
  , layoutSamples :: !Int
  , layoutHashes :: !Int
  , layoutIntervals :: !Int
  , layoutPCM :: !Int
  , layoutBytes :: !Int
  }

preparedSource :: PreparedPlan -> AudioPlan
preparedSource = preparedSourceValue

preparedBytes :: PreparedPlan -> Int
preparedBytes = layoutBytes

stableId :: Text -> Word64
stableId = nonzero . ByteString.foldl' (\h byte -> (h `xor` fromIntegral byte) * 1099511628211) 14695981039346656037 . Text.encodeUtf8
  where nonzero 0 = 1
        nonzero value = value

require :: Bool -> Text -> Either AudioError ()
require condition message = unless condition (Left (AudioError message))

finite :: Double -> Bool
finite value = not (isNaN value || isInfinite value)

within :: Text -> Double -> Double -> Double -> Either AudioError ()
within name lo hi value = require (finite value && value >= lo && value <= hi)
  (name <> " must be finite and between " <> Text.pack (show lo) <> " and " <> Text.pack (show hi))

uniqueIds :: Text -> [Text] -> Either AudioError ()
uniqueIds kind ids = do
  require (all (not . Text.null) ids) (kind <> " IDs must not be empty")
  require (length ids == Set.size (Set.fromList ids)) (kind <> " IDs must be unique")
  require (length ids == Set.size (Set.fromList (map stableId ids))) (kind <> " IDs have a 64-bit identity collision; rename one ID")

validateAudioPlan :: AudioPlan -> Either AudioError ()
validateAudioPlan = fmap (const ()) . preparePlan

preparePlan :: AudioPlan -> Either AudioError PreparedPlan
preparePlan source = do
  let tracks = planTracks source
      notes = planNotes source
      samples = planSamples source
      trackIds = Set.fromList (map trackId tracks)
      sampleIds = Set.fromList (map sampleId samples)
      endLimit = fromIntegral sampleRate * 4 * 60 * 60
  within "Tempo" 20 400 (planTempo source)
  within "Master gain" 0 2 (planMasterGain source)
  require (planLengthFrames source > 0 && planLengthFrames source <= endLimit) "Song length must be positive and at most four hours"
  require (length tracks <= maxTracks) "Audio capacity is 32 tracks; reduce the track count"
  require (length notes <= maxNotes) "Audio capacity is 32768 resolved notes; shorten or simplify the arrangement"
  require (length samples <= 32) "Audio capacity is 32 sample assets"
  uniqueIds "Track" (map trackId tracks)
  uniqueIds "Note" (map noteId notes)
  uniqueIds "Sample" (map sampleId samples)
  forM_ (planLoop source) $ \(start,end) ->
    require (start >= 0 && end > start && end <= planLengthFrames source) "Loop must be a nonempty interval inside the song"
  forM_ tracks $ \track -> do
    let patch = trackPatch track
    within "Track gain" 0 4 (trackGain track)
    within "Track pan" (-1) 1 (trackPan track)
    within "Attack seconds" 0.001 10 (patchAttack patch)
    within "Release seconds" 0.005 20 (patchRelease patch)
    within "Cutoff Hz" 20 20000 (patchCutoff patch)
    within "Resonance" 0 0.95 (patchResonance patch)
    within "Tone" 0 1 (patchTone patch)
    within "Delay send" 0 1 (patchDelaySend patch)
    within "Delay beats" 0.03125 16 (patchDelayBeats patch)
    within "Delay feedback" 0 0.92 (patchDelayFeedback patch)
    require (patchDelayBeats patch * 60 / planTempo source <= 4) "Tempo-synced delay exceeds four seconds; reduce delay beats"
    forM_ (trackSampleId track) $ \identity -> require (Set.member identity sampleIds) "Track refers to a missing sample asset"
    require (trackInstrument track /= Sample || maybe False (`Set.member` sampleIds) (trackSampleId track)) "A sample instrument needs a decoded WAV asset"
    require (length (trackAutomation track) <= 3 && length (map automationParameter (trackAutomation track)) == Set.size (Set.fromList (map automationParameter (trackAutomation track)))) "Each automation parameter may appear once per track"
    forM_ (trackAutomation track) $ \lane -> do
      let points = automationPoints lane
      require (map fst points == Set.toAscList (Set.fromList (map fst points))) "Automation frames must be strictly increasing"
      forM_ points $ \(frame,value) -> do
        require (frame >= 0 && frame <= planLengthFrames source) "Automation point lies outside the song"
        case automationParameter lane of
          Gain -> within "Automated gain" 0 4 value
          Pan -> within "Automated pan" (-1) 1 value
          Cutoff -> within "Automated cutoff" 20 20000 value
  forM_ notes $ \note -> do
    require (Set.member (noteTrackId note) trackIds) "Note refers to a missing track"
    require (noteStartFrame note >= 0 && noteDurationFrames note > 0 && noteStartFrame note < planLengthFrames source && noteDurationFrames note <= endLimit && noteStartFrame note + noteDurationFrames note <= planLengthFrames source) "A note interval lies outside the song"
    within "Note frequency Hz" 8 20000 (noteFrequency note)
    within "Note velocity" 0 1 (noteVelocity note)
  forM_ samples $ \sample -> do
    let pcm = samplePCM sample
    require (pcmSampleRate pcm >= 8000 && pcmSampleRate pcm <= 384000) "WAV sample rate must be 8000..384000 Hz"
    require (pcmChannels pcm `elem` [1,2]) "Only mono/stereo WAV samples are supported"
    require (pcmFrames pcm > 0 && pcmFrames pcm <= (24*1024*1024) `quot` pcmChannels pcm && Vector.length (pcmSamples pcm) == pcmFrames pcm * pcmChannels pcm) "Decoded sample length does not match its metadata or exceeds capacity"
    require (Vector.all (\x -> not (isNaN x || isInfinite x) && abs x <= 8) (pcmSamples pcm)) "Sample has nonfinite or excessively loud values"
  let sampleValues = sum (map (Vector.length . pcmSamples . samplePCM) samples)
      releases = Map.fromList [(trackId track, ceiling (patchRelease (trackPatch track) * fromIntegral sampleRate) :: Frame) | track <- tracks]
      occupancy = sortOn fst $ concat [[(noteStartFrame n,1 :: Int),(noteStartFrame n + noteDurationFrames n + Map.findWithDefault 0 (noteTrackId n) releases,-1)] | n <- notes, noteVelocity n > 0]
      groupedOccupancy = [(time,sum (map snd rest)+delta) | ((time,delta):rest) <- groupOnFirst occupancy]
      peak = maximum (0 : scanl (\count (_,delta) -> count + delta) 0 groupedOccupancy)
  require (peak <= maxSongVoices) ("Arrangement needs " <> Text.pack (show peak) <> " simultaneous voices including release tails; capacity is 256")
  require (sampleValues <= 24 * 1024 * 1024) "Decoded samples exceed 96 MiB; trim the WAV assets or use shorter material"
  let lanes track = [maybe [] automationPoints (findLane parameter (trackAutomation track)) | parameter <- [Gain,Pan,Cutoff]]
      allLanes = map lanes tracks
      (pointCount,ranges) = mapAccumL rangesForTrack 0 allLanes
      points = concat (concat allLanes)
      notesOffset = planHeaderBytes + length tracks * trackStride
      automationOffset = notesOffset + length notes * noteStride
      samplesOffset = automationOffset + pointCount * 16
      hashesOffset = samplesOffset + length samples * sampleStride
      intervalsOffset = hashesOffset + hashCapacity * 4
      pcmOffset = intervalsOffset + hashCapacity * 8
      (_,pcmOffsets) = mapAccumL (\offset sample -> (offset + Vector.length (pcmSamples (samplePCM sample)) * 4, offset)) pcmOffset samples
      bytes = pcmOffset + sampleValues * 4
  require (pointCount <= 65536) "Audio capacity is 65536 automation points"
  require (bytes <= slotBytes) "Flat execution plan exceeds 128 MiB; reduce assets or events"
  let orderedNotes = sortOn (\n -> (noteStartFrame n, stableId (noteId n))) notes
  validateHashProbes (map (stableId . noteId) orderedNotes)
  pure (PreparedPlan source orderedNotes points ranges pcmOffsets notesOffset automationOffset samplesOffset hashesOffset intervalsOffset pcmOffset bytes)
  where
    findLane _ [] = Nothing
    findLane parameter (lane:rest) | automationParameter lane == parameter = Just lane
                                 | otherwise = findLane parameter rest
    rangesForTrack offset lanes = mapAccumL (\start points -> (start + length points,(start,length points))) offset lanes
    groupOnFirst [] = []
    groupOnFirst (first:rest) = let (same,remaining) = span ((== fst first) . fst) rest in (first:same) : groupOnFirst remaining

validateHashProbes :: [Word64] -> Either AudioError ()
validateHashProbes identities = () <$ foldM insert IntMap.empty identities
  where
    insert table identity = probe 0 (fromIntegral identity .&. (hashCapacity-1))
      where
        probe !steps !position
          | steps >= (64 :: Int) = Left (AudioError "Note identities form an excessive lookup cluster; rename note IDs or split the project")
          | IntMap.member position table = probe (steps+1) ((position+1) .&. (hashCapacity-1))
          | otherwise = Right (IntMap.insert position identity table)

writePlan :: Ptr Word8 -> PreparedPlan -> IO ()
writePlan target prepared = do
  let source = preparedSource prepared
      tracks = planTracks source
      samples = planSamples source
      trackIndexes = Map.fromList (zip (map trackId tracks) [0 :: Int ..])
      sampleIndexes = Map.fromList (zip (map sampleId samples) [0 :: Int ..])
      notes = sortedNotes prepared
      writeI :: Int -> Int -> IO ()
      writeI offset value = pokeByteOff target offset (fromIntegral value :: Int64)
      writeN :: Int -> Int -> IO ()
      writeN offset value = pokeByteOff target offset (fromIntegral value :: Int32)
  fillBytes target 0 (layoutPCM prepared)
  pokeByteOff target 0 (0x41594131 :: Word32)
  writeN 4 1
  writeN 8 (length tracks); writeN 12 (length notes)
  writeN 16 (length (flattenedAutomation prepared)); writeN 20 (length samples)
  writeI 24 (layoutBytes prepared); pokeByteOff target 32 (planLengthFrames source)
  pokeByteOff target 40 (planTempo source); pokeByteOff target 48 (planMasterGain source)
  pokeByteOff target 56 (maybe (-1) fst (planLoop source)); pokeByteOff target 64 (maybe (-1) snd (planLoop source))
  writeI 72 (layoutNotes prepared); writeI 80 (layoutAutomation prepared)
  writeI 88 (layoutSamples prepared); writeI 96 (layoutPCM prepared)
  writeI 104 (layoutIntervals prepared); writeI 112 (layoutHashes prepared)
  forM_ (zip3 [0..] tracks (automationRanges prepared)) $ \(index,track,ranges) -> do
    let pointer = trackAt target index
        patch = trackPatch track
    pokeByteOff pointer flatTrackId (stableId (trackId track))
    pokeByteOff pointer flatInstrument (fromIntegral (fromEnum (trackInstrument track)) :: Int32)
    pokeByteOff pointer flatMuted (if trackMuted track then 1 else 0 :: Int32)
    forM_ (zip [flatGain,flatPan,flatAttack,flatRelease,flatCutoff,flatResonance,flatTone,flatDelaySend,flatDelayFeedback] [trackGain track,trackPan track,patchAttack patch,patchRelease patch,patchCutoff patch,patchResonance patch,patchTone patch,patchDelaySend patch,patchDelayFeedback patch]) $ \(offset,value) -> pokeByteOff pointer offset value
    pokeByteOff pointer flatDelayFrames (max 1 (round (patchDelayBeats patch * 60 / planTempo source * fromIntegral sampleRate)) :: Int32)
    pokeByteOff pointer flatSampleIndex (fromIntegral (maybe (-1) (\identity -> Map.findWithDefault (-1) identity sampleIndexes) (trackSampleId track)) :: Int32)
    forM_ (zip [flatAutomationRanges,flatAutomationRanges+8,flatAutomationRanges+16] ranges) $ \(offset,(start,count)) -> do
      pokeByteOff pointer offset (fromIntegral start :: Int32)
      pokeByteOff pointer (offset+4) (fromIntegral count :: Int32)
  forM_ (zip [0..] notes) $ \(index,note) -> do
    let pointer = target `plusPtr` (layoutNotes prepared + index * noteStride)
    pokeByteOff pointer flatNoteId (stableId (noteId note))
    pokeByteOff pointer flatNoteTrack (fromIntegral (Map.findWithDefault (-1) (noteTrackId note) trackIndexes) :: Int32)
    pokeByteOff pointer flatNoteStart (noteStartFrame note)
    pokeByteOff pointer flatNoteEnd (noteStartFrame note + noteDurationFrames note)
    pokeByteOff pointer flatNoteFrequency (noteFrequency note); pokeByteOff pointer flatNoteVelocity (noteVelocity note)
  forM_ (zip [0..] (flattenedAutomation prepared)) $ \(index,(frame,value)) -> do
    pokeByteOff target (layoutAutomation prepared + index*16) frame
    pokeByteOff target (layoutAutomation prepared + index*16+8) value
  forM_ (zip3 [0..] samples (sampleOffsets prepared)) $ \(index,sample,offset) -> do
    let pointer = target `plusPtr` (layoutSamples prepared + index * sampleStride)
        pcm = samplePCM sample
    pokeByteOff pointer flatSampleId (stableId (sampleId sample))
    pokeByteOff pointer flatSampleRate (fromIntegral (pcmSampleRate pcm) :: Int32)
    pokeByteOff pointer flatSampleChannels (fromIntegral (pcmChannels pcm) :: Int32)
    pokeByteOff pointer flatSampleFrames (fromIntegral (pcmFrames pcm) :: Int64)
    pokeByteOff pointer flatSampleData (fromIntegral offset :: Int64)
    Vector.unsafeWith (pcmSamples pcm) $ \samplesPointer -> copyBytes (target `plusPtr` offset) samplesPointer (Vector.length (pcmSamples pcm)*4)
  let hashes = castPtr (target `plusPtr` layoutHashes prepared) :: Ptr Int32
      intervals = castPtr (target `plusPtr` layoutIntervals prepared) :: Ptr Int64
  fillBytes hashes 255 (hashCapacity*4)
  forM_ (zip [0..] notes) $ \(index,note) -> insertHash hashes (stableId (noteId note)) index
  forM_ (zip [0..] notes) $ \(index,note) -> pokeElemOff intervals (32768+index) (noteStartFrame note + noteDurationFrames note)
  let buildTree !index | index <= 0 = pure ()
                       | otherwise = do
                           left <- peekElemOff intervals (index*2)
                           right <- peekElemOff intervals (index*2+1)
                           pokeElemOff intervals index (max left right)
                           buildTree (index-1)
  buildTree 32767
  where
    insertHash :: Ptr Int32 -> Word64 -> Int -> IO ()
    insertHash hashes key index = probe (fromIntegral key .&. (hashCapacity-1))
      where probe !position = do
              entry <- peekElemOff hashes position
              if entry < 0 then pokeElemOff hashes position (fromIntegral index)
                else probe ((position+1) .&. (hashCapacity-1))

checkFlatPlan :: Ptr Word8 -> IO Bool
checkFlatPlan plan = do
  magic <- peekByteOff plan 0 :: IO Word32
  version <- peekByteOff plan 4 :: IO Int32
  tracks <- peekByteOff plan 8 :: IO Int32
  notes <- peekByteOff plan 12 :: IO Int32
  automation <- peekByteOff plan 16 :: IO Int32
  samples <- peekByteOff plan 20 :: IO Int32
  bytes <- peekByteOff plan 24 :: IO Int64
  notesOffset <- peekByteOff plan flatNotesOffset :: IO Int64
  automationOffset <- peekByteOff plan flatAutomationOffset :: IO Int64
  samplesOffset <- peekByteOff plan flatSamplesOffset :: IO Int64
  hashesOffset <- peekByteOff plan flatHashesOffset :: IO Int64
  intervalsOffset <- peekByteOff plan flatIntervalsOffset :: IO Int64
  pcmOffset <- peekByteOff plan flatPCMOffset :: IO Int64
  pure (magic == 0x41594131 && version == 1 &&
    tracks >= 0 && tracks <= fromIntegral maxTracks && notes >= 0 && notes <= fromIntegral maxNotes &&
    automation >= 0 && automation <= 65536 && samples >= 0 && samples <= 32 &&
    notesOffset == fromIntegral planHeaderBytes+fromIntegral tracks*fromIntegral trackStride &&
    automationOffset == notesOffset+fromIntegral notes*fromIntegral noteStride &&
    samplesOffset == automationOffset+fromIntegral automation*16 &&
    hashesOffset == samplesOffset+fromIntegral samples*fromIntegral sampleStride &&
    intervalsOffset == hashesOffset+fromIntegral hashCapacity*4 &&
    pcmOffset == intervalsOffset+fromIntegral hashCapacity*8 && bytes >= pcmOffset && bytes <= fromIntegral slotBytes)

trackAt :: Ptr Word8 -> Int -> Ptr Word8
trackAt plan index = plan `plusPtr` (planHeaderBytes + index*trackStride)
{-# INLINE trackAt #-}

noteAt :: Ptr Word8 -> Int -> IO (Ptr Word8)
noteAt plan index = do
  offset <- peekByteOff plan flatNotesOffset :: IO Int64
  pure (plan `plusPtr` (fromIntegral offset + index*noteStride))
{-# INLINE noteAt #-}

lookupNote :: Ptr Word8 -> Word64 -> IO Int
lookupNote plan identity = do
  offset <- peekByteOff plan flatHashesOffset :: IO Int64
  let hashes = castPtr (plan `plusPtr` fromIntegral offset) :: Ptr Int32
      probe :: Int -> Int -> IO Int
      probe !position !remaining
        | remaining == 0 = pure (-1)
        | otherwise = do
            index <- peekElemOff hashes position
            if index < 0 then pure (-1) else do
              pointer <- noteAt plan (fromIntegral index)
              found <- peekByteOff pointer flatNoteId
              if found == identity then pure (fromIntegral index)
                else probe ((position+1) .&. (hashCapacity-1)) (remaining-1)
  probe (fromIntegral identity .&. (hashCapacity-1)) 64

automationValue :: Ptr Word8 -> Ptr Word8 -> Int -> Frame -> Double -> IO Double
automationValue plan track lane frame fallback = do
  start <- peekByteOff track (flatAutomationRanges+lane*8) :: IO Int32
  count <- peekByteOff track (flatAutomationRanges+4+lane*8) :: IO Int32
  offset <- peekByteOff plan flatAutomationOffset :: IO Int64
  let base = plan `plusPtr` (fromIntegral offset + fromIntegral start*16)
      valueAt index = peekByteOff base (index*16+8) :: IO Double
      frameAt index = peekByteOff base (index*16) :: IO Int64
      search !lo !hi
        | hi-lo <= 1 = pure lo
        | otherwise = do
            let middle = (lo+hi) `quot` 2
            time <- frameAt middle
            if time <= frame then search middle hi else search lo middle
  if count <= 0 then pure fallback else do
    firstFrame <- frameAt 0
    if frame <= firstFrame then valueAt 0 else do
      let lastIndex = fromIntegral count-1
      lastFrame <- frameAt lastIndex
      if frame >= lastFrame then valueAt lastIndex else do
        index <- search 0 lastIndex
        leftFrame <- frameAt index; rightFrame <- frameAt (index+1)
        left <- valueAt index; right <- valueAt (index+1)
        pure (left + (right-left) * fromIntegral (frame-leftFrame) / fromIntegral (rightFrame-leftFrame))
{-# INLINE automationValue #-}

planTailFrames :: AudioPlan -> Frame
planTailFrames plan = ceiling ((maximum (0.1 : map tailSeconds (planTracks plan))) * fromIntegral sampleRate)
  where
    tailSeconds track =
      let patch = trackPatch track
          delaySeconds = patchDelayBeats patch * 60 / planTempo plan
          echoes | patchDelaySend patch <= 0 = 0
                 | patchDelayFeedback patch <= 0 = delaySeconds
                 | otherwise = delaySeconds * (1 + ceilingDouble (log 0.000001 / log (patchDelayFeedback patch)))
      in patchRelease patch + echoes + 0.15
    ceilingDouble = fromIntegral . (ceiling :: Double -> Int)
