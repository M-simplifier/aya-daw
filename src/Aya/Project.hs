{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
module Aya.Project
  ( Id(..), Beat, beat, beats, fromDecimal, Project(..), Track(..), Patch(..)
  , Instrument(..), GeneratorKind(..), TransformKind(..), AutomationParameter(..)
  , Loop(..), Tuning(..), Note(..), Pattern(..), Generator(..), Transform(..)
  , Clip(..), Asset(..), Automation(..), Point(..), DomainError(..), problem
  , emptyProject, defaultTrack, defaultPatch, instrumentNames
  ) where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Char (toLower)
import Data.Ratio ((%))
import Data.Scientific (fromFloatDigits, base10Exponent, coefficient)
import Data.Text (Text)
import GHC.Generics (Generic)

newtype Id = Id { unId :: Text }
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

-- Raw input may contain negative time. Only Aya.Compile admits it to music.
newtype Beat = Beat Rational deriving stock (Eq, Ord, Show)
  deriving newtype (Num, Fractional, Real, RealFrac)

beat :: Rational -> Beat
beat = Beat

beats :: Beat -> Double
beats (Beat value) = fromRational value

fromDecimal :: Double -> Beat
fromDecimal = Beat . toRational . fromFloatDigits

instance ToJSON Beat where toJSON = toJSON . beats
instance FromJSON Beat where
  parseJSON = withScientific "beat" $ \value ->
    if base10Exponent value < -24 || base10Exponent value > 12 || abs (coefficient value) > 10^(30 :: Int)
      then fail "Beat precision/range exceeds supported musical time"
      else pure (Beat (toRational value))

jsonFields :: Int -> Options
jsonFields prefix = defaultOptions { fieldLabelModifier = lower . drop prefix }
  where lower [] = []; lower (c:cs) = toLower c : cs

data Instrument = Bass | Pad | Bell | Lead | Pluck | Kick | Snare | Hat | Sample
  deriving stock (Eq, Ord, Show, Enum, Bounded)
data GeneratorKind = Euclid | Arpeggio | Chords
  deriving stock (Eq, Ord, Show, Enum, Bounded)
data TransformKind = Transpose | Rotate | Reverse | Stretch | Invert | Probability
  deriving stock (Eq, Ord, Show, Enum, Bounded)
data AutomationParameter = Gain | Pan | Cutoff
  deriving stock (Eq, Ord, Show, Enum, Bounded)

instance ToJSON Instrument where toJSON = String . instrumentTag
instance FromJSON Instrument where parseJSON = parseTag "instrument" instrumentTag
instance ToJSON GeneratorKind where toJSON = String . generatorTag
instance FromJSON GeneratorKind where parseJSON = parseTag "generator kind" generatorTag
instance ToJSON TransformKind where toJSON = String . transformTag
instance FromJSON TransformKind where parseJSON = parseTag "transform kind" transformTag
instance ToJSON AutomationParameter where toJSON = String . automationTag
instance FromJSON AutomationParameter where parseJSON = parseTag "automation parameter" automationTag

parseTag :: (Enum a, Bounded a) => String -> (a -> Text) -> Value -> Parser a
parseTag name tag = withText name $ \value -> case lookup value [(tag choice,choice) | choice <- [minBound .. maxBound]] of
  Just choice -> pure choice
  Nothing -> fail ("Unknown " <> name <> ": " <> show value)

instrumentTag :: Instrument -> Text
instrumentTag instrument = case instrument of
  Bass -> "bass"; Pad -> "pad"; Bell -> "bell"; Lead -> "lead"; Pluck -> "pluck"
  Kick -> "kick"; Snare -> "snare"; Hat -> "hat"; Sample -> "sample"
generatorTag :: GeneratorKind -> Text
generatorTag kind = case kind of Euclid -> "euclid"; Arpeggio -> "arpeggio"; Chords -> "chords"
transformTag :: TransformKind -> Text
transformTag kind = case kind of
  Transpose -> "transpose"; Rotate -> "rotate"; Reverse -> "reverse"; Stretch -> "stretch"
  Invert -> "invert"; Probability -> "probability"
automationTag :: AutomationParameter -> Text
automationTag parameter = case parameter of Gain -> "gain"; Pan -> "pan"; Cutoff -> "cutoff"

data Project = Project
  { projectSchemaVersion :: Int, projectId :: Id, projectName :: Text
  , projectTempo :: Double, projectBeatsPerBar :: Int, projectLengthBeats :: Beat
  , projectMasterGain :: Double, projectLoop :: Loop, projectTuning :: Tuning
  , projectTracks :: [Track], projectPatterns :: [Pattern], projectClips :: [Clip]
  , projectAssets :: [Asset]
  } deriving stock (Eq, Show, Generic)
instance ToJSON Project where toJSON = genericToJSON (jsonFields 7)
instance FromJSON Project where parseJSON = genericParseJSON (jsonFields 7)

data Loop = Loop { loopEnabled :: Bool, loopStart :: Beat, loopEnd :: Beat }
  deriving stock (Eq, Show, Generic)
instance ToJSON Loop where toJSON = genericToJSON (jsonFields 4)
instance FromJSON Loop where parseJSON = genericParseJSON (jsonFields 4)

data Tuning = Tuning
  { tuningDivisions :: Int, tuningReferenceHz :: Double, tuningRoot :: Double
  , tuningScale :: [Int]
  } deriving stock (Eq, Show, Generic)
instance ToJSON Tuning where toJSON = genericToJSON (jsonFields 6)
instance FromJSON Tuning where parseJSON = genericParseJSON (jsonFields 6)

data Track = Track
  { trackId :: Id, trackName :: Text, trackColor :: Text, trackInstrument :: Instrument
  , trackGain :: Double, trackPan :: Double, trackMute :: Bool, trackSolo :: Bool
  , trackPatch :: Patch, trackAssetId :: Maybe Id, trackAutomation :: [Automation]
  } deriving stock (Eq, Show, Generic)
instance ToJSON Track where toJSON = genericToJSON (jsonFields 5)
instance FromJSON Track where parseJSON = genericParseJSON (jsonFields 5)

data Patch = Patch
  { patchAttack :: Double, patchRelease :: Double, patchCutoff :: Double
  , patchResonance :: Double, patchTone :: Double, patchDelaySend :: Double
  , patchDelayBeats :: Double, patchDelayFeedback :: Double
  } deriving stock (Eq, Show, Generic)
instance ToJSON Patch where toJSON = genericToJSON (jsonFields 5)
instance FromJSON Patch where parseJSON = genericParseJSON (jsonFields 5)

data Pattern = Pattern
  { patternId :: Id, patternName :: Text, patternLength :: Beat
  , patternNotes :: [Note], patternGenerator :: Maybe Generator
  , patternTransforms :: [Transform]
  } deriving stock (Eq, Show, Generic)
instance ToJSON Pattern where toJSON = genericToJSON (jsonFields 7)
instance FromJSON Pattern where parseJSON = genericParseJSON (jsonFields 7)

data Note = Note
  { noteId :: Id, noteStart :: Beat, noteDuration :: Beat
  , notePitch :: Double, noteVelocity :: Double
  } deriving stock (Eq, Show, Generic)
instance ToJSON Note where toJSON = genericToJSON (jsonFields 4)
instance FromJSON Note where parseJSON = genericParseJSON (jsonFields 4)

data Generator = Generator
  { generatorKind :: GeneratorKind, generatorSteps :: Int, generatorPulses :: Int
  , generatorRotation :: Int, generatorRoot :: Double, generatorOctaves :: Int
  , generatorGate :: Double, generatorSeed :: Int, generatorDegrees :: [Int]
  , generatorVelocity :: Double
  } deriving stock (Eq, Show, Generic)
instance ToJSON Generator where toJSON = genericToJSON (jsonFields 9)
instance FromJSON Generator where parseJSON = genericParseJSON (jsonFields 9)

data Transform = Transform { transformKind :: TransformKind, transformAmount :: Double }
  deriving stock (Eq, Show, Generic)
instance ToJSON Transform where toJSON = genericToJSON (jsonFields 9)
instance FromJSON Transform where parseJSON = genericParseJSON (jsonFields 9)

data Clip = Clip
  { clipId :: Id, clipTrackId :: Id, clipPatternId :: Id
  , clipStart :: Beat, clipLength :: Beat, clipTranspose :: Double, clipGain :: Double
  } deriving stock (Eq, Show, Generic)
instance ToJSON Clip where toJSON = genericToJSON (jsonFields 4)
instance FromJSON Clip where parseJSON = genericParseJSON (jsonFields 4)

data Asset = Asset
  { assetId :: Id, assetName :: Text, assetData :: Text
  , assetSampleRate :: Int, assetChannels :: Int, assetFrames :: Int
  } deriving stock (Eq, Show, Generic)
instance ToJSON Asset where toJSON = genericToJSON (jsonFields 5)
instance FromJSON Asset where
  parseJSON = withObject "WAV asset" $ \o -> Asset <$> o .: "id" <*> o .: "name" <*> o .: "data"
    <*> o .:? "sampleRate" .!= 0 <*> o .:? "channels" .!= 0 <*> o .:? "frames" .!= 0

data Automation = Automation { automationParameter :: AutomationParameter, automationPoints :: [Point] }
  deriving stock (Eq, Show, Generic)
instance ToJSON Automation where toJSON = genericToJSON (jsonFields 10)
instance FromJSON Automation where parseJSON = genericParseJSON (jsonFields 10)

data Point = Point { pointBeat :: Beat, pointValue :: Double }
  deriving stock (Eq, Show, Generic)
instance ToJSON Point where toJSON = genericToJSON (jsonFields 5)
instance FromJSON Point where parseJSON = genericParseJSON (jsonFields 5)

data DomainError = DomainError { errorPath :: Text, errorCode :: Text, errorMessage :: Text }
  deriving stock (Eq, Show, Generic)
instance ToJSON DomainError where toJSON = genericToJSON (jsonFields 5)

problem :: Text -> Text -> Text -> [DomainError]
problem path code message = [DomainError path code message]

defaultPatch :: Patch
defaultPatch = Patch 0.01 0.35 7000 0.12 0.5 0.15 0.75 0.32

defaultTrack :: Id -> Text -> Instrument -> Track
defaultTrack ident name instrument = Track ident name "#77b8ac" instrument 0.55 0 False False defaultPatch Nothing []

instrumentNames :: [(Instrument, Text)]
instrumentNames = [(Bass,"ベース"),(Pad,"パッド"),(Bell,"ベル"),(Lead,"リード"),
  (Pluck,"プラック"),(Kick,"キック"),(Snare,"スネア"),(Hat,"ハット"),(Sample,"サンプル")]

emptyProject :: Project
emptyProject = Project 1 (Id "aya-project") "無題の曲" 108 4 (beat (32 % 1)) 0.75
  (Loop False 0 16) (Tuning 12 440 60 [0,2,3,5,7,8,10])
  [defaultTrack (Id "track-1") "トラック 1" Pad] [] [] []
