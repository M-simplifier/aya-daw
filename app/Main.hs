{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main (main) where

import Aya.Compile
import Aya.EnginePlan
import Aya.Example
import Aya.Project
import qualified Aya.Audio as Audio
import qualified Aya.Midi as Midi
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (IOException, bracket, catch, displayException, try)
import Control.Monad (forM, void)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as Base64
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as LBS
import Data.IORef
import Data.List (sort)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Types
import Network.Socket hiding (shutdown)
import Network.Wai
import qualified Network.Wai.Handler.Warp as Warp
import System.Directory
import System.Environment (getArgs, getExecutablePath)
import System.FilePath
import System.IO (hFlush, stdout)
import System.Exit (exitFailure)
import Text.Read (readMaybe)

data Session = Session
  { sessionRoot :: FilePath, sessionOrigin :: BS.ByteString
  , sessionEngine :: Maybe Audio.Engine, sessionEngineFailure :: Text
  , sessionCompilation :: MVar Compilation, sessionMutation :: MVar ()
  , sessionExport :: MVar (), sessionCounter :: IORef Int, sessionToken :: String
  , sessionShutdown :: MVar (IO ())
  }

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--audio-worker",name] -> Audio.runAudioWorker name
    ["--audio-self-test",path] -> Audio.runAudioSelfTest path >>= reportDiagnostic
    ["--audio-device-test",path] -> Audio.runAudioDeviceTest path >>= reportDiagnostic
    ["--write-examples"] -> do
      createDirectoryIfMissing True "examples"
      LBS.writeFile "examples/glass-tides.aya.json" (encode exampleProject)
      LBS.writeFile "examples/empty.aya.json" (encode emptyProject)
    _ -> runServer arguments

reportDiagnostic :: Either Audio.AudioError Text -> IO ()
reportDiagnostic result = case result of
  Left (Audio.AudioError message) -> putStrLn (Text.unpack message) >> exitFailure
  Right message -> putStrLn (Text.unpack message)

runServer :: [String] -> IO ()
runServer arguments = withSocketsDo $ do
  root <- locateRoot arguments
  createDirectoryIfMissing True (root </> ".work")
  initial <- recoverProject root
  case compileAndPlan initial of
    Left errors -> ioError (userError (show errors))
    Right (compilation,plan) -> bracket Audio.startEngine (either (const (pure ())) Audio.closeEngine) $ \started -> do
      let (engine,failure) = case started of Left (Audio.AudioError message) -> (Nothing,message); Right value -> (Just value,"")
      case engine of Nothing -> pure (); Just value -> void (Audio.setPlan value plan)
      accepted <- newMVar compilation
      mutation <- newMVar (); exports <- newMVar (); counter <- newIORef 0; shutdown <- newEmptyMVar
      token <- show . (round :: Double -> Integer) . (* 1000000) . realToFrac <$> getPOSIXTime
      bracket (openLoopback (requestedPort arguments)) (close . fst) $ \(socketValue,port) -> do
        let origin = BSC.pack ("http://127.0.0.1:" <> show port)
            session = Session root origin engine failure accepted mutation exports counter token shutdown
            settings = Warp.setPort port . Warp.setHost "127.0.0.1" . Warp.setTimeout 120
              . Warp.setGracefulShutdownTimeout (Just 1)
              . Warp.setInstallShutdownHandler (putMVar shutdown) $ Warp.defaultSettings
        atomicWrite (root </> ".work" </> "endpoint.json") (encode (object ["url" .= Text.decodeUtf8 origin,"version" .= ("0.1.0" :: Text)]))
        putStrLn (BSC.unpack origin); hFlush stdout
        Warp.runSettingsSocket settings socketValue (application session)

requestedPort :: [String] -> Int
requestedPort ("--port":value:rest) = fromMaybe (requestedPort rest) (readMaybe value >>= \n -> if n >= 0 && n < 65536 then Just n else Nothing)
requestedPort (_:rest) = requestedPort rest
requestedPort [] = 0

locateRoot :: [String] -> IO FilePath
locateRoot arguments = do
  current <- getCurrentDirectory; executable <- takeDirectory <$> getExecutablePath
  let explicit = case dropWhile (/= "--root") arguments of _:path:_ -> Just path; _ -> Nothing
      choices = maybe [] pure explicit ++ [current,executable]
  existing <- filterMDirectory choices
  case existing of root:_ -> canonicalizePath root; [] -> ioError (userError "Ayaのwebフォルダーが見つかりません。Launch.cmdから起動してください。")
  where filterMDirectory [] = pure []
        filterMDirectory (path:rest) = do yes <- doesDirectoryExist (path </> "web"); others <- filterMDirectory rest; pure ([path | yes] ++ others)

openLoopback :: Int -> IO (Socket,Int)
openLoopback port = do
  socketValue <- socket AF_INET Stream defaultProtocol
  bind socketValue (SockAddrInet (fromIntegral port) (tupleToHostAddress (127,0,0,1)))
  listen socketValue 16
  address <- getSocketName socketValue
  case address of SockAddrInet actual _ -> pure (socketValue,fromIntegral actual); _ -> close socketValue >> ioError (userError "IPv4 loopback unavailable")

recoverProject :: FilePath -> IO Project
recoverProject root = do
  let path = root </> ".work" </> "recovery.aya.json"
  exists <- doesFileExist path
  if not exists then pure exampleProject else do
    result <- try (LBS.readFile path) :: IO (Either IOException LBS.ByteString)
    pure $ case result >>= \bytes -> either (Left . userError) Right (eitherDecode bytes) of
      Right project | Right _ <- compileAndPlan project -> project
      _ -> exampleProject

compileAndPlan :: Project -> Either [DomainError] (Compilation, Audio.AudioPlan)
compileAndPlan project = do compilation <- compileProject project; plan <- toAudioPlan compilation; pure (compilation,plan)

application :: Session -> Application
application session request respond = do
  let host = "127.0.0.1:" <> BSC.drop (BS.length "http://127.0.0.1:") (sessionOrigin session)
      origin = lookup "Origin" (requestHeaders request)
      foreignOrigin = maybe False (/= sessionOrigin session) origin
      crossSite = lookup "Sec-Fetch-Site" (requestHeaders request) == Just "cross-site"
      apiRequest = case pathInfo request of "api":_ -> True; _ -> False
  if requestHeaderHost request /= Just host || apiRequest && (foreignOrigin || crossSite)
    then respond (errorsResponse status403 (problem "request" "origin" "Ayaを開いたローカル画面から操作してください。"))
    else do
      result <- route session request `catch` \(exception :: IOException) ->
        pure (errorsResponse status500 (problem "io" "io" ("処理を完了できませんでした: " <> Text.pack (displayException exception))))
      respond (mapResponseHeaders (++ securityHeaders) result)

securityHeaders :: ResponseHeaders
securityHeaders = [("Cache-Control","no-store"),("X-Content-Type-Options","nosniff"),
  ("Content-Security-Policy","default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'")]

route :: Session -> Request -> IO Response
route session request = case (requestMethod request,pathInfo request) of
  ("GET",["api","bootstrap"]) -> do
    compilation <- readMVar (sessionCompilation session); statusValue <- status session
    pure (json status200 (object ["project" .= compiledProject compilation,"resolved" .= compiledResolved compilation,
      "instruments" .= [object ["id" .= ident,"name" .= name] | (ident,name) <- instrumentNames],
      "engine" .= statusValue,"version" .= ("0.1.0" :: Text),
      "capabilities" .= object ["midi" .= True,"keyboardGate" .= True]]))
  ("GET",["api","example"]) -> pure (json status200 exampleProject)
  ("GET",["api","empty"]) -> pure (json status200 emptyProject)
  ("GET",["api","status"]) -> do
    compilation <- readMVar (sessionCompilation session)
    case sessionEngine session of
      Nothing -> do engineStatus <- status session; pure (json status200 (object ["playing" .= False,"beat" .= (0 :: Double),"peakL" .= (0 :: Double),"peakR" .= (0 :: Double),"engine" .= engineStatus]))
      Just engine -> do
        value <- Audio.readEngineStatus engine
        pure (json status200 (object ["playing" .= Audio.enginePlaying value,
          "beat" .= frameBeat (projectTempo (compiledProject compilation)) (Audio.engineFrame value),
          "peakL" .= Audio.enginePeakL value,"peakR" .= Audio.enginePeakR value,"engine" .= engineJSON value]))
  ("POST",["api","compile"]) -> withJSON request $ \project -> acceptProject session project
  ("POST",["api","materialize"]) -> withJSON request $ \value -> case parseEither materializeRequest value of
    Left message -> pure (parseFailure message)
    Right (project,target) -> case materialize project target of
      Left errors -> pure (errorsResponse status422 errors)
      Right compilation -> acceptProject session (compiledProject compilation)
  ("POST",["api","transport"]) -> withJSON request $ \value -> withMVar (sessionMutation session) $ \() -> do
    compilation <- readMVar (sessionCompilation session)
    let project = compiledProject compilation
    case parseEither transportRequest value of
      Left message -> pure (parseFailure message)
      Right (action,position) ->
        if not (validFinite position) || position < 0 || position > beats (projectLengthBeats project)
          then pure (errorsResponse status422 (problem "beat" "seek-range" "移動先を曲の範囲内にしてください。"))
          else case lookup action [("play",Audio.Play),("pause",Audio.Pause),("stop",Audio.Stop),("seek",Audio.Seek (beatFrame (projectTempo project) (fromDecimal position)))] of
            Nothing -> pure (errorsResponse status422 (problem "action" "transport" "再生操作が見つかりません。"))
            Just command -> engineOperation session (\engine -> Audio.sendTransport engine command)
  ("POST",["api","audition"]) -> withJSON request $ \value -> case fromJSON value of
    Error message -> pure (parseFailure message)
    Success event -> sendInput session [event]
  ("POST",["api","input-events"]) -> withJSON request $ \value -> case parseEither (withObject "input events" (.: "events")) value of
    Left message -> pure (parseFailure message)
    Right events -> sendInput session events
  ("POST",["api","panic"]) -> engineOperation session Audio.panic
  ("POST",["api","assets","wav"]) -> withJSON request $ \value -> case parseEither assetRequest value of
    Left message -> pure (parseFailure message)
    Right (name,encoded) -> case Base64.decode (Text.encodeUtf8 encoded) of
      Left message -> pure (parseFailure message)
      Right bytes -> do
        ident <- nextId session "asset"
        pure $ case assetFromWave (Id (Text.pack ident)) name bytes of
          Left errors -> errorsResponse status422 errors; Right asset -> json status200 asset
  ("POST",["api","export"]) -> withJSON request $ \value -> case parseEither exportRequest value of
    Left message -> pure (parseFailure message)
    Right (project,stems) -> exportAudio session project stems
  ("POST",["api","midi","import"]) -> withJSON request $ \value -> case parseEither assetRequest value of
    Left message -> pure (parseFailure message)
    Right (name,encoded) -> case Base64.decode (Text.encodeUtf8 encoded) of
      Left message -> pure (parseFailure message)
      Right bytes -> pure $ case Midi.importMidi name bytes of
        Left errors -> errorsResponse status422 errors
        Right (project,warnings) -> json status200 (object ["project" .= project,"warnings" .= warnings])
  ("POST",["api","midi","export"]) -> withJSON request $ \project -> case compileProject project >>= Midi.exportMidi of
    Left errors -> pure (errorsResponse status422 errors)
    Right (bytes,warnings) -> do
      directoryName <- nextId session "midi"
      let directory = sessionRoot session </> ".work" </> "exports" </> directoryName
      createDirectoryIfMissing True directory; BS.writeFile (directory </> "composition.mid") bytes
      pure (json status200 (object ["files" .= [object ["name" .= ("composition.mid" :: Text),"url" .= ("/exports/" <> Text.pack directoryName <> "/composition.mid")]],"warnings" .= warnings]))
  ("GET",["api","recovery"]) -> do
    let path = sessionRoot session </> ".work" </> "recovery.aya.json"
    exists <- doesFileExist path
    if not exists then pure (json status200 Null) else do bytes <- LBS.readFile path; pure (responseLBS status200 [(hContentType,"application/json; charset=utf-8")] bytes)
  ("POST",["api","recovery"]) -> withJSON request $ \project -> case compileAndPlan project of
    Left errors -> pure (errorsResponse status422 errors)
    Right _ -> withMVar (sessionMutation session) $ \() -> do
      atomicWrite (sessionRoot session </> ".work" </> "recovery.aya.json") (encode project)
      pure (json status200 (object ["saved" .= True]))
  ("POST",["api","shutdown"]) -> do
    void (forkIO (threadDelay 250000 >> readMVar (sessionShutdown session) >>= id))
    pure (json status200 (object ["closing" .= True]))
  ("GET",["exports",directory,name]) | safePart directory && safePart name && takeExtension (Text.unpack name) `elem` [".wav",".mid"] ->
    serveFile (sessionRoot session </> ".work" </> "exports" </> Text.unpack directory </> Text.unpack name)
      [(hContentType,if takeExtension (Text.unpack name) == ".mid" then "audio/midi" else "audio/wav"),("Content-Disposition","attachment; filename=\"" <> Text.encodeUtf8 name <> "\"")]
  ("GET",segments) | all safePart segments ->
    let relative = if null segments then "index.html" else joinPath (map Text.unpack segments)
    in if takeExtension relative `elem` [".html",".js",".css",".svg",".png",".ico",".woff2"]
      then serveFile (sessionRoot session </> "web" </> relative) [(hContentType,mime relative)]
      else pure (errorsResponse status404 (problem "path" "not-found" "このページはありません。"))
  _ -> pure (errorsResponse status404 (problem "path" "not-found" "この操作はありません。"))

acceptProject :: Session -> Project -> IO Response
acceptProject session project = case compileAndPlan project of
  Left errors -> pure (errorsResponse status422 errors)
  Right (compilation,plan) -> withMVar (sessionMutation session) $ \() -> do
    result <- case sessionEngine session of Nothing -> pure (Right ()); Just engine -> Audio.setPlan engine plan
    case result of
      Left (Audio.AudioError message) -> pure (errorsResponse status503 (problem "engine" "plan-rejected" message))
      Right () -> do
        void (swapMVar (sessionCompilation session) compilation)
        pure (json status200 (object ["project" .= project,"resolved" .= compiledResolved compilation,
          "warnings" .= (["音声デバイスへ接続できていません。編集とWAV書出しは使えます。" :: Text | Nothing <- [sessionEngine session]])]))

exportAudio :: Session -> Project -> Bool -> IO Response
exportAudio session project stems = case compileAndPlan project of
  Left errors -> pure (errorsResponse status422 errors)
  Right (_,plan) -> withMVar (sessionExport session) $ \() -> do
    directoryName <- nextId session "render"
    let directory = sessionRoot session </> ".work" </> "exports" </> directoryName
        outputs = ("mix.wav",Nothing) : [("track-" <> show i <> ".wav",Just (unId (trackId track)))
          | stems,(i,track) <- zip [1 :: Int ..] (projectTracks project)]
    createDirectoryIfMissing True directory
    results <- forM outputs $ \(name,stem) -> do
      result <- Audio.renderWav (directory </> name) plan stem
      case result of
        Left failure -> pure (Left failure)
        Right report -> do
          size <- getFileSize (directory </> name)
          pure $ if size > 44 then Right (name,report) else Left (Audio.AudioError "WAV書出しが空になりました。")
    case sequence results of
      Left (Audio.AudioError message) -> pure (errorsResponse status500 (problem "export" "render" message))
      Right reports -> pure (json status200 (object ["files" .=
        [object ["name" .= name,"url" .= ("/exports/" <> directoryName <> "/" <> name),"peak" .= Audio.renderPeak report,
          "clippedSamples" .= Audio.renderClippedSamples report] | (name,report) <- reports],
        "duration" .= maximum (0 : map (Audio.renderDuration . snd) reports)]))

data InputEvent = InputEvent
  { inputKind :: Text, inputEventId :: Text, inputTrackId :: Id, inputPitch :: Double
  , inputVelocity :: Double, inputDuration :: Double, inputTimestamp :: Maybe Double, inputSequence :: Maybe Int
  } deriving (Show)
instance FromJSON InputEvent where
  parseJSON = withObject "keyboard event" $ \o -> InputEvent <$> o .:? "kind" .!= "note"
    <*> o .:? "eventId" .!= "audition" <*> o .:? "trackId" .!= Id ""
    <*> o .:? "pitch" .!= 60 <*> o .:? "velocity" .!= 0.8 <*> o .:? "duration" .!= 0.2
    <*> o .:? "timestampMs" <*> o .:? "sequence"

sendInput :: Session -> [InputEvent] -> IO Response
sendInput session events = withMVar (sessionMutation session) $ \() -> do
  compilation <- readMVar (sessionCompilation session)
  let project = compiledProject compilation
      sequenceValues = [n | event <- events,Just n <- [inputSequence event]]
      errors = [DomainError "events" "event-capacity" "一度の入力は256イベントまでです。" | length events > 256]
        ++ [DomainError "events" "event-order" "入力イベントを順序番号の昇順で送ってください。" | sequenceValues /= sort sequenceValues]
        ++ concatMap (validateInput project) events
  if not (null errors) then pure (errorsResponse status422 errors) else case sessionEngine session of
    Nothing -> engineUnavailable session
    Just engine -> do
      results <- forM events $ \event -> case inputKind event of
        "off" -> Audio.releaseAudition engine (inputEventId event)
        "on" -> Audio.auditionKey engine (inputEventId event) (unId (inputTrackId event))
          (frequencyFor (projectTuning project) (inputPitch event)) (inputVelocity event)
        _ -> Audio.audition engine (unId (inputTrackId event)) (frequencyFor (projectTuning project) (inputPitch event)) (inputVelocity event) (inputDuration event)
      case sequence results of
        Left (Audio.AudioError message) -> pure (errorsResponse status503 (problem "input" "input-queue" message))
        Right _ -> pure (json status200 (object ["accepted" .= length events,"timing" .= ("next-audio-block" :: Text)]))

validateInput :: Project -> InputEvent -> [DomainError]
validateInput project event = concat
  [ [DomainError "eventId" "event-id" "発音IDは1〜96文字です。" | Text.null (inputEventId event) || Text.length (inputEventId event) > 96]
  , [DomainError "kind" "event-kind" "入力種類はon・off・noteです。" | inputKind event `notElem` ["on","off","note"]]
  , [DomainError "trackId" "missing-track" "演奏するトラックがありません。" | inputKind event /= "off" && inputTrackId event `notElem` map trackId (projectTracks project)]
  , [DomainError "pitch" "pitch" "音高は0〜127、強さは0〜1、長さは0.005〜10秒です。"
      | not (all validFinite [inputPitch event,inputVelocity event,inputDuration event]) || inputPitch event < 0 || inputPitch event > 127
        || inputVelocity event < 0 || inputVelocity event > 1 || inputDuration event < 0.005 || inputDuration event > 10]
  , [DomainError "timestampMs" "timestamp" "時刻を有限のミリ秒で送ってください。" | maybe False (not . validFinite) (inputTimestamp event)]
  ]

validFinite :: Double -> Bool
validFinite value = not (isNaN value || isInfinite value)

engineOperation :: Session -> (Audio.Engine -> IO (Either Audio.AudioError ())) -> IO Response
engineOperation session operation = case sessionEngine session of
  Nothing -> engineUnavailable session
  Just engine -> do
    result <- operation engine
    pure $ case result of Left (Audio.AudioError message) -> errorsResponse status503 (problem "engine" "audio" message); Right () -> json status200 (object ["ok" .= True])

engineUnavailable :: Session -> IO Response
engineUnavailable session = pure (errorsResponse status503 (problem "engine" "unavailable" (sessionEngineFailure session)))

status :: Session -> IO Value
status session = case sessionEngine session of
  Just engine -> engineJSON <$> Audio.readEngineStatus engine
  Nothing -> pure (object ["available" .= False,"backend" .= ("WASAPI / GHC" :: Text),"sampleRate" .= Audio.sampleRate,
    "bufferFrames" .= (0 :: Int),"underruns" .= (0 :: Int),"message" .= sessionEngineFailure session])

engineJSON :: Audio.EngineStatus -> Value
engineJSON value = object ["available" .= Audio.engineAvailable value,"backend" .= ("WASAPI / GHC" :: Text),
  "sampleRate" .= Audio.engineSampleRate value,"bufferFrames" .= Audio.engineBufferFrames value,
  "underruns" .= Audio.engineUnderruns value,"lateBuffers" .= Audio.engineLateBuffers value,
  "processedBuffers" .= Audio.engineProcessedBuffers value,"maxProcessMicros" .= Audio.engineMaxProcessMicros value,
  "voiceOverflows" .= Audio.engineVoiceOverflows value,"clippedSamples" .= Audio.engineClippedSamples value,
  "message" .= Audio.engineMessage value]

materializeRequest :: Value -> Parser (Project,Id)
materializeRequest = withObject "materialize" $ \o -> (,) <$> o .: "project" <*> o .: "patternId"
transportRequest :: Value -> Parser (Text,Double)
transportRequest = withObject "transport" $ \o -> (,) <$> o .: "action" <*> o .:? "beat" .!= 0
assetRequest :: Value -> Parser (Text,Text)
assetRequest = withObject "asset" $ \o -> (,) <$> o .: "name" <*> o .: "data"
exportRequest :: Value -> Parser (Project,Bool)
exportRequest = withObject "export" $ \o -> (,) <$> o .: "project" <*> o .:? "stems" .!= False

withJSON :: FromJSON a => Request -> (a -> IO Response) -> IO Response
withJSON request action
  | not (maybe False (BS.isPrefixOf "application/json") (lookup hContentType (requestHeaders request))) =
      pure (errorsResponse status415 (problem "request" "content-type" "JSON形式で送ってください。"))
  | otherwise = do
      bytes <- boundedBody request (192 * 1024 * 1024)
      case bytes of
        Left errors -> pure (errorsResponse status413 errors)
        Right body -> case eitherDecodeStrict' body of Left message -> pure (parseFailure message); Right value -> action value

boundedBody :: Request -> Int -> IO (Either [DomainError] BS.ByteString)
boundedBody request limit = case requestBodyLength request of
  KnownLength size | size > fromIntegral limit -> pure oversized
  _ -> gather 0 []
  where
    oversized = Left (problem "request" "body-capacity" "送信データは192 MiBまでです。素材を短くしてください。")
    gather total chunks = do
      chunk <- getRequestBodyChunk request
      if BS.null chunk then pure (Right (BS.concat (reverse chunks)))
        else let size = total + BS.length chunk in if size > limit then pure oversized else gather size (chunk:chunks)

safePart :: Text -> Bool
safePart part = not (Text.null part) && part /= "." && part /= ".." && not (Text.any (`elem` ("/\\\0:\r\n\"" :: String)) part)

serveFile :: FilePath -> ResponseHeaders -> IO Response
serveFile path headers = do
  exists <- doesFileExist path
  pure $ if exists then responseFile status200 headers path Nothing else errorsResponse status404 (problem "file" "not-found" "ファイルが見つかりません。")

mime :: FilePath -> BS.ByteString
mime path = case takeExtension path of
  ".html" -> "text/html; charset=utf-8"; ".js" -> "text/javascript; charset=utf-8"; ".css" -> "text/css; charset=utf-8"
  ".svg" -> "image/svg+xml"; ".png" -> "image/png"; ".ico" -> "image/x-icon"; ".woff2" -> "font/woff2"; _ -> "application/octet-stream"

nextId :: Session -> String -> IO String
nextId session prefix = do index <- atomicModifyIORef' (sessionCounter session) (\n -> (n+1,n+1)); pure (prefix <> "-" <> sessionToken session <> "-" <> show index)

atomicWrite :: FilePath -> LBS.ByteString -> IO ()
atomicWrite path bytes = do
  let temporary = path <> ".new"
  LBS.writeFile temporary bytes
  renameFile temporary path

json :: ToJSON a => Status -> a -> Response
json code value = responseLBS code [(hContentType,"application/json; charset=utf-8")] (encode value)
errorsResponse :: Status -> [DomainError] -> Response
errorsResponse code errors = json code (object ["errors" .= errors])
parseFailure :: String -> Response
parseFailure message = errorsResponse status400 (problem "json" "parse" (Text.pack message))
