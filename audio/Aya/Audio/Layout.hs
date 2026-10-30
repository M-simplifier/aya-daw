module Aya.Audio.Layout where

-- Versioned private flat ABI. Offsets are bytes; frame fields are signed Int64,
-- identities Word64, indices/flags Int32 and DSP scalars Double. A single name
-- identifies each independent meaning even when two structures share an offset.

voiceBytes, voiceId, voiceTrackId, voiceActive, voiceTrackSlot, voiceOrigin,
  voiceGateFrames, voiceAge, voiceFrequency, voiceVelocity, voicePhase,
  voiceSecondPhase, voiceFilterLowL, voiceFilterBandL, voiceNoiseSeed,
  voiceReleaseAge, voiceReleaseLevel, voiceSamplePosition,
  voiceSampleInitialized, voiceTargetFrequency, voiceThirdPhase,
  voiceFilterLowR, voiceFilterBandR, voiceEnvelopeLevel :: Int
voiceBytes = 176
voiceId = 0
voiceTrackId = 8
voiceActive = 16
voiceTrackSlot = 20
voiceOrigin = 24
voiceGateFrames = 32
voiceAge = 40
voiceFrequency = 48
voiceVelocity = 56
voicePhase = 64
voiceSecondPhase = 72
voiceFilterLowL = 80
voiceFilterBandL = 88
voiceNoiseSeed = 96
voiceReleaseAge = 104
voiceReleaseLevel = 112
voiceSamplePosition = 120
voiceSampleInitialized = 128
voiceTargetFrequency = 136
voiceThirdPhase = 144
voiceFilterLowR = 152
voiceFilterBandR = 160
voiceEnvelopeLevel = 168

stateBytes, stateTrackId, statePlanIndex, stateActive, stateGain, statePan,
  stateCutoff, stateMixL, stateMixR, stateDelayWrite, stateDelayAge,
  stateFilterG, stateFilterDamping, stateDelayFrames, stateTargetGain,
  stateTargetPan, stateTargetFilterG :: Int
stateBytes = 192
stateTrackId = 0
statePlanIndex = 8
stateActive = 12
stateGain = 16
statePan = 24
stateCutoff = 32
stateMixL = 40
stateMixR = 48
stateDelayWrite = 56
stateDelayAge = 60
stateFilterG = 88
stateFilterDamping = 96
stateDelayFrames = 128
stateTargetGain = 144
stateTargetPan = 152
stateTargetFilterG = 160

transportMode, transportFrame, transportNextNote, transportControlTick,
  transportPeakL, transportPeakR, transportOverflows, transportClips,
  transportFade, transportTransitionL,
  transportTransitionR, transportLastL, transportLastR :: Int
transportMode = 0
transportFrame = 8
transportNextNote = 16
transportControlTick = 20
transportPeakL = 32
transportPeakR = 40
transportOverflows = 48
transportClips = 56
transportFade = 72
transportTransitionL = 80
transportTransitionR = 88
transportLastL = 96
transportLastR = 104

flatTrackId, flatInstrument, flatMuted, flatGain, flatPan, flatAttack,
  flatRelease, flatCutoff, flatResonance, flatTone, flatDelaySend,
  flatDelayFrames, flatSampleIndex, flatDelayFeedback, flatAutomationRanges :: Int
flatTrackId = 0
flatInstrument = 8
flatMuted = 12
flatGain = 16
flatPan = 24
flatAttack = 32
flatRelease = 40
flatCutoff = 48
flatResonance = 56
flatTone = 64
flatDelaySend = 72
flatDelayFrames = 80
flatSampleIndex = 84
flatDelayFeedback = 88
flatAutomationRanges = 96

flatNoteId, flatNoteTrack, flatNoteStart, flatNoteEnd,
  flatNoteFrequency, flatNoteVelocity :: Int
flatNoteId = 0
flatNoteTrack = 8
flatNoteStart = 16
flatNoteEnd = 24
flatNoteFrequency = 32
flatNoteVelocity = 40

flatTrackCount, flatNoteCount, flatLength, flatTempo, flatMaster,
  flatLoopStart, flatLoopEnd, flatNotesOffset, flatAutomationOffset,
  flatSamplesOffset, flatPCMOffset, flatIntervalsOffset, flatHashesOffset :: Int
flatTrackCount = 8
flatNoteCount = 12
flatLength = 32
flatTempo = 40
flatMaster = 48
flatLoopStart = 56
flatLoopEnd = 64
flatNotesOffset = 72
flatAutomationOffset = 80
flatSamplesOffset = 88
flatPCMOffset = 96
flatIntervalsOffset = 104
flatHashesOffset = 112

flatSampleId, flatSampleRate, flatSampleChannels, flatSampleFrames,
  flatSampleData :: Int
flatSampleId = 0
flatSampleRate = 8
flatSampleChannels = 12
flatSampleFrames = 16
flatSampleData = 24
