{-# LANGUAGE OverloadedStrings #-}
module Aya.Example (exampleProject) where

import Aya.Project
import Data.Text (Text)
import qualified Data.Text as Text

-- An original 40-bar miniature: a quiet opening, two sections, a variation and a coda.
exampleProject :: Project
exampleProject = emptyProject
  { projectId = Id "example-glass-tides", projectName = "硝子の潮 — Glass Tides", projectTempo = 108
  , projectLengthBeats = 160, projectLoop = Loop False 32 96, projectMasterGain = 0.68
  , projectTuning = Tuning 19 440 60 [0,3,5,8,11,13,16]
  , projectTracks = tracks, projectPatterns = patterns, projectClips = clips
  }
  where
    tracks =
      [ (defaultTrack (Id "drum-kick") "深い鼓動" Kick) {trackGain=0.62,trackPatch=defaultPatch {patchDelaySend=0,patchRelease=0.12,patchTone=0.4}}
      , (defaultTrack (Id "drum-snare") "紙のスネア" Snare) {trackGain=0.26,trackPan=0.04,trackPatch=defaultPatch {patchDelaySend=0.08,patchRelease=0.12}}
      , (defaultTrack (Id "drum-hat") "細かな波" Hat) {trackGain=0.16,trackPan=(-0.24),trackPatch=defaultPatch {patchDelaySend=0.07,patchRelease=0.07},
          trackAutomation=[Automation Gain [Point 0 0.08,Point 32 0.17,Point 96 0.13,Point 128 0.2,Point 152 0.02]]}
      , (defaultTrack (Id "low") "潮の低音" Bass) {trackGain=0.35,trackPatch=defaultPatch {patchCutoff=1600,patchTone=0.3,patchDelaySend=0.04,patchRelease=0.2}}
      , (defaultTrack (Id "harmony") "十九の硝子" Pad) {trackGain=0.22,trackPan=(-0.1),trackPatch=defaultPatch {patchAttack=0.45,patchRelease=2.4,patchCutoff=2800,patchTone=0.28,patchDelaySend=0.18},
          trackAutomation=[Automation Cutoff [Point 0 700,Point 32 2500,Point 88 3900,Point 120 1700,Point 144 3200,Point 160 600],
            Automation Gain [Point 0 0.04,Point 12 0.24,Point 128 0.23,Point 160 0.02]]}
      , (defaultTrack (Id "arp") "水面の粒" Pluck) {trackGain=0.21,trackPan=0.3,trackPatch=defaultPatch {patchCutoff=6200,patchTone=0.42,patchRelease=0.7,patchDelaySend=0.32,patchDelayFeedback=0.4}}
      , (defaultTrack (Id "melody") "ひとつの灯" Bell) {trackGain=0.22,trackPan=0.08,trackPatch=defaultPatch {patchAttack=0.004,patchRelease=1.8,patchTone=0.26,patchDelaySend=0.26}}
      ]
    gen ident name len kind steps pulses root degrees velocity = Pattern (Id ident) name len []
      (Just (Generator kind steps pulses 0 root 1 0.75 23 degrees velocity)) []
    patterns =
      [ gen "p-kick" "四つの波" 4 Euclid 4 4 36 [0] 0.85
      , Pattern (Id "p-snare") "裏拍" 4 [Note (Id "snare-1") 1 0.2 40 0.72,Note (Id "snare-2") 3 0.2 40 0.65] Nothing []
      , gen "p-hat" "五つの粒" 4 Euclid 16 9 84 [0] 0.7
      , Pattern (Id "p-bass") "根と余白" 16 (zipWith bass [0 :: Int ..] [(0,36),(3,36),(4,39.1578947368),(7,39.1578947368),(8,34.7368421053),(11,34.7368421053),(12,41.0526315789),(14.5,43.5789473684)]) Nothing []
      , gen "p-pad" "ゆっくり巡る和音" 32 Chords 8 4 60 [0,2,-1,3] 0.68
      , gen "p-arp" "上昇する水面" 8 Arpeggio 16 5 72 [0,2,4,6,4,2,1,4] 0.64
      , (gen "p-arp-var" "回り込む水面" 8 Arpeggio 16 5 72 [0,2,4,6,4,2,1,4] 0.6)
          {patternTransforms=[Transform Reverse 0,Transform Rotate 0.5,Transform Probability 0.8]}
      , Pattern (Id "p-theme") "灯の主題" 16
          (zipWith theme [0 :: Int ..] [(0,79.5789473684,1.5),(2,77.0526315789,0.75),(3,75.1578947368,1.8),(6,72,1),(8,73.8947368421,1.4),(10,75.1578947368,0.6),(11,77.0526315789,0.75),(13,72,2.5)]) Nothing []
      , Pattern (Id "p-answer") "遠い返事" 16
          (zipWith themeAnswer [0 :: Int ..] [(0,84,2),(3,82.1052631579,1),(5,79.5789473684,2),(9,77.0526315789,1.5),(12,75.1578947368,3)]) Nothing []
      ]
    bass i (position,pitch) = Note (Id ("bass-note-" <> number i)) (fromDecimal position) 0.65 pitch (if even i then 0.85 else 0.66)
    theme i (position,pitch,duration) = Note (Id ("theme-note-" <> number i)) (fromDecimal position) (fromDecimal duration) pitch (0.65 + fromIntegral (i `mod` 3) * 0.08)
    themeAnswer i (position,pitch,duration) = (theme i (position,pitch,duration)) {noteId=Id ("answer-note-" <> number i)}
    clips = zipWith clip [0 :: Int ..]
      [("harmony","p-pad",0,160,0,1),("arp","p-arp",8,24,0,0.65),
       ("drum-kick","p-kick",16,128,0,1),("drum-snare","p-snare",32,112,0,1),
       ("drum-hat","p-hat",24,120,0,1),("low","p-bass",16,128,0,1),
       ("arp","p-arp",32,64,0,1),("arp","p-arp-var",96,48,0,1),
       ("melody","p-theme",32,32,0,1),("melody","p-answer",64,32,0,0.95),
       ("melody","p-theme",104,32,0,0.9),("melody","p-answer",144,16,-12,0.7),
       ("arp","p-arp-var",144,12,-12,0.6)]
    clip i (track,patternValue,start,len,transpose,gain) = Clip (Id ("clip-" <> number i)) (Id track) (Id patternValue) start len transpose gain
    number :: Int -> Text
    number = Text.pack . show
