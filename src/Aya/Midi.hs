{-# LANGUAGE OverloadedStrings #-}
module Aya.Midi (importMidi, exportMidi) where

import Aya.Compile
import Aya.Project
import Control.Monad (foldM, unless, when)
import Data.Binary.Get hiding (label, remaining)
import Data.Binary.Put
import Data.Bits
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.List (nub, sortOn)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Text.Encoding.Error (lenientDecode)
import Data.Word

type Tick = Integer
data Message = On Int Int Int | Off Int Int | Tempo Int | Program Int Int
  | Bend Int Int | Control Int Int Int | TrackName Text | Ignored
  deriving (Eq,Show)
data Event = Event { eventTick :: Tick,eventTrack :: Int,eventOrder :: Int,eventMessage :: Message }
  deriving (Eq,Show)

readMidi :: Get (Int,[Event])
readMidi = do
  header <- getByteString 4; unless (header == "MThd") (fail "MThd header required")
  size <- getWord32be; unless (size >= 6 && size <= 1024) (fail "Invalid MIDI header size")
  format <- getWord16be; unless (format <= 1) (fail "Only SMF type 0 and type 1 are supported")
  tracks <- getWord16be; when (tracks == 0 || tracks > 256 || format == 0 && tracks /= 1) (fail "Invalid MIDI track count")
  division <- getWord16be; when (division == 0 || testBit division 15) (fail "SMPTE time division is not supported; use PPQN")
  skip (fromIntegral size - 6)
  chunks <- forMIndexed (fromIntegral tracks) $ \index -> do
    label <- getByteString 4; unless (label == "MTrk") (fail "MTrk chunk required")
    bytes <- getWord32be; when (bytes > 8*1024*1024) (fail "MIDI track exceeds 8 MiB")
    content <- getLazyByteString (fromIntegral bytes)
    case runGetOrFail (readTrack index) content of
      Left (_,_,message) -> fail message
      Right (_,_,events) -> pure events
  remaining <- isEmpty; unless remaining (fail "Unexpected bytes after MIDI tracks")
  pure (fromIntegral division,sortOn (\e -> (eventTick e,eventTrack e,eventOrder e)) (concat chunks))
  where forMIndexed count action = mapM action [0 .. count - 1]

readTrack :: Int -> Get [Event]
readTrack track = go 0 Nothing 0
  where
    go tick running count = do
      empty <- isEmpty
      if empty then pure [] else do
        when (count > 100000) (fail "MIDI event capacity exceeded")
        delta <- variableLength
        firstByte <- getWord8
        (status,firstData) <- if firstByte < 0x80
          then case running of Nothing -> fail "Running status without a channel message"; Just status -> pure (status,Just firstByte)
          else pure (firstByte,Nothing)
        let nextTick = tick + fromIntegral delta; channel = fromIntegral (status .&. 15)
            dataByte = case firstData of Just value -> pure value; Nothing -> sevenBit
            next message nextRunning = (Event nextTick track count message :) <$> go nextTick nextRunning (count+1)
        case status .&. 0xf0 of
          0x80 -> do key <- dataByte; _ <- sevenBit; next (Off channel (fromIntegral key)) (Just status)
          0x90 -> do key <- dataByte; velocity <- sevenBit
                     next (if velocity == 0 then Off channel (fromIntegral key) else On channel (fromIntegral key) (fromIntegral velocity)) (Just status)
          0xa0 -> dataByte >> sevenBit >> next Ignored (Just status)
          0xb0 -> do parameter <- dataByte; value <- sevenBit; next (Control channel (fromIntegral parameter) (fromIntegral value)) (Just status)
          0xc0 -> do program <- dataByte; next (Program channel (fromIntegral program)) (Just status)
          0xd0 -> dataByte >> next Ignored (Just status)
          0xe0 -> do low <- dataByte; high <- sevenBit; next (Bend channel (fromIntegral low + 128 * fromIntegral high)) (Just status)
          _ | status == 0xff -> do
                kind <- getWord8; size <- variableLength
                when (size > 1024*1024) (fail "MIDI meta-event exceeds 1 MiB")
                payload <- getByteString size
                let message = case kind of
                      0x51 | BS.length payload == 3 -> Tempo (BS.foldl' (\a b -> a*256 + fromIntegral b) 0 payload)
                      0x03 -> TrackName (Text.decodeUtf8With lenientDecode payload)
                      _ -> Ignored
                if kind == 0x2f then pure [Event nextTick track count Ignored] else next message Nothing
            | status == 0xf0 || status == 0xf7 -> do size <- variableLength; skip size; next Ignored Nothing
            | otherwise -> fail "Unsupported MIDI system event"
    sevenBit = do value <- getWord8; when (value > 127) (fail "Invalid MIDI data byte"); pure value

variableLength :: Get Int
variableLength = go 0 0
  where go count value = do
          when (count >= (4 :: Int)) (fail "MIDI variable-length value exceeds four bytes")
          byte <- getWord8
          let result = value * 128 + fromIntegral (byte .&. 127)
          if testBit byte 7 then go (count+1) result else pure result

data Channel = Channel { channelProgram :: Int,channelBend :: Int,channelRange :: Double
  , channelSustain :: Bool,channelRpnMSB :: Int,channelRpnLSB :: Int }
  deriving (Eq,Show)
defaultChannel :: Channel
defaultChannel = Channel 0 8192 2 False 127 127
data OpenNote = OpenNote { openChannel :: Int,openKey :: Int,openTick :: Tick,openTrack :: Int
  , openPitch :: Double,openVelocity :: Double,openInstrument :: Instrument,openReleased :: Bool }
  deriving (Eq,Show)
data Finished = Finished OpenNote Tick deriving (Eq,Show)
data ImportState = ImportState { channels :: Map.Map Int Channel,openNotes :: [OpenNote],finishedNotes :: [Finished],importWarnings :: [Text] }

importMidi :: Text -> BS.ByteString -> Either [DomainError] (Project,[Text])
importMidi name bytes
  | BS.length bytes > 8*1024*1024 = Left (problem "midi" "capacity" "MIDIファイルは8 MiBまでです。")
  | otherwise = case runGetOrFail readMidi (LBS.fromStrict bytes) of
      Left (_,_,message) -> Left (problem "midi" "midi-format" (Text.pack message))
      Right (_,_,(division,events)) -> do
        let tempoEvents = [(eventTick e,us) | e <- events,Tempo us <- [eventMessage e]]
            initialTempo = case [us | (tick,us) <- tempoEvents,tick == 0,us > 0] of us:_ -> us; [] -> 500000
            tempo = 60000000 / fromIntegral initialTempo
            state = foldl' importEvent (ImportState Map.empty [] [] []) events
            endTick = maximum (fromIntegral division : map eventTick events)
            completed = finishedNotes state ++ [Finished note (max endTick (openTick note + 1)) | note <- openNotes state]
            time tick = beat (tickMicros division tempoEvents tick / fromIntegral initialTempo)
            groups = nub [(openTrack note,openChannel note,openInstrument note) | Finished note _ <- completed]
            lengthBeats = max 4 (fromInteger (ceiling (maximum (0 : [time end | Finished _ end <- completed]) / 4)) * 4)
            groupNotes group = [Note (Id ("midi-note-" <> number index)) (time (openTick note)) (time end - time (openTick note)) (openPitch note) (openVelocity note)
              | (index,Finished note end) <- zip [0 :: Int ..] completed,(openTrack note,openChannel note,openInstrument note) == group]
            sourceName source = case [value | e <- events,eventTrack e == source,TrackName value <- [eventMessage e],not (Text.null value)] of
              value:_ -> Text.take 100 value; [] -> "MIDI " <> number (source+1)
            track index (source,_,instrument) = (defaultTrack (Id ("midi-track-" <> number index)) (sourceName source) instrument) {trackGain=0.6}
            patternValue index group = Pattern (Id ("midi-pattern-" <> number index)) ("取込音型 " <> number (index+1)) lengthBeats (groupNotes group) Nothing []
            clip index _ = Clip (Id ("midi-clip-" <> number index)) (Id ("midi-track-" <> number index)) (Id ("midi-pattern-" <> number index)) 0 lengthBeats 0 1
            project = emptyProject {projectId=Id "midi-import-project",projectName=Text.take 200 (if Text.null name then "MIDI取込み" else name),projectTempo=tempo,
              projectLengthBeats=lengthBeats,projectLoop=Loop False 0 (min 16 lengthBeats),projectTracks=zipWith track [0 :: Int ..] groups,
              projectPatterns=zipWith patternValue [0 :: Int ..] groups,projectClips=zipWith clip [0 :: Int ..] groups}
            warnings = nub ("MIDI音色はAyaの内蔵音色へ近い種類で割り当てます。音色・ミックス・SysEx・圧力情報の完全な再現ではありません。"
              : importWarnings state ++ ["テンポ変更を発音の実時間に展開しました。Ayaでは一定テンポの拍位置として編集できます。" | length (nub (map snd tempoEvents)) > 1]
              ++ ["終端まで離鍵のない音は、ファイル終端で離鍵しました。" | not (null (openNotes state))])
        unless (all ((>0) . sndTempo) tempoEvents) (Left (problem "midi.tempo" "tempo" "0のテンポを含むMIDIは読み込めません。"))
        _ <- compileProject project
        pure (project,warnings)
  where sndTempo = snd

number :: Show a => a -> Text
number = Text.pack . show

tickMicros :: Int -> [(Tick,Int)] -> Tick -> Rational
tickMicros division changes target = advance 0 500000 0 (sortOn fst changes)
  where
    advance previous tempo elapsed [] = elapsed + fromInteger (target-previous) * fromIntegral tempo / fromIntegral division
    advance previous tempo elapsed ((position,nextTempo):rest)
      | position > target = elapsed + fromInteger (target-previous) * fromIntegral tempo / fromIntegral division
      | otherwise = advance position nextTempo (elapsed + fromInteger (position-previous) * fromIntegral tempo / fromIntegral division) rest

importEvent :: ImportState -> Event -> ImportState
importEvent state event = case eventMessage event of
  On channel key velocity ->
    let current = channelAt channel
        pitch = fromIntegral key + fromIntegral (channelBend current - 8192) / 8192 * channelRange current
        instrument = if channel == 9 then drumInstrument key else gmInstrument (channelProgram current)
        note = OpenNote channel key (eventTick event) (eventTrack event) pitch (fromIntegral velocity / 127) instrument False
    in state {openNotes=openNotes state ++ [note]}
  Off channel key -> releaseOne channel key
  Program channel program -> update channel (\current -> current {channelProgram=program})
  Bend channel value -> (update channel (\current -> current {channelBend=value}))
    {importWarnings=importWarnings state ++ ["発音中のピッチベンドは発音開始時の音高へ固定しました。連続ベンドはWAVで受け渡してください。" | any ((==channel) . openChannel) (openNotes state)]}
  Control channel parameter value -> case parameter of
    64 -> let updated = update channel (\current -> current {channelSustain=value >= 64})
          in if value >= 64 then updated else releaseHeld channel updated
    101 -> update channel (\current -> current {channelRpnMSB=value})
    100 -> update channel (\current -> current {channelRpnLSB=value})
    6 | channelRpnMSB (channelAt channel) == 0 && channelRpnLSB (channelAt channel) == 0 -> update channel (\current -> current {channelRange=fromIntegral value})
    38 | channelRpnMSB (channelAt channel) == 0 && channelRpnLSB (channelAt channel) == 0 -> update channel (\current -> current {channelRange=fromIntegral (floor (channelRange current) :: Int) + fromIntegral value/100})
    120 -> releaseAll channel
    123 -> releaseAll channel
    _ -> state
  _ -> state
  where
    channelAt channel = Map.findWithDefault defaultChannel channel (channels state)
    update channel f = state {channels=Map.insert channel (f (channelAt channel)) (channels state)}
    releaseOne channel key =
      let matches note = openChannel note == channel && openKey note == key && not (openReleased note)
          (before,after) = break matches (openNotes state)
      in case after of
        [] -> state
        note:rest | channelSustain (channelAt channel) -> state {openNotes=before ++ [note {openReleased=True}] ++ rest}
                  | otherwise -> state {openNotes=before ++ rest,finishedNotes=Finished note (eventTick event):finishedNotes state}
    releaseHeld channel current =
      let held note = openChannel note == channel && openReleased note
      in current {openNotes=filter (not . held) (openNotes current),finishedNotes=[Finished note (eventTick event) | note <- openNotes current,held note] ++ finishedNotes current}
    releaseAll channel = state {openNotes=filter ((/=channel) . openChannel) (openNotes state),
      finishedNotes=[Finished note (eventTick event) | note <- openNotes state,openChannel note == channel] ++ finishedNotes state}

gmInstrument :: Int -> Instrument
gmInstrument program | program >= 32 && program <= 39 = Bass
                     | program >= 88 && program <= 95 = Pad
                     | program >= 80 && program <= 87 = Lead
                     | program >= 8 && program <= 15 = Bell
                     | otherwise = Pluck
drumInstrument :: Int -> Instrument
drumInstrument key | key `elem` [35,36] = Kick | key `elem` [38,40] = Snare | otherwise = Hat

data MidiOut = MidiOut Integer Int [Word8] deriving (Eq,Show)

exportMidi :: Compilation -> Either [DomainError] (BS.ByteString,[Text])
exportMidi compilation = do
  (_,events) <- foldM allocate ([],[]) audible
  let tempo = round (60000000 / projectTempo project) :: Int
      initial = MidiOut 0 0 ([0xff,0x51,3] ++ bytes24 tempo)
        : [MidiOut 0 0 [0xb0+fromIntegral channel,parameter,value]
          | channel <- [0..15 :: Int],channel /= 9,(parameter,value) <- [(101,0),(100,0),(6,2),(38,0),(101,127),(100,127)]]
      ordered = sortOn (\(MidiOut position order _) -> (position,order)) (initial ++ events)
      content = runPut (writeEvents 0 ordered >> putWord8 0 >> putByteString "\xff\x2f\x00")
      file = runPut $ do putByteString "MThd"; putWord32be 6; putWord16be 0; putWord16be 1; putWord16be 960
                         putByteString "MTrk"; putWord32be (fromIntegral (LBS.length content)); putLazyByteString content
      warnings = ["SMF type 0、960 PPQNで書き出します。音色はGM近似です。ミックス・エフェクト・素材音声・オートメーションはWAVに含めてください。",
        "微分音は音ごとのMIDIチャンネルと±2半音のピッチベンドで保持します。受信側のRPN対応が必要で、同時に15の旋律声までです。"]
        ++ ["1を超えるクリップ強度はMIDIの最大ベロシティへ変換しました。WAVは元の強度を保持します。" | any ((>1) . resolvedVelocity) audible]
  pure (LBS.toStrict file,warnings)
  where
    project = compiledProject compilation
    table = Map.fromList [(trackId track,track) | track <- projectTracks project]
    solo = any trackSolo (projectTracks project)
    audible = [note | note <- resolvedNotes (compiledResolved compilation),Just track <- [Map.lookup (resolvedTrackId note) table],
      not (trackMute track),not solo || trackSolo track,resolvedVelocity note > 0]
    tick position = round (toRational position * 960)
    allocate (active,events) note = do
      let track = Map.lookup (resolvedTrackId note) table
          instrument = maybe Pluck trackInstrument track
          percussion = instrument `elem` [Kick,Snare,Hat]
          start = tick (resolvedStart note); end = tick (resolvedStart note + resolvedDuration note)
          continuing = filter (\(_,untilTick) -> untilTick > start) active
          free = [channel | channel <- [0..15 :: Int],channel /= 9,channel `notElem` map fst continuing]
          pitch = resolvedPitch note + 12 * logBase 2 (tuningReferenceHz (projectTuning project) / 440)
          key = if percussion then percussionKey instrument else round pitch
          bend = round (8192 + (pitch - fromIntegral key) / 2 * 8192) :: Int
          velocity = max 1 (round (min 1 (resolvedVelocity note) * 127)) :: Int
      when (end <= start) (Left (problem "midi.notes" "midi-resolution" "960 PPQNより短い音符があります。WAV書出しを使うか長さを伸ばしてください。"))
      when (key < 0 || key > 127) (Left (problem "midi.pitch" "midi-range" "基準周波数を含めた音高がMIDIの範囲を超えます。WAV書出しを使ってください。"))
      channel <- if percussion then Right 9 else case free of
        value:_ -> Right value
        [] -> Left (problem "midi.voices" "midi-channels" "同時に15を超える旋律声があります。音ごとの微分音を保持するにはWAVかステムで書き出してください。")
      let c = fromIntegral channel; k = fromIntegral key
          setup = if percussion then [] else [MidiOut start 1 [0xc0+c,programFor instrument],
            MidiOut start 2 [0xe0+c,fromIntegral (bend .&. 127),fromIntegral ((bend `shiftR` 7) .&. 127)]]
          messages = setup ++ [MidiOut start 3 [0x90+c,k,fromIntegral velocity],MidiOut end 0 [0x80+c,k,0]]
      pure (if percussion then continuing else (channel,end):continuing,events ++ messages)

programFor :: Instrument -> Word8
programFor instrument = case instrument of
  Bass -> 38; Pad -> 89; Bell -> 10; Lead -> 81; Pluck -> 24; Sample -> 24
  Kick -> 0; Snare -> 0; Hat -> 0

percussionKey :: Instrument -> Int
percussionKey instrument = case instrument of
  Kick -> 36; Snare -> 38; Hat -> 42
  Bass -> 36; Pad -> 60; Bell -> 72; Lead -> 72; Pluck -> 60; Sample -> 60

bytes24 :: Int -> [Word8]
bytes24 value = map (fromIntegral . (.&.255) . shiftR value) [16,8,0]

writeEvents :: Integer -> [MidiOut] -> Put
writeEvents _ [] = pure ()
writeEvents previous (MidiOut tick _ bytes:rest) = do
  putVariable (fromIntegral (tick-previous)); mapM_ putWord8 bytes; writeEvents tick rest

putVariable :: Int -> Put
putVariable value = mapM_ putWord8 (mark (reverse (digits value)))
  where digits n | n < 128 = [fromIntegral n] | otherwise = fromIntegral (n .&.127) : digits (n `shiftR`7)
        mark [] = []; mark [x] = [x]; mark (x:xs) = (x .|.128):mark xs
