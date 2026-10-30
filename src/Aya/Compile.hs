{-# LANGUAGE OverloadedStrings #-}
module Aya.Compile
  ( Compilation, compiledProject, compiledResolved, Resolved(..), ResolvedPattern(..)
  , ResolvedNote(..), compileProject, materialize, degreePitch, frequencyFor
  ) where

import Aya.Project
import Data.Aeson (ToJSON(..), object, (.=))
import Data.Bits (xor)
import Data.Char (isAlphaNum)
import Data.List (nub, sort, sortOn)
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)

data Compilation = Compilation Project Resolved deriving (Eq, Show)
compiledProject :: Compilation -> Project
compiledProject (Compilation project _) = project
compiledResolved :: Compilation -> Resolved
compiledResolved (Compilation _ resolved) = resolved

data Resolved = Resolved
  { resolvedPatterns :: [ResolvedPattern], resolvedNotes :: [ResolvedNote]
  , resolvedLengthBeats :: Beat
  } deriving (Eq, Show)
instance ToJSON Resolved where
  toJSON r = object ["patterns" .= resolvedPatterns r, "notes" .= resolvedNotes r,
    "lengthBeats" .= resolvedLengthBeats r]

data ResolvedPattern = ResolvedPattern
  { resolvedPatternId :: Id, resolvedPatternLength :: Beat, resolvedPatternNotes :: [Note]
  } deriving (Eq, Show)
instance ToJSON ResolvedPattern where
  toJSON p = object ["id" .= resolvedPatternId p,"length" .= resolvedPatternLength p,
    "notes" .= resolvedPatternNotes p]

data ResolvedNote = ResolvedNote
  { resolvedNoteId :: Id, resolvedTrackId :: Id, resolvedClipId :: Id
  , resolvedStart :: Beat, resolvedDuration :: Beat, resolvedPitch :: Double
  , resolvedFrequency :: Double, resolvedVelocity :: Double
  } deriving (Eq, Show)
instance ToJSON ResolvedNote where
  toJSON n = object ["id" .= resolvedNoteId n,"trackId" .= resolvedTrackId n,
    "clipId" .= resolvedClipId n,"start" .= resolvedStart n,"duration" .= resolvedDuration n,
    "pitch" .= resolvedPitch n,"frequency" .= resolvedFrequency n,"velocity" .= resolvedVelocity n]

compileProject :: Project -> Either [DomainError] Compilation
compileProject project = do
  requireClean (validateProject project)
  let patterns = map (resolvePattern (projectTuning project)) (projectPatterns project)
      patternTable = Map.fromList [(resolvedPatternId p,p) | p <- patterns]
      boundedNotes = take 32769 (concatMap (resolveClip (projectTuning project) patternTable) (projectClips project))
      transformErrors = concatMap validateResolvedPattern patterns
      noteErrors = concatMap validateResolvedNote boundedNotes
  requireClean (transformErrors ++ noteErrors ++ check (length boundedNotes > 32768)
    "clips" "capacity" "配置後の音符は32,768音までです。クリップの長さか音数を減らしてください。")
  pure (Compilation project (Resolved patterns (sortOn (\n -> (resolvedStart n,resolvedTrackId n,resolvedNoteId n)) boundedNotes) (projectLengthBeats project)))

requireClean :: [DomainError] -> Either [DomainError] ()
requireClean [] = Right ()
requireClean errors = Left errors

check :: Bool -> Text -> Text -> Text -> [DomainError]
check condition path code message = if condition then problem path code message else []

finite :: Double -> Bool
finite x = not (isNaN x || isInfinite x)

range :: Text -> Double -> Double -> Double -> [DomainError]
range path lo hi value = check (not (finite value) || value < lo || value > hi)
  path "range" ("値は " <> text lo <> " 〜 " <> text hi <> " の範囲にしてください。")

text :: Show a => a -> Text
text = Text.pack . show

at :: Text -> Id -> Text
at kind ident = kind <> "." <> unId ident

