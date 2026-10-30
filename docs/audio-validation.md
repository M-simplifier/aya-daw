# Audio validation, 2026-10-30

Environment: native Windows, GHC 9.14.1, ordinary `-O2`, x86-64 NCG,
48,000 Hz stereo float supplied to event-driven shared WASAPI. The observed
endpoint buffer capacity was 1,056 frames; normal fills were 480 frames
(10 ms). Tests used low master levels and stopped/released the stream afterward.
These observations concern this machine and bounded runs.

## Semantics

`runAudioSelfTest` exercises production plan admission, encoding, kernel and
state migration. Its independent impulse reference is a pure one-sample
direct-form biquad plus persistent FIFO. The production implementation uses
TPT filter memories and mutable rings. Their filter realization, delay
representation and migration paths are separate.

For 18,000 frames with a plan track-layout/address swap at frame 3,000, the
maximum Float sample error was **0.0**. A deliberately reset feedback state
produced error **2.581879925855901e-6**, so the test rejects losing the tail.
The same comparison was then performed on the exact buffers supplied to
WASAPI: **18,000 frames, 38 packets, maximum error 0.0**, the reset fault was
again rejected, zero late packets and zero observed buffer starvation. Maximum
measured wake-to-release work in that probe was **154.7 microseconds**.
The final source check repeated it with maximum **162.8 microseconds**, again
with exact supplied-sample agreement and zero late/starvation observations.
The device test writes the supplied samples as `wasapi-supplied-reference.wav`
in its selected output directory. This is buffer-supply evidence, not physical
speaker/loopback capture.

This controlled device probe drives the production kernel and `installPlan`
at a fixed sample index, splitting a native packet at that index if needed.
The faulty comparison is a reference variant that clears its FIFO at the swap;
the executable is not patched to inject that fault. Shared-memory generation
exchange and acknowledgment are exercised separately by the isolated-worker
load test below.

The selftest also checks live move-to-future/retrigger, shortening, deletion,
pitch-only phase preservation, fractional-Hz smoothed phase against an
independent recurrence, frozen early-keyup envelope, panic output continuity,
seek/chase and exact loop boundary. Duplicate IDs, NaNs and 257 overlapping
voices are rejected. All nine instrument families including stereo 44.1 kHz
PCM, gain/cutoff automation and delay are bit-identical when the same render
is split into irregular block lengths. WAV normalized edge cases cover all
six admitted sample formats; compressed, truncated and nonfinite files fail.

This is not an independent musical/spectral model for every instrument.
Block-partition equality proves deterministic execution of that fixture; the
independent impulse check supports its narrower filter/delay/state meaning.

## Device and load observations

An initial 4-second device run sounded all eight procedural families, then
stopped. It processed 405 packets with zero observed starvation/late packets,
zero voice overflow and maximum measured block work **594.5 microseconds**.

A separate isolated-worker test used 32 tracks and 256 simultaneous voices,
12 plan layout swaps and 60 forced collections in the controller while
repeatedly constructing/reducing million-element storable vectors. Across
729 packets (approximately 7.3 seconds), observations were zero late packets,
zero starvation, zero voice overflow, zero clipped frames and maximum measured
block work **6.513 ms**, below the normal 10 ms fill duration. The last portion
included voice release; not every packet had 256 sustained voices.

`engineUnderruns` counts zero-padding-before-refill observations after startup.
This can indicate render starvation; WASAPI's render API does not directly
report a hardware glitch count. `engineLateBuffers` separately counts processing
work exceeding the supplied packet's duration. Neither counter establishes
that an endpoint never glitched outside the observation window.

## Allocation and generated code

After warmup, a 4,800-frame sustained-voice block used **32 Haskell heap bytes**.
A 4,096-frame block containing all nine families, live automation, sample
interpolation and effects also used **32 bytes**. `getAllocationCounter` measured
the calling Haskell thread around the production block. Those fixed block-entry
allocations do not grow per sample in these fixtures. Foreign runtime state is
preallocated separately. The selftest checks a 512-byte bound to catch optimizer
regressions in this pinned compiler configuration.

Inspection of the optimized GHC 9.14.1 build found that Core contains
primitive `readDoubleOffAddr#`/`writeDoubleOffAddr#`, unboxed integer/float state
and recursive joins; Cmm exposes direct loads, arithmetic, stores and branches.
The observed steady oscillator/filter/mix paths avoid intermediate sample lists
and boxed per-sample tuples. Entry closures, onsets/chase/transport and exceptional
branches still contain allocation/GC checks. This is deliberately narrower than
claiming an allocation-free executable or a hard realtime guarantee.
In particular, event-dispatch branches reserve and retract heap space when no
onset is due, so a fixed net allocation count alone does not establish the
absence of GC polls. The worker process still runs the ordinary RTS.

## Reproduction

The packaged/integrated executable accepts:

```text
aya --audio-self-test diagnostics
aya --audio-device-test diagnostics
```

The package's `audio-tests` executable additionally accepts `--device` and
`--stress`. Ordinary `cabal test aya-audio:audio-tests` is silent: it runs the
selftest without opening the device. The device/stress modes must be explicitly
selected. All device modes close their stream with `finally`.

With GHC 9.14.1 and Cabal available, run from the project root on Windows:

```text
cabal test aya-audio:audio-tests --test-show-details=direct
cabal run exe:aya -- --audio-self-test diagnostics
cabal run exe:aya -- --audio-device-test diagnostics
cabal test aya-audio:audio-tests --test-options="--stress" --test-show-details=direct
```

The device and stress commands produce audio. Use a low system volume before
running them. To inspect compiler output, add `-ddump-simpl -ddump-cmm
-ddump-asm -ddump-to-file` to a local optimized build of `Aya.Audio.Kernel`.
Generated compiler files are local build artifacts and do not belong in the
source distribution.

Long-duration deadline distributions, hardware loopback, device removal during
playback, MIDI hardware and subjective listening quality have not been
established by these tests. Windows scheduling and drivers remain outside the
GHC kernel's guarantees. No failed evidence required moving DSP out of GHC.
