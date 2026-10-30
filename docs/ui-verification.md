# Browser verification — 2026-10-30

Observed against the actual Windows Haskell server at `http://127.0.0.1:8765/`,
with its actual WASAPI/GHC engine. The operational checks used a dedicated Chrome
tab through supported browser controls, not a mocked service or browser synth.
The run finished with the included example restored and transport stopped.

## Completed workflow

1. Opened the real example, dismissed the first-use guide, then created an empty
   project and renamed it using normal text input.
2. Added a pattern; generated an arpeggio; changed its subdivision count to eight;
   added a 0.5-semitone transpose. Eight canonical generated notes appeared.
3. Materialized those notes, changed fractional pitch, duration, and velocity;
   dragged a note in time and pitch; resized its right edge. One undo restored
   the whole drag and redo reapplied it. Double-click added a ninth note;
   Delete removed it and undo restored it. Shift selection, arrow movement,
   multi-note duplication, and its undo were exercised.
4. Duplicated a linked clip, observed the shared-edit warning, detached the copy,
   added a bass track, dragged the detached clip into it and later in time, and
   resized it from four to five bars. Edited gain, pan, and cutoff; reordered
   tracks and restored their order; toggled mute and restored it.
5. Added two gain automation points and edited their beat/value fields.
6. Set master gain to 0.1, armed recording on the direct pattern, and performed a
   real PC-keyboard press/release. A tenth authored note appeared (grid-quantized
   0.25-beat duration); the native output meter reported a nonzero level. Stop
   reset transport to the beginning and released voices. Keyboard mode was then
   switched off. No playback was left running.
7. Imported the task's generated 16-bit mono 48 kHz WAV fixture through the actual
   file chooser; the sample track showed its name, sample rate, channels, and
   0.1-second duration. Added a five-hit generated sample pattern.
8. Saved `Aya 検証 — Seed to Song.aya` (21,260 bytes), created an empty project,
   and opened the actual saved file through the file chooser. Three tracks,
   three patterns, three clips, the edited notes, and the embedded sample were
   restored. The embedded WAV's SHA-256 equaled the original fixture's SHA-256.
   The original pattern held ten notes; the independent copy retained nine.
9. Reloaded the app successfully. It recovered the current project without
   starting playback. Exported a stereo mix and three stems through the UI.
   The completion view reported 41.52 seconds including the effect tail.
10. Downloaded the actual mix WAV. All four served WAV files are nonempty RIFF
    PCM, stereo, 48 kHz, 24-bit, 11,958,452 bytes each.
11. Exported MIDI through the UI and observed the explicit GM/effects and
    microtonal pitch-bend compatibility warnings. The generated SMF is 845 bytes.
    Imported that actual generated file through the UI; continuous pitches such
    as 62.25 appeared and the import compatibility warning remained visible.
12. Restored the complete example, reloaded the final code, and checked the
    layout at 1280×800 and 900×700. The final browser error/warning log was empty.
    Fit-to-song and the selected track were visible; focus-height controls kept
    the editor usable without reducing its text size.

An additional visual review covered 1280×720, including the arrangement/editor
focus controls.

## Artifacts

Local diagnostics retained the edited project, imported fixture, downloaded
mix, inspected WAV headers and screenshots. These machine-local outputs are not
distributed as source. The public [editor capture](../site/assets/aya-studio.jpg)
shows the actual loaded example; the [example project](../examples/glass-tides.aya.json)
and [native WAV export](../examples/Glass-Tides.wav) are also included.

Screenshot capture explicitly checked the project title, native connection,
13 clips, 12 pattern notes and completed boot before saving the visually
inspected frame. This replaced an earlier capture that had caught loading.

## Automated checks and limits

Final check: `node --check web/main.js` and
`node --test tests/ui/editing.test.mjs tests/ui/dom-contract.test.mjs` passed
(11 tests). They cover source identity, group movement bounds, resize bounds,
single-transaction undo, automation ordering, stale compile responses, recovery
after compile errors, and renderer/markup ID contracts.

A removed toolbar badge initially exposed a renderer reference to a missing DOM
ID. It was fixed, the consumer contract test was added, local rendering faults
were distinguished from connection errors, and real boot was repeated. Canvas
selection also explicitly commits/blurs a text field; an in-flight projection
does not overwrite the active note-value field. Pitch fitting centers the full
note range rather than an onset/duplication-weighted mean.

The Chrome connector missed the Blob-save download event although the `.aya`
file was present and verified. Its MIDI download probe also timed out, and no
MIDI file was observed in Downloads. Browser MIDI delivery is therefore not
claimed here; the MIDI file and actual UI reimport were verified, and the
separate HTTP checks confirmed download/MIDI roundtrip success,
including 200 status, `audio/midi`, attachment filename `composition.mid`,
845-byte content length, and byte-identical received data. The UI did show its
ordinary usable server download link; no missing-file/link result was presented.

These checks establish this concrete composing/editing/file/export path. They
do not establish musical taste, hardware latency compensation, external MIDI
device compatibility, professional deadline guarantees, or every possible
capacity limit. Loop/seek/pause, exhaustive parameter behavior, and device timing
have the integration/audio checks as their separate evidence; this browser run
did not individually exercise every such control.
