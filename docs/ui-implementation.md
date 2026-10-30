# Aya browser editor

The browser is an editor for the Haskell service. It contains no synthesizer,
music generator, transform interpreter, or substitute audio playback. Generated
notes and their transformed lengths come from `resolved.patterns`; materializing
uses `/api/materialize`. Native output availability and actual output peaks come
from `/api/status`. Opening the page does not start transport.

`web/model.js` contains immutable editing operations and bounded undo history.
Track/clip/note identities survive movement and reordering. A linked duplicate
shares its pattern; detaching creates new pattern/note identities. A drag previews
the project locally and commits one history transaction on release. Group note
movement clamps its shared delta, preserving chord intervals and relative timing.
Generator/transform results cannot be edited as raw notes until materialization.

`web/api.js` serializes compile requests, coalesces pending edits, and publishes
only the latest revision's projection or error. Transport play, save, and export
flush this queue. Invalid edits remain visible for correction while the service
retains its last accepted native plan. Recovery is written after successful
compilation; browser storage also retains the latest edit when quota permits.
The browser's newer/different recovery is offered explicitly at startup.

`web/main.js` owns DOM rendering and effects: service requests, pointer/keyboard
input, file downloads, and status polling. Inspector controls edit the same
project as timeline and piano roll. Numeric pitch is continuous semitone units;
vertical movement steps by `12 / tuning.divisions`. Generator scale entries are
EDO step offsets; generator degree sequences index that scale. The interface
states shared edit scope and provides separate linked/independent duplication.

PC keyboard presses/releases have unique gate IDs, monotonic timestamps, and
ordered sequence numbers, sent to the native audition endpoint. When armed,
paired presses become authored notes in the selected direct pattern. Recording
uses the current transport beat and tempo, with the selected grid; this is not
hardware latency compensation or sample-accurate external MIDI recording.
Focus changes release held gates. Page hide requests stop and panic. Text fields
keep their native editing shortcuts.

WAV import sends original bytes to the service and embeds its validated asset in
the project. Selecting a sample instrument without an asset opens the chooser
before changing the accepted instrument. `.aya` files contain JSON with the full
project and embedded assets. MIDI controls use the service's actual import/export
endpoints when bootstrap advertises MIDI capability. MIDI conversion warnings
are displayed alongside the resulting download.

## Checks

Run from the project root:

```powershell
node --test tests/ui/editing.test.mjs tests/ui/dom-contract.test.mjs
node --check web/main.js
```

These tests cover editing invariants, source independence, undo transaction
boundaries, automation ordering, and compile race/error recovery. They do not
constitute a browser, audio-device, or listening test. Actual served browser
checks and screenshots are recorded separately in `ui-verification.md`.

No external assets, fonts, CDNs, package installation, or frontend build step is
required. The service serves the HTML, CSS, and ES modules directly.
