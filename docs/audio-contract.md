# Native audio contract

Aya's synths, sample playback, envelopes, filters, pan, automation, mixing,
tempo-synced delay and WAV rendering are ordinary Haskell compiled by GHC.
`audio/cbits/aya_native.c` binds Windows COM, handles, process creation,
shared memory, atomics and clocks. It does not calculate audio samples.

The public caller boundary is `Aya.Audio`, with raw input records in
`Aya.Audio.Types`. `validateAudioPlan` performs the same admission as
`setPlan` and `renderWav`, so compilation can fail usefully without a device.
The prepared representation is opaque; its source accessor is an ordinary
function and cannot be used to bypass validation with record update.

## Time and voice identity

All musical positions are signed 64-bit frames at exactly 48,000 Hz. The model
converts beats to frames once. A note occupies `[start,end)`; onsets at the same
frame run in ascending stable identity order. Its frequency is a finite Double
in Hz, including fractional Hz. The renderer does not quantize it to MIDI.

Track and note IDs become checked 64-bit FNV-1a identities. Duplicate IDs or
hash collisions reject the plan. The flat note lookup table admits no probe
chain above 64 entries. The note interval tree bounds chase work by the
admitted note count and overlap, rather than scanning the arrangement at every
sample. The audio thread owns all live mutable state.

A compatible plan update keeps voice phase, filter memory, integrated sample
position and track delay memory, even when track order and flat data addresses
change. Pitch-only edits slew the frequency. Surviving notes use the new
interval's remaining gate at the current cursor. Moving an onset into the
future, shortening it into the past or deleting it starts release. A future
onset retriggers. Moving a note to another track transfers its voice to that
track's controls. An already released voice is not held indefinitely by an edit.

Key release freezes the envelope level reached during attack. Release then
decays from that level. Track deletion retires its sound with an output
transition. Pause freezes the cursor and resets voices and delay; resume
chases held intervals. Stop returns to frame zero. Seek and loop wrap reset
voice/filter/delay state and chase notes whose intervals contain the new
position. They initialize the held envelope age and sample offset there;
they do not reconstruct past feedback or past noise history. A 128-frame
transition prevents an instantaneous jump to zero on these resets and panic.

Automation is linear between points, holds the nearest endpoint outside the
point range, is evaluated every 32 samples, and has a per-sample control slew.
Track gain, pan and filter coefficient use a 0.004 slew coefficient. Changed
delay length slews by at most one frame per sample. PCM playback uses linear
interpolation; its natural root is C4, 261.6255653005986 Hz. Stereo PCM remains
stereo. High transpositions are not a fully bandlimited sample-rate converter.

## Process and memory ownership

`startEngine` launches the same executable as `--audio-worker NAME` with
`CREATE_NO_WINDOW`. The executable must dispatch that mode before starting its
web server. The worker runs one long-lived bound Haskell thread. That thread
initializes COM, owns WASAPI, safely waits for the buffer-ready event, calls
Haskell DSP directly and returns the native buffer. There is no per-buffer
foreign-export callback. WASAPI is shared/event-driven stereo float at 48 kHz,
with Windows format conversion requested for the endpoint's mix format.

A named mapping contains a 4 KiB control page followed by two 128 MiB slots.
Only the controller writes plans. It writes an inactive slot completely, then
publishes its generation with an interlocked release/acquire operation.
The worker switches at a buffer boundary, migrates scalar state, drops every
old-plan pointer and acknowledges the generation. The controller cannot reuse
the retired slot before acknowledgment. `setPlan` reports success only after
that acknowledgment; rejection leaves the admitted playing plan untouched.
An acknowledgment timeout is reported as a pending/uncertain update, not as
successful application.

The same page contains a 64-entry ordered command queue. Payloads are written
before the write sequence is published; the worker advances the read sequence
after applying them. Queue overflow is an explicit error. Audition on/off IDs
are stable; commands take effect, in order, at the next native buffer boundary.
The controller retains precise recording timestamps separately from this
block-quantized audition latency. Status uses a sequence-checked snapshot.
The source of byte layouts is `Aya.Audio.Layout`; native control-page offsets
and plan version are private to this executable version.

Delay lines, voices, track state, sine table and sample buffers use explicitly
owned foreign memory. Allocation and initial page touching precede device
start. A seek clears epochs rather than clearing all delay memory on a deadline.
Normal shutdown stops WASAPI and releases COM, MMCSS, event, device and mapping
handles. The worker also exits when its parent disappears. A failed shutdown
has a two-second grace period before process termination. Device invalidation
returns a useful HRESULT/status message; restoring a device currently requires
restarting Aya. No machine output preference is changed.

## Admission and output

Limits are 32 tracks, 32 samples, 32,768 resolved notes, 65,536 automation
points, 256 overlapping song voices including release and 32 reserved audition
voices. Runtime overflow from overlapping live edits/auditions increments an
explicit status counter; it is not presented as complete playback. Decoded
sample values total at most 96 MiB. A delay is at most four seconds with
feedback at most 0.92. A song is at most four hours. Full numeric bounds and
actionable errors live in `preparePlan`; no track, asset or event is truncated
to fit.

WAV import supports little-endian RIFF, mono/stereo PCM 8/16/24/32-bit and
IEEE float 32/64-bit, including matching valid/container-bit extensible PCM
subtypes. Surround, compressed audio, RF64 and differing valid/container bit
depths are rejected. Chunk lengths, data alignment and finite sample values
are checked before the sample is admitted.

Offline rendering uses the same production kernel, with looping disabled.
Stereo output and stems are 48 kHz stereo PCM24 WAV. A stem includes its track's
own delay and the master gain. The tail length includes release, enough delay
round trips for feedback to decay by 120 dB, and a filter settling margin.
Clipping is metered and counted; no silent normalization is applied. Nonempty
output is written to a temporary file and renamed on success. The RIFF 4 GiB
limit is checked first. A failed render cannot replace a completed WAV.

An allocation-free steady inner path does not prove a hard realtime system.
Plan activation, onsets, transport, safe-FFI resumption, the worker's outer
loop, RTS collection, Windows scheduling, page residency and drivers remain
separate timing obligations. See [the measurements](audio-validation.md).
