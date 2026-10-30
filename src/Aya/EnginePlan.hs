{-# LANGUAGE OverloadedStrings #-}
module Aya.EnginePlan (toAudioPlan, beatFrame, frameBeat, decodeAsset, assetFromWave) where

import Aya.Compile
import Aya.Project
import qualified Aya.Audio as Audio
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as Base64
import Data.Int (Int64)
import Data.Scientific (fromFloatDigits)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text

beatFrame :: Double -> Beat -> Int64
beatFrame tempo position = round (toRational position * 60 * fromIntegral Audio.sampleRate / toRational (fromFloatDigits tempo))

frameBeat :: Double -> Int64 -> Double
frameBeat tempo frame = fromIntegral frame * tempo / (60 * fromIntegral Audio.sampleRate)

decodeAsset :: Asset -> Either [DomainError] Audio.AudioSample
decodeAsset asset = do
  bytes <- case Base64.decode (Text.encodeUtf8 (assetData asset)) of
    Left message -> Left (problem path "base64" ("WAVの埋込み形式が壊れています: " <> Text.pack message))
    Right value -> Right value
  pcm <- wavePCM path bytes
  let matches actual declared = declared == 0 || declared == actual
  if and [matches (Audio.pcmSampleRate pcm) (assetSampleRate asset),matches (Audio.pcmChannels pcm) (assetChannels asset),matches (Audio.pcmFrames pcm) (assetFrames asset)]
    then Right (Audio.AudioSample (unId (assetId asset)) pcm)
    else Left (problem path "asset-metadata" "WAVの内容と保存された素材情報が一致しません。元のWAVを読み込み直してください。")
  where path = "assets." <> unId (assetId asset)

wavePCM :: Text -> BS.ByteString -> Either [DomainError] Audio.PCM
wavePCM path bytes = case Audio.decodeWave bytes of
  Left (Audio.AudioError message) -> Left (problem path "wave" message)
  Right pcm -> Right pcm

assetFromWave :: Id -> Text -> BS.ByteString -> Either [DomainError] Asset
assetFromWave ident name bytes = do
  pcm <- wavePCM "assets" bytes
  pure (Asset ident name (Text.decodeUtf8 (Base64.encode bytes)) (Audio.pcmSampleRate pcm) (Audio.pcmChannels pcm) (Audio.pcmFrames pcm))

toAudioPlan :: Compilation -> Either [DomainError] Audio.AudioPlan
toAudioPlan compilation = do
  samples <- traverse decodeAsset (projectAssets project)
  tracks <- traverse audioTrack (projectTracks project)
  notes <- traverse audioNote (resolvedNotes resolved)
  let settings = projectLoop project
      loopFrames = if loopEnabled settings then Just (frame (loopStart settings),frame (loopEnd settings)) else Nothing
      plan = Audio.AudioPlan (projectTempo project) (frame (projectLengthBeats project))
        (projectMasterGain project) loopFrames tracks notes samples
  case Audio.validateAudioPlan plan of
    Left (Audio.AudioError message) -> Left (problem "audioPlan" "audio-capacity" message)
    Right () -> Right plan
  where
    project = compiledProject compilation; resolved = compiledResolved compilation
    frame = beatFrame (projectTempo project)
    anySolo = any trackSolo (projectTracks project)
    audioTrack track = Right (Audio.AudioTrack (unId (trackId track)) (audioInstrument (trackInstrument track)) (trackGain track) (trackPan track)
        (trackMute track || (anySolo && not (trackSolo track))) (audioPatch (trackPatch track))
        (unId <$> trackAssetId track) (map audioAutomation (trackAutomation track)))
    audioAutomation automation = Audio.Automation parameter [(frame (pointBeat p),pointValue p) | p <- automationPoints automation]
      where parameter = case automationParameter automation of Pan -> Audio.Pan; Cutoff -> Audio.Cutoff; Gain -> Audio.Gain
    audioNote note =
      let start = frame (resolvedStart note)
          duration = frame (resolvedStart note + resolvedDuration note) - start
      in if duration <= 0
           then Left (problem "notes.duration" "subsample-note" "音符が1サンプル未満です。長さを伸ばしてください。")
           else Right (Audio.AudioNote (unId (resolvedNoteId note)) (unId (resolvedTrackId note)) start duration
             (resolvedFrequency note) (resolvedVelocity note))

audioPatch :: Patch -> Audio.AudioPatch
audioPatch patch = Audio.AudioPatch (patchAttack patch) (patchRelease patch) (patchCutoff patch)
  (patchResonance patch) (patchTone patch) (patchDelaySend patch) (patchDelayBeats patch) (patchDelayFeedback patch)

audioInstrument :: Instrument -> Audio.Instrument
audioInstrument instrument = case instrument of
  Bass -> Audio.Bass; Pad -> Audio.Pad; Bell -> Audio.Bell; Lead -> Audio.Lead; Pluck -> Audio.Pluck
  Kick -> Audio.Kick; Snare -> Audio.Snare; Hat -> Audio.Hat; Sample -> Audio.Sample