validateProject :: Project -> [DomainError]
validateProject project = concat
  [ check (projectSchemaVersion project /= 1) "schemaVersion" "version" "対応しているプロジェクト形式は1です。"
  , range "tempo" 30 300 (projectTempo project)
  , check (projectBeatsPerBar project < 1 || projectBeatsPerBar project > 16) "beatsPerBar" "range" "拍子は1〜16拍です。"
  , check (projectLengthBeats project <= 0 || projectLengthBeats project > 4096) "lengthBeats" "range" "曲の長さは0より大きく4,096拍以下にしてください。"
  , range "masterGain" 0 2 (projectMasterGain project)
  , check (Text.null (Text.strip (projectName project)) || Text.length (projectName project) > 200) "name" "name" "曲名は1〜200文字です。"
  , validateIds allIds
  , check (length (projectTracks project) > 32) "tracks" "capacity" "トラックは32本までです。"
  , check (length (projectPatterns project) > 256) "patterns" "capacity" "音型は256個までです。"
  , check (length (projectClips project) > 2048) "clips" "capacity" "クリップは2,048個までです。"
  , check (sum (map (length . patternNotes) (projectPatterns project)) > 32768) "patterns" "capacity" "元の音符は合計32,768音までです。"
  , check (length (projectAssets project) > 32) "assets" "capacity" "素材は32個までです。"
  , check (sum (map (Text.length . assetData) (projectAssets project)) > 180000000) "assets" "capacity" "埋込みWAVは合計128 MiBまでです。"
  , validateLoop (projectLengthBeats project) (projectLoop project)
  , validateTuning (projectTuning project)
  , concatMap (validateTrack project) (projectTracks project)
  , concatMap validatePattern (projectPatterns project)
  , concatMap (validateClip project) (projectClips project)
  ]
  where allIds = projectId project : map trackId (projectTracks project)
          ++ map patternId (projectPatterns project) ++ map clipId (projectClips project)
          ++ map assetId (projectAssets project) ++ concatMap (map noteId . patternNotes) (projectPatterns project)

validateIds :: [Id] -> [DomainError]
validateIds ids = check (length ids /= Set.size (Set.fromList ids)) "id" "duplicate-id" "IDが重複しています。別のIDを割り当ててください。"
  ++ concat [check (Text.null value || Text.length value > 96 || not (Text.all allowed value))
       ("id." <> value) "invalid-id" "IDには96文字以内の文字・数字・ハイフン・下線・ピリオドを使ってください。"
       | Id value <- ids]
  where allowed c = isAlphaNum c || c `elem` ("-_." :: String)

validateLoop :: Beat -> Loop -> [DomainError]
validateLoop lengthBeats settings = check (loopStart settings < 0 || loopEnd settings <= loopStart settings
  || loopEnd settings > lengthBeats) "loop" "interval" "ループの開始と終了を曲の範囲内で指定してください。"

validateTuning :: Tuning -> [DomainError]
validateTuning tuning = concat
  [ check (tuningDivisions tuning < 1 || tuningDivisions tuning > 120) "tuning.divisions" "range" "平均律の分割数は1〜120です。"
  , range "tuning.referenceHz" 300 600 (tuningReferenceHz tuning)
  , range "tuning.root" 0 120 (tuningRoot tuning)
  , check (null scale || length scale > 120 || scale /= sort (nub scale)
       || any (\n -> n < 0 || n >= tuningDivisions tuning) scale)
      "tuning.scale" "scale" "音階は0以上、分割数未満の重複しない昇順ステップで指定してください。"
  ] where scale = tuningScale tuning

validateTrack :: Project -> Track -> [DomainError]
validateTrack project track = concat
  [ range (path <> ".gain") 0 2 (trackGain track), range (path <> ".pan") (-1) 1 (trackPan track)
  , validatePatch (projectTempo project) path (trackPatch track)
  , check (trackInstrument track == Sample && trackAssetId track == Nothing) (path <> ".assetId") "sample-required" "サンプル音色にはWAV素材を選んでください。"
  , check (maybe False (`notElem` map assetId (projectAssets project)) (trackAssetId track)) (path <> ".assetId") "missing-asset" "参照するWAV素材が見つかりません。"
  , check (length parameters /= length (nub parameters)) (path <> ".automation") "duplicate-parameter" "同じパラメーターのオートメーションを一つにまとめてください。"
  , concatMap (validateAutomation (projectLengthBeats project) path) (trackAutomation track)
  ] where path = at "tracks" (trackId track); parameters = map automationParameter (trackAutomation track)

