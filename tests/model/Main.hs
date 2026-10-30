{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Aya.Compile
import Aya.EnginePlan
import Aya.Example
import Aya.Project
import qualified Aya.Midi as Midi
import qualified Aya.Audio as Audio
import Control.Monad (unless)
import Data.Aeson (eitherDecode,encode)
import Data.Binary.Put
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Either (isLeft)
import Data.List (sortOn)
import Data.Ratio ((%))
import qualified Data.Text as Text
import System.Directory (createDirectoryIfMissing)
import System.Exit (exitFailure)
import Test.QuickCheck

main :: IO ()
main = do
  checks <- sequence
    [ test "empty project compiles to silence" $ null . resolvedNotes . compiledResolved <$> compileProject emptyProject
    , test "whole original example is admitted by native capacities" $ toAudioPlan <$> compileProject exampleProject >>= pure . either (const False) (const True)
    , test "reverse reflects the complete interval" $ (==[(2.5,0.5)]) . intervals <$> transformed [Transform Reverse 0]
    , test "rotation wraps and splits the sounding interval" $ (==[(0,0.25),(3.75,0.25)]) . intervals <$> compileOne [Note (Id "n") 3.5 0.5 60 0.8] [Transform Rotate 0.25]
    , test "successive wrapped rotations retain distinct fragment identities" $ do
        c <- compileOne [Note (Id "n") 1 3 60 0.8] [Transform Rotate 0.5,Transform Rotate 0.25]
        _ <- toAudioPlan c
        committed <- materialize (compiledProject c) (Id "p")
        pure (sum (map noteDuration (patternResult committed)) == 3)
    , test "stretch changes duration and period together" $ (\c -> case resolvedPatterns (compiledResolved c) of p:_ -> resolvedPatternLength p == 8 && intervals c == [(2,1)]; [] -> False) <$> transformed [Transform Stretch 2]
    , test "probability zero and one have exact boundary meanings" $ do a <- transformed [Transform Probability 0]; b <- transformed [Transform Probability 1]; pure (null (intervals a) && intervals b == [(1,0.5)])
    , test "Euclidean rhythm has independently expected positions" $ (==[0,1.5,3]) . map noteStart . patternResult <$> generated (Generator Euclid 8 3 0 60 1 0.5 7 [0] 0.8)
    , test "EDO degree wrap also works below zero" $ Right (abs (degreePitch (Tuning 19 440 60 [0,3,5,8,11,13,16]) 60 (-1) - (60 - 36/19)) < 1e-12)
    , test "arrangement repeats canonical intervals and clips the last repeat" $ (==[(4,1),(8,1),(12,0.5)]) . map (\n -> (resolvedStart n,resolvedDuration n)) . resolvedNotes . compiledResolved <$> compileProject arrangementFixture
    , test "materialization keeps the exact resolved musical result" $ do
        original <- generated (Generator Arpeggio 8 3 0 60 1 0.5 2 [0,2,4] 0.8)
        committed <- materialize (compiledProject original) (Id "p")
        pure (compiledResolved original == compiledResolved committed && all ((==Nothing) . patternGenerator) (projectPatterns (compiledProject committed)))
    , test "invalid projects return their reasons" $ Right (all isLeft invalidProjects)
    , test "expanded note capacity rejects instead of truncating" $ Right (isLeft (compileProject excessiveFixture))
    , test "triplets become exact integer samples once" $ Right (beatFrame 120 (beat (1%3)) == 8000 && beatFrame 120 (beat (2%3)) == 16000)
    , test "large Rational compiler arithmetic preserves independent interval/sample expectations" $ do
        let startValue = 123456789012345678901234 % (10^(24 :: Int))
            factor = (1001 % 1000)^(32 :: Int)
            project = projectWith basePattern {patternNotes=[Note (Id "n") (beat startValue) 0.2 60 0.8],
              patternTransforms=replicate 32 (Transform Stretch 1.001)}
        compilation <- compileProject project
        plan <- toAudioPlan compilation
        pure (case (patternResult compilation,Audio.planNotes plan) of
          (note:_,rendered:_) -> noteStart note == beat (startValue*factor)
            && noteDuration note == beat ((1%5)*factor)
            && Audio.noteStartFrame rendered == round (startValue*factor*(80000%3))
          _ -> False)
    , test "self-contained embedded WAV project round trips" embeddedAssetRoundTrip
    , test "WAV content is checked against metadata" $ do
        asset <- assetFromWave (Id "sample") "impulse.wav" waveFixture
        pure (isLeft (decodeAsset asset {assetFrames=999}))
    , test "malformed WAV is rejected" $ Right (isLeft (assetFromWave (Id "broken") "broken.wav" "RIFF1234bad"))
    , test "MIDI tempo map preserves real elapsed time" $ do
        (project,_) <- Midi.importMidi "tempo fixture" midiTempoFixture
        compilation <- compileProject project
        pure (map resolvedDuration (resolvedNotes (compiledResolved compilation)) == [3])
    , test "MIDI pitch bend preserves fractional onset pitch" $ do
        compilation <- compileOne [Note (Id "n") 1 0.5 60.25 0.8] []
        (bytes,_) <- Midi.exportMidi compilation
        (project,_) <- Midi.importMidi "pitch roundtrip" bytes
        decoded <- compileProject project
        pure (case resolvedNotes (compiledResolved decoded) of note:_ -> abs (resolvedPitch note - 60.25) < 0.00025; [] -> False)
    , test "MIDI rejects a sixteenth simultaneous melodic voice" $ do
        compilation <- compileOne [Note (Id ("n" <> Text.pack (show i))) 0 1 (60+fromIntegral i/10) 0.8 | i <- [0..15 :: Int]] []
        pure (isLeft (Midi.exportMidi compilation))
    , test "MIDI malformed input is rejected" $ Right (isLeft (Midi.importMidi "bad.mid" "MThd"))
    ]
  propertyResults <- sequence
    [ quickCheckWithResult stdArgs {maxSuccess=200} propReverseInvolution
    , quickCheckWithResult stdArgs {maxSuccess=200} propTransposeComposition
    , quickCheckWithResult stdArgs {maxSuccess=200} propClipEndBound
    ]
  exportChecks <- renderRoundTrip
  unless (and checks && all isSuccess propertyResults && exportChecks) exitFailure
  putStrLn "PASS: 22 musical/codec/interchange checks, 600 generated law cases, deterministic reopen render"

test :: String -> Either [DomainError] Bool -> IO Bool
test name result = do
  let passed = result == Right True
  putStrLn ((if passed then "PASS " else "FAIL ") ++ name ++ if passed then "" else " " ++ show result)
  pure passed

basePattern :: Pattern
basePattern = Pattern (Id "p") "test" 4 [Note (Id "n") 1 0.5 60 0.8] Nothing []
projectWith :: Pattern -> Project
projectWith patternValue = emptyProject {projectPatterns=[patternValue],projectClips=[Clip (Id "c") (Id "track-1") (Id "p") 0 4 0 1]}
transformed :: [Transform] -> Either [DomainError] Compilation
transformed transforms = compileProject (projectWith basePattern {patternTransforms=transforms})
compileOne :: [Note] -> [Transform] -> Either [DomainError] Compilation
compileOne notes transforms = compileProject (projectWith basePattern {patternNotes=notes,patternTransforms=transforms})
generated :: Generator -> Either [DomainError] Compilation
generated generator = compileProject (projectWith basePattern {patternNotes=[],patternGenerator=Just generator})
patternResult :: Compilation -> [Note]
patternResult compilation = case resolvedPatterns (compiledResolved compilation) of patternValue:_ -> resolvedPatternNotes patternValue; [] -> []
intervals :: Compilation -> [(Beat,Beat)]
intervals = sortOn fst . map (\n -> (noteStart n,noteDuration n)) . patternResult

arrangementFixture :: Project
arrangementFixture = (projectWith basePattern {patternNotes=[Note (Id "n") 0 1 60 0.8]})
  {projectClips=[Clip (Id "c") (Id "track-1") (Id "p") 4 8.5 0 1]}
excessiveFixture :: Project
excessiveFixture = (projectWith basePattern {patternLength=0.00001,patternNotes=[Note (Id "n") 0 0.000005 60 0.8]})
  {projectClips=[Clip (Id "c") (Id "track-1") (Id "p") 0 4 0 1]}
invalidProjects :: [Either [DomainError] Compilation]
invalidProjects = map compileProject
  [emptyProject {projectTempo=0},projectWith basePattern {patternNotes=[Note (Id "n") 3.5 1 60 0.8]},
   emptyProject {projectTracks=[defaultTrack (Id "track-1") "x" Pad,defaultTrack (Id "track-1") "duplicate" Pad]},
   emptyProject {projectTuning=Tuning 12 440 60 [0,7,2]},
   (projectWith basePattern) {projectClips=[Clip (Id "c") (Id "missing") (Id "p") 0 4 0 1]},
   emptyProject {projectTracks=[(defaultTrack (Id "track-1") "x" Pad) {trackAutomation=[Automation Gain [Point 2 0.3,Point 1 0.2]]}]}]

propReverseInvolution :: NonNegative Int -> Property
propReverseInvolution (NonNegative raw) =
  let start = fromIntegral (raw `mod` 24) / 8; duration = 0.5
      notes=[Note (Id "n") start duration 60 0.8]
  in fmap patternResult (compileOne notes [Transform Reverse 0,Transform Reverse 0]) === Right notes

propTransposeComposition :: Small Int -> Small Int -> Property
propTransposeComposition (Small a) (Small b) =
  let x=fromIntegral (a `mod` 12); y=fromIntegral (b `mod` 12)
  in fmap patternResult (transformed [Transform Transpose x,Transform Transpose y]) === fmap patternResult (transformed [Transform Transpose (x+y)])

propClipEndBound :: Positive Int -> Property
propClipEndBound (Positive raw) =
  let lengthBeats=fromIntegral (1+raw `mod` 100) / 4
      project=(projectWith basePattern) {projectClips=[Clip (Id "c") (Id "track-1") (Id "p") 0 lengthBeats 0 1]}
  in case compileProject project of
       Left errors -> counterexample (show errors) False
       Right c -> property (all (\n -> resolvedStart n >= 0 && resolvedStart n+resolvedDuration n <= lengthBeats) (resolvedNotes (compiledResolved c)))

embeddedAssetRoundTrip :: Either [DomainError] Bool
embeddedAssetRoundTrip = do
  asset <- assetFromWave (Id "sample") "impulse.wav" waveFixture
  let project=emptyProject {projectAssets=[asset],projectTracks=[(defaultTrack (Id "track-1") "sample" Sample) {trackAssetId=Just (Id "sample")}]}
  case eitherDecode (encode project) of
    Left _ -> pure False
    Right decoded -> do _ <- toAudioPlan =<< compileProject decoded; pure (decoded == project)

waveFixture :: BS.ByteString
waveFixture = LBS.toStrict $ runPut $ do
  putByteString "RIFF"; putWord32le 44; putByteString "WAVEfmt "; putWord32le 16
  putWord16le 1; putWord16le 1; putWord32le 48000; putWord32le 96000; putWord16le 2; putWord16le 16
  putByteString "data"; putWord32le 8; mapM_ putInt16le [0,16384,0,-16384]

midiTempoFixture :: BS.ByteString
midiTempoFixture = LBS.toStrict $ runPut $ do
  putByteString "MThd"; putWord32be 6; putWord16be 1; putWord16be 2; putWord16be 480
  chunk [0,0xff,0x51,3,7,0xa1,0x20,0x83,0x60,0xff,0x51,3,0x0f,0x42,0x40,0x83,0x60,0xff,0x2f,0]
  chunk [0,0x90,69,100,0x87,0x40,0x80,69,0,0,0xff,0x2f,0]
  where chunk bytes = putByteString "MTrk" >> putWord32be (fromIntegral (length bytes)) >> mapM_ putWord8 bytes

renderRoundTrip :: IO Bool
renderRoundTrip = do
  createDirectoryIfMissing True ".work/model-tests"
  let project = (projectWith basePattern {patternNotes=[Note (Id "n") 0 0.25 60.25 0.4]})
        {projectLengthBeats=4,projectLoop=Loop False 0 4,projectTracks=[(defaultTrack (Id "track-1") "bell" Bell)
          {trackPatch=defaultPatch {patchRelease=0.05,patchDelaySend=0}}]}
      result = do original <- compileProject project; plan <- toAudioPlan original
                  decoded <- either (const (Left (problem "json" "decode" "decode"))) Right (eitherDecode (encode project))
                  reopened <- compileProject decoded; reopenedPlan <- toAudioPlan reopened; pure (plan,reopenedPlan)
  case result of
    Left errors -> print errors >> pure False
    Right (plan,reopenedPlan) -> do
      left <- Audio.renderWav ".work/model-tests/original.wav" plan Nothing
      right <- Audio.renderWav ".work/model-tests/reopened.wav" reopenedPlan Nothing
      case (left,right) of
        (Right _,Right _) -> do
          a<-BS.readFile ".work/model-tests/original.wav"; b<-BS.readFile ".work/model-tests/reopened.wav"
          let passed=plan==reopenedPlan && a==b && BS.length a>44
          putStrLn (if passed then "PASS deterministic reopened project renders identical WAV" else "FAIL reopened render")
          pure passed
        failures -> print failures >> pure False
