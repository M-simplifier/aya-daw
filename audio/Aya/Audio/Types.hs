{-# LANGUAGE DerivingStrategies #-}
module Aya.Audio.Types
  ( Frame, sampleRate, Instrument(..), Parameter(..), AudioPatch(..), defaultPatch
  , AudioTrack(..), AudioNote(..), Automation(..), PCM(..), AudioSample(..)
  , AudioPlan(..), AudioError(..), TransportCommand(..), EngineStatus(..)
  , RenderReport(..), instrumentName, instrumentFromName
  ) where

import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector.Storable as Vector

type Frame = Int64

sampleRate :: Int
sampleRate = 48000

data Instrument = Bass | Pad | Bell | Lead | Pluck | Kick | Snare | Hat | Sample
  deriving stock (Eq, Ord, Show, Read, Enum, Bounded)

data Parameter = Gain | Pan | Cutoff
  deriving stock (Eq, Ord, Show, Read, Enum, Bounded)

data AudioPatch = AudioPatch
  { patchAttack :: !Double
  , patchRelease :: !Double
  , patchCutoff :: !Double
  , patchResonance :: !Double
  , patchTone :: !Double
  , patchDelaySend :: !Double
  , patchDelayBeats :: !Double
  , patchDelayFeedback :: !Double
  } deriving stock (Eq, Show)

defaultPatch :: AudioPatch
defaultPatch = AudioPatch 0.012 0.28 9000 0.12 0.5 0.12 0.75 0.32

data Automation = Automation
  { automationParameter :: !Parameter
  , automationPoints :: ![(Frame, Double)]
  } deriving stock (Eq, Show)

data AudioTrack = AudioTrack
  { trackId :: !Text
  , trackInstrument :: !Instrument
  , trackGain :: !Double
  , trackPan :: !Double
  , trackMuted :: !Bool
  , trackPatch :: !AudioPatch
  , trackSampleId :: !(Maybe Text)
  , trackAutomation :: ![Automation]
  } deriving stock (Eq, Show)

data AudioNote = AudioNote
  { noteId :: !Text
  , noteTrackId :: !Text
  , noteStartFrame :: !Frame
  , noteDurationFrames :: !Frame
  , noteFrequency :: !Double
  , noteVelocity :: !Double
  } deriving stock (Eq, Show)

-- PCM samples are finite, interleaved and normalized. Only mono/stereo is admitted.
data PCM = PCM
  { pcmSampleRate :: !Int
  , pcmChannels :: !Int
  , pcmFrames :: !Int
  , pcmSamples :: !(Vector.Vector Float)
  } deriving stock (Eq, Show)

data AudioSample = AudioSample
  { sampleId :: !Text
  , samplePCM :: !PCM
  } deriving stock (Eq, Show)

data AudioPlan = AudioPlan
  { planTempo :: !Double
  , planLengthFrames :: !Frame
  , planMasterGain :: !Double
  , planLoop :: !(Maybe (Frame, Frame))
  , planTracks :: ![AudioTrack]
  , planNotes :: ![AudioNote]
  , planSamples :: ![AudioSample]
  } deriving stock (Eq, Show)

newtype AudioError = AudioError { audioErrorMessage :: Text }
  deriving stock (Eq, Show)

data TransportCommand = Play | Pause | Stop | Seek !Frame
  deriving stock (Eq, Show)

data EngineStatus = EngineStatus
  { engineAvailable :: !Bool
  , enginePlaying :: !Bool
  , engineFrame :: !Frame
  , engineSampleRate :: !Int
  , engineBufferFrames :: !Int
  , enginePeakL :: !Double
  , enginePeakR :: !Double
  , engineUnderruns :: !Int64
  , engineLateBuffers :: !Int64
  , engineProcessedBuffers :: !Int64
  , engineMaxProcessMicros :: !Double
  , engineVoiceOverflows :: !Int64
  , engineClippedSamples :: !Int64
  , engineMessage :: !Text
  } deriving stock (Eq, Show)

data RenderReport = RenderReport
  { renderPath :: !FilePath
  , renderFrames :: !Frame
  , renderDuration :: !Double
  , renderPeak :: !Double
  , renderClippedSamples :: !Int64
  } deriving stock (Eq, Show)

instrumentName :: Instrument -> Text
instrumentName = Text.toLower . Text.pack . show

instrumentFromName :: Text -> Maybe Instrument
instrumentFromName name = lookup (Text.toLower name) [(instrumentName i, i) | i <- [minBound .. maxBound]]