validatePatch :: Double -> Text -> Patch -> [DomainError]
validatePatch tempo path patch = concat
  [ r "attack" 0.001 10 (patchAttack patch), r "release" 0.005 20 (patchRelease patch)
  , r "cutoff" 20 20000 (patchCutoff patch), r "resonance" 0 1 (patchResonance patch)
  , r "tone" 0 1 (patchTone patch), r "delaySend" 0 1 (patchDelaySend patch)
  , r "delayBeats" 0.03125 8 (patchDelayBeats patch)
  , r "delayFeedback" 0 0.92 (patchDelayFeedback patch)
  , check (patchDelayBeats patch * 60 / tempo > 4) (path <> ".patch.delayBeats") "delay-capacity" "ディレイの実時間は4秒以内にしてください。"
  ] where r name = range (path <> ".patch." <> name)

validateAutomation :: Beat -> Text -> Automation -> [DomainError]
validateAutomation lengthBeats path automation =
  check (length points > 4096 || positions /= sort (nub positions)) path "automation-order" "点は重複しない時刻順で4,096個以内にしてください。"
  ++ concat [check (pointBeat p < 0 || pointBeat p > lengthBeats) path "automation-time" "点を曲の範囲内に置いてください。"
    ++ range path lo hi (pointValue p) | p <- points]
  where parameter = automationParameter automation; points = automationPoints automation
        positions = map pointBeat points
        (lo,hi) = case parameter of Pan -> (-1,1); Cutoff -> (20,20000); Gain -> (0,2)

validatePattern :: Pattern -> [DomainError]
validatePattern patternValue =
  check (patternLength patternValue <= 0 || patternLength patternValue > 1024) path "pattern-length" "音型の長さは0より大きく1,024拍以内です。"
  ++ concatMap (validateNote path (patternLength patternValue)) (patternNotes patternValue)
  ++ maybe [] (validateGenerator path) (patternGenerator patternValue)
  ++ check (length (patternTransforms patternValue) > 32) path "transform-capacity" "変形は音型ごとに32個以内です。"
  ++ concatMap (validateTransform path) (patternTransforms patternValue)
  where path = at "patterns" (patternId patternValue)

validateNote :: Text -> Beat -> Note -> [DomainError]
validateNote path lengthBeats note =
  check (noteStart note < 0 || noteDuration note <= 0 || noteStart note + noteDuration note > lengthBeats)
    (path <> ".notes." <> unId (noteId note)) "note-interval" "音符の開始・長さを音型の範囲内にしてください。"
  ++ range (path <> ".pitch") 0 127 (notePitch note)
  ++ range (path <> ".velocity") 0 1 (noteVelocity note)

validateGenerator :: Text -> Generator -> [DomainError]
validateGenerator path generator = concat
  [ check (generatorSteps generator < 1 || generatorSteps generator > 256) path "steps" "ステップ数は1〜256です。"
  , check (generatorPulses generator < 0 || generatorPulses generator > generatorSteps generator) path "pulses" "発音数は0〜ステップ数です。"
  , range (path <> ".root") 0 108 (generatorRoot generator)
  , check (generatorOctaves generator < 1 || generatorOctaves generator > 4) path "octaves" "オクターブ数は1〜4です。"
  , range (path <> ".gate") 0.01 1 (generatorGate generator)
  , range (path <> ".velocity") 0 1 (generatorVelocity generator)
  , check (null degrees || length degrees > 64 || any (\n -> n < -120 || n > 120) degrees) path "degrees" "音階度数は1〜64個、各値は-120〜120です。"
  ] where degrees = generatorDegrees generator

validateTransform :: Text -> Transform -> [DomainError]
validateTransform path transform = case transformKind transform of
  Transpose -> range path (-96) 96 amount
  Rotate -> range path (-4096) 4096 amount
  Reverse -> range path (-4096) 4096 amount
  Stretch -> range path 0.0625 16 amount
  Invert -> range path 0 127 amount
  Probability -> range path 0 1 amount
  where amount = transformAmount transform

validateClip :: Project -> Clip -> [DomainError]
validateClip project clip = concat
  [ check (clipTrackId clip `notElem` map trackId (projectTracks project)) path "missing-track" "配置先のトラックが見つかりません。"
  , check (clipPatternId clip `notElem` map patternId (projectPatterns project)) path "missing-pattern" "配置する音型が見つかりません。"
  , check (clipStart clip < 0 || clipLength clip <= 0 || clipStart clip + clipLength clip > projectLengthBeats project) path "clip-interval" "クリップを曲の範囲内に置いてください。"
  , range (path <> ".transpose") (-96) 96 (clipTranspose clip)
  , range (path <> ".gain") 0 2 (clipGain clip)
  ] where path = at "clips" (clipId clip)

