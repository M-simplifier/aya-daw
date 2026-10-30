# Aya

**Make a pattern, hear a variation, arrange a whole piece.**

Aya is a local Windows composition studio for generative and microtonal
electronic music. Draw notes or create Euclidean rhythms, arpeggios and chord
progressions; transform them, make the result directly editable, and arrange
linked clips across tracks. Save the whole project, including its WAV samples,
then export a stereo mix or individual track stems.

[Official website](https://m-simplifier.github.io/aya-daw/en/) ·
[日本語](README.ja.md) ·
[Download for Windows](https://github.com/M-simplifier/aya-daw/releases/latest/download/Aya-Windows-x64.zip) ·
[Developer guide](docs/developer-guide.en.md)

## Start making music

1. Extract the Windows ZIP into a writable folder and double-click **Launch.cmd**.
   Aya opens its browser editor and a separate native audio worker. No Haskell
   installation, account or terminal is needed for the download.
2. Start with **Glass Tides**, the included original 40-bar, 19-EDO composition,
   or choose **新規** for a blank project. The current app interface is Japanese;
   the website and developer documentation are available in English and Japanese.
3. Add tracks and patterns. Draw individual notes, or use **規則で作る** to generate
   them. Transpose, rotate, reverse, stretch, invert or filter notes by seeded
   probability. **音符に確定** materializes the result for direct editing.
4. Place clips on the timeline, build an introduction, main section, variation
   and ending, then adjust instruments, gain, pan, filter and automation.
5. **保存** downloads a self-contained `.aya` JSON project. **開く** restores it.
   The included `.aya.json` examples can be opened too. **書き出す** exports WAV;
   enable track WAVs to obtain stems. Download the files listed in the result.
6. Save before leaving. **Close.cmd** closes both the local server and its audio
   worker; closing only the browser tab leaves the app available to reopen.

Built-in sounds include bass, pad, bell, lead, pluck, kick, snare and hat, plus a
WAV sample instrument. Pitch remains continuous; EDO scales are not rounded to
12-tone MIDI notes. PC keyboard performance can be recorded as notes. Undo,
redo, local recovery, clip looping, mute/solo, delay and gain/pan/cutoff
automation use the same project model.

Projects and samples stay local. The editor talks only to its loopback service;
there is no audio upload or Web Audio synthesizer fallback. Native GHC code
calculates the samples for playback and offline export.

## Current scope

Windows x64, WASAPI shared/event output, fixed 48 kHz stereo. WAV exports are
24-bit PCM and include release/delay tails. Imported WAVs may be mono or stereo
PCM 8/16/24/32-bit or float 32/64-bit. The capacity limits are 32 tracks, 256
patterns, 2,048 clips, 32,768 arranged notes and 256 simultaneous releasing or
sustained song voices. Invalid data is rejected with a reason.

MIDI files: import SMF type 0/1 with PPQN timing; export type 0 at 960 PPQN.
Tempo changes are flattened into elapsed-time-preserving note positions in a
constant-tempo project. Continuous bends are held at their onset pitch with a
warning. Export uses per-note channels and pitch bend for microtones, requires
a receiver that supports the declared bend range, and supports 15 simultaneous
melodic voices. Instrument sounds, effects, automation and samples belong in
WAV/stems. External MIDI hardware, VST hosting and multitempo editing are not
implemented in v0.1.0.

## Build and contribute

Install ordinary GHC **9.14.1** and Cabal **3.18.2.0** on Windows and make
`ghc`/`cabal` available on PATH. Node 24 runs frontend/site checks; Python 3.10+
collects package notices. No frontend package installation or build is needed.

```powershell
cabal update
./scripts/build.ps1 -Tests
node --test tests/ui/*.test.mjs
node site/check.mjs
```

The pure compiler validates identities and rational musical intervals before
resolving generators, transformations and arrangement. It converts boundaries
to sample positions once. The audio worker owns persistent synthesis and effect
state; a thin C layer binds Windows audio, process and shared-memory operations.
Read the [developer guide](docs/developer-guide.en.md),
[API contract](docs/INTERFACES.md) and [audio validation](docs/audio-validation.md)
for the exact boundaries and measured evidence. Tests do not establish a
universal realtime deadline or artistic quality.

**Redistribution differs from a local build.** GHC's default Windows build can
statically include GMP. To make the licensed release package instead:

```powershell
./scripts/build.ps1 -Release -Tests
./scripts/package.ps1 -SkipBuild
```

This verifies and links a replaceable GMP DLL, bundles complete corresponding
source and original notices, and removes build-machine debug paths. It does not
change the installed toolchain. Use a writable extraction directory; launchers
and recovery files remain relative to that directory.

## License

Aya's own source and original example are [MIT](LICENSE). Dependencies keep
their own licenses. The Windows download includes **LGPL-3.0-or-later GNU MP**
as a replaceable DLL with its complete source and replacement instructions.
Read [THIRD-PARTY.md](THIRD-PARTY.md) and the bundled notices before redistributing.
Imported samples and the music you create are not relicensed by saving them.