validateResolvedPattern :: ResolvedPattern -> [DomainError]
validateResolvedPattern patternValue = check (resolvedPatternLength patternValue <= 0 || resolvedPatternLength patternValue > 4096)
  "transforms" "transformed-length" "変形後の音型の長さを0より大きく4,096拍以内にしてください。"
  ++ check (length boundedNotes > 32768) "transforms" "pattern-capacity" "変形後の音符は音型ごとに32,768音までです。"
  ++ check (length ids /= Set.size (Set.fromList ids)) "transforms" "resolved-id" "変形した音符IDが重複しました。元の音符IDを変更してください。"
  ++ concatMap (validateNote "transforms" (resolvedPatternLength patternValue)) (resolvedPatternNotes patternValue)
  where boundedNotes = take 32769 (resolvedPatternNotes patternValue); ids = map noteId boundedNotes

validateResolvedNote :: ResolvedNote -> [DomainError]
validateResolvedNote note = range "clips.pitch" 0 127 (resolvedPitch note)
  ++ range "clips.frequency" 8 20000 (resolvedFrequency note)

resolvePattern :: Tuning -> Pattern -> ResolvedPattern
resolvePattern tuning patternValue = foldl' (\current (index,transform) -> applyTransform seed index current transform)
  initial (zip [0 :: Int ..] (patternTransforms patternValue))
  where initial = ResolvedPattern (patternId patternValue) (patternLength patternValue)
          (maybe (patternNotes patternValue) (generateNotes tuning patternValue) (patternGenerator patternValue))
        seed = maybe 0 generatorSeed (patternGenerator patternValue)

generateNotes :: Tuning -> Pattern -> Generator -> [Note]
generateNotes tuning patternValue generator = zipWith makeNote [0 :: Int ..] events
  where
    lengthBeats = patternLength patternValue
    steps = generatorSteps generator
    stepLength = lengthBeats / fromIntegral steps
    degrees = generatorDegrees generator
    scaleSize = length (tuningScale tuning)
    pitches = [degreePitch tuning (generatorRoot generator) (degree + octave * scaleSize)
      | octave <- [0 .. generatorOctaves generator - 1], degree <- degrees]
    cyclicPitch index = case drop (index `mod` max 1 (length pitches)) pitches of p:_ -> p; [] -> generatorRoot generator
    events = case generatorKind generator of
      Euclid -> [(fromIntegral i * stepLength, stepLength * fromDecimal (generatorGate generator),generatorRoot generator)
        | i <- [0 .. steps - 1], ((i - generatorRotation generator) * generatorPulses generator) `mod` steps < generatorPulses generator]
      Arpeggio -> [(fromIntegral i * stepLength,stepLength * fromDecimal (generatorGate generator),cyclicPitch i) | i <- [0 .. steps - 1]]
      Chords ->
        let cell = lengthBeats / fromIntegral (length degrees)
            voicings = voiceLeading tuning (generatorRoot generator) degrees
        in [(fromIntegral i * cell,cell * fromDecimal (generatorGate generator),pitch)
           | (i,chord) <- zip [0 :: Int ..] voicings,pitch <- chord]
    makeNote index (start,duration,pitch) = Note (Id (unId (patternId patternValue) <> ".g" <> text index))
      start duration pitch (generatorVelocity generator)

degreePitch :: Tuning -> Double -> Int -> Double
degreePitch tuning root degree = case tuningScale tuning of
  [] -> root
  scale -> let (octave,index) = degree `divMod` length scale
               step = case drop index scale of value:_ -> value; [] -> 0
           in root + 12 * (fromIntegral octave + fromIntegral step / fromIntegral (tuningDivisions tuning))

frequencyFor :: Tuning -> Double -> Double
frequencyFor tuning pitch = tuningReferenceHz tuning * 2 ** ((pitch - 69) / 12)

voiceLeading :: Tuning -> Double -> [Int] -> [[Double]]
voiceLeading tuning root degrees = case degrees of
  [] -> []
  firstDegree:rest ->
    let firstStates = fmap (\candidate -> (candidate,(registerCost candidate,[candidate]))) (candidates firstDegree)
        finalStates = foldl' advance firstStates rest
    in snd (snd (leastCost (fst . snd) finalStates))
  where
    candidates degree =
      let base = map (degreePitch tuning root . (+ degree)) [0,2,4]
          options = nub [sort (zipWith (+) base shifts) | a <- [-12,0,12],b <- [-12,0,12],c <- [-12,0,12],let shifts=[a,b,c]]
          valid = filter (\ps -> and (zipWith (<) ps (drop 1 ps)) && all (\p -> p >= 0 && p <= 127) ps) options
      in case valid of first:rest -> first :| rest; [] -> base :| []
    registerCost = (* 0.03) . sum . map (\p -> abs (p - root - 7))
    advance previous degree = fmap (\candidate -> (candidate,bestPath candidate previous)) (candidates degree)
    bestPath candidate previous = leastCost fst $ fmap
      (\(before,(cost,path)) -> (cost + sum (zipWith (\a b -> abs (a-b)) before candidate) + registerCost candidate,path ++ [candidate])) previous

leastCost :: (a -> Double) -> NonEmpty a -> a
leastCost cost (first :| rest) = foldl' choose first rest
  where choose best candidate = if cost candidate < cost best then candidate else best

applyTransform :: Int -> Int -> ResolvedPattern -> Transform -> ResolvedPattern
applyTransform seed transformIndex patternValue transform = case transformKind transform of
  Transpose -> mapNotes (\n -> n { notePitch = notePitch n + amount })
  Invert -> mapNotes (\n -> n { notePitch = 2 * amount - notePitch n })
  Reverse -> mapNotes (\n -> n { noteStart = lengthBeats - noteStart n - noteDuration n })
  Stretch -> patternValue { resolvedPatternLength = lengthBeats * factor,
    resolvedPatternNotes = [n { noteStart = noteStart n * factor,noteDuration = noteDuration n * factor } | n <- notes] }
  Rotate -> patternValue { resolvedPatternNotes = concatMap rotateNote notes }
  Probability -> patternValue { resolvedPatternNotes = filter (\n -> randomUnit (unId (noteId n) <> ":" <> text seed) < amount) notes }
  where
    notes = resolvedPatternNotes patternValue; lengthBeats = resolvedPatternLength patternValue
    amount = transformAmount transform; factor = fromDecimal amount
    mapNotes f = patternValue { resolvedPatternNotes = map f notes }
    rotateNote note =
      let start = wrap (noteStart note + factor)
          firstDuration = min (noteDuration note) (lengthBeats - start)
          remaining = noteDuration note - firstDuration
      in note { noteStart = start,noteDuration = firstDuration }
         : [note { noteId = Id (unId (noteId note) <> ".wrap" <> text transformIndex), noteStart = 0,noteDuration = remaining } | remaining > 0]
    wrap value = value - fromInteger (floor (value / lengthBeats)) * lengthBeats

randomUnit :: Text -> Double
randomUnit value = fromIntegral (hash `mod` 1000000) / 1000000
  where hash = Text.foldl' (\acc c -> (acc `xor` fromIntegral (fromEnum c)) * 1099511628211) (1469598103934665603 :: Word64) value

resolveClip :: Tuning -> Map.Map Id ResolvedPattern -> Clip -> [ResolvedNote]
resolveClip tuning patterns clip = case Map.lookup (clipPatternId clip) patterns of
  Nothing -> []
  Just patternValue | null (resolvedPatternNotes patternValue) -> []
  Just patternValue ->
    [ ResolvedNote (Id (unId (clipId clip) <> "/" <> unId (noteId n) <> "/" <> text cycleIndex))
        (clipTrackId clip) (clipId clip) (clipStart clip + localStart)
        (min (noteDuration n) (clipLength clip - localStart)) pitch (frequencyFor tuning pitch)
        (noteVelocity n * clipGain clip)
    | cycleIndex <- [0 .. ceiling (clipLength clip / resolvedPatternLength patternValue) - 1 :: Integer]
    , n <- resolvedPatternNotes patternValue
    , let localStart = fromInteger cycleIndex * resolvedPatternLength patternValue + noteStart n
    , localStart < clipLength clip
    , let pitch = notePitch n + clipTranspose clip
    ]

materialize :: Project -> Id -> Either [DomainError] Compilation
materialize project target = do
  compilation <- compileProject project
  case filter ((== target) . resolvedPatternId) (resolvedPatterns (compiledResolved compilation)) of
    [] -> Left (problem "patternId" "missing-pattern" "確定する音型が見つかりません。")
    resolved:_ -> compileProject project { projectPatterns = map (replace resolved) (projectPatterns project) }
  where replace resolved patternValue
          | patternId patternValue == target = patternValue { patternLength = resolvedPatternLength resolved,
              patternNotes = resolvedPatternNotes resolved,patternGenerator = Nothing,patternTransforms = [] }
          | otherwise = patternValue
