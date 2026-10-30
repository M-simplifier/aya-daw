# Local editor API v1

This is the JSON boundary used by Aya v0.1.0. Browser controls express edits;
Haskell owns generation, transformation, validation and resolved notes. A separate
native GHC process computes realtime and offline samples. The browser has no
Web Audio synthesis fallback. Preserve schema compatibility when changing it.

## Product services

The loopback-only HTTP server serves `web/` and JSON `/api` routes. Failures use
HTTP error status and `{errors:[{path,code,message}]}`. Host and API Origin/fetch
checks reject foreign sites. Top-level static page navigation is allowed. The
launcher selects an available IPv4 loopback port and opens its actual URL.

- GET /api/bootstrap -> {project,resolved,instruments,engine,version,capabilities}. Project schema below. `capabilities.midi` and `keyboardGate` describe implemented routes.
- POST /api/compile, body full Project -> {project, resolved, warnings}. Resolved notes are canonical UI projection and preview. Invalid project leaves current sound intact.
- POST /api/materialize, body {project,patternId} -> the same compile response with that pattern converted to direct notes.
- POST /api/transport -> {action:"play"|"pause"|"stop"|"seek", beat?:number}. Play uses last accepted compile. Loop settings are in project.
- GET /api/status -> {playing,beat,peakL,peakR,engine:{available,backend,sampleRate,bufferFrames,underruns,message}}.
- POST /api/audition, body {trackId,pitch,velocity,duration}, auditions a bounded note. Pitch has the same units as Note.pitch and duration is seconds.
- For a held key, POST /api/audition with {kind:"on",eventId,trackId,pitch,velocity,timestampMs?,sequence?}; release with {kind:"off",eventId,timestampMs?,sequence?}. Events reach the native queue in HTTP submission order and apply at the next audio block. Timestamps do not claim sample-accurate hardware recording.
- POST /api/input-events, body {events:[...]} sends an ordered batch of up to 256 events. Recording pairs key press/release timestamps in the editor, then compiles authored notes.
- POST /api/panic releases active voices.
- POST /api/export, body {project,stems:boolean} -> export manifest {files:[{name,url}],duration}. URLs are local served downloads, verified nonempty. Deterministic engine renders including effect tail.
- POST /api/assets/wav -> {name,data:base64} -> Asset object usable in Project.assets. Initial supported PCM WAV/float variants must be explicit.
- GET /api/example -> complete composed Project, independent from bootstrap recovery.
- POST /api/recovery, body Project -> persist recovery atomically; GET /api/recovery -> Project or null.
- Save/open uses a browser `.aya` JSON file containing `{format:"Aya",version:1,project}`. Raw Project JSON is accepted by the file opener too. Assets are embedded. There is no arbitrary server filesystem write route.
- POST /api/midi/import, body {name,data:base64}, returns {project,warnings}. POST /api/midi/export, body Project, returns {files:[{name,url}],warnings}.
- POST /api/shutdown closes the local app and audio worker; `Close.cmd` uses this route.

## Project JSON v1

All IDs are persistent unique strings. Beats are quarter-note units. Tick quantization at boundary may use rational internal time; sample conversion happens once. Pitch is semitone units relative to MIDI 0, including fractions; tuning maps scale/step generators into this continuous pitch or Hz without rounding. Notes and transformations can be expressed directly without MIDI hardware.

```
{
 "schemaVersion":1,"id":"...","name":"...","tempo":108,"beatsPerBar":4,
 "lengthBeats":128,"masterGain":0.8,
 "loop":{"enabled":false,"start":0,"end":32},
 "tuning":{"divisions":12,"referenceHz":440,"root":60,"scale":[0,2,3,5,7,8,10]},
 "tracks":[Track],"patterns":[Pattern],"clips":[Clip],"assets":[Asset]
}
Track = {
 "id":"...","name":"...","color":"#...","instrument":"pad",
 "gain":0.6,"pan":0,"mute":false,"solo":false,
 "patch":{"attack":0.02,"release":0.3,"cutoff":8000,"resonance":0.1,
          "tone":0.5,"delaySend":0.2,"delayBeats":0.75,"delayFeedback":0.3},
 "assetId":null,
 "automation":[{"parameter":"gain"|"pan"|"cutoff", "points":[{"beat":0,"value":0.6}]}]
}
Pattern = {
 "id":"...","name":"...","length":16,
 "notes":[{"id":"...","start":0,"duration":1,"pitch":60,"velocity":0.8}],
 "generator":null|Generator,
 "transforms":[Transform]
}
Clip = {"id":"...","trackId":"...","patternId":"...","start":0,"length":16,
        "transpose":0,"gain":1}
Asset = {"id":"...","name":"...","data":"base64 original WAV", ...validated metadata}
Generator = {
 "kind":"euclid"|"arpeggio"|"chords", "steps":16,"pulses":5,"rotation":0,
 "root":60,"octaves":2,"gate":0.7,"seed":1,
 "degrees":[0,3,4,0],"velocity":0.8
}
Transform = {"kind":"transpose"|"rotate"|"reverse"|"stretch"|"invert"|"probability", "amount":number}
```

A generator replaces base notes until materialization, which copies compiled
pattern notes, sets the compiled period, clears generator/transforms and keeps
further editing direct. Pitch and transpose use continuous semitones; scale
entries use EDO steps and generator degrees index that scale. Reverse reflects
complete intervals. Rotation splits intervals that cross the period boundary;
fragments receive distinct IDs. Probability is deterministic for a note ID and
seed, so linked clip repetitions share the same resolved pattern. Linked edits
affect all referring clips; making a source independent allocates new IDs.

Resolved = {patterns:[{id,length,notes:[Note]}], notes:[{id,trackId,clipId,start,duration,pitch,frequency,velocity}], lengthBeats:number}.
Track instrument IDs initially: bass, pad, bell, lead, pluck, kick, snare, hat, sample.

`Aya.EnginePlan` translates admitted music to `Aya.Audio` using integer frame
boundaries rounded once at 48 kHz. Simultaneous resolved notes are ordered by
start, track ID and note ID; the native plan has its own explicit event ordering
and persistent identities. Seeking/looping uses reset/chase, while compatible
live edits preserve oscillator/filter/delay state. See `audio-contract.md` and
the developer guides for the exact mutable state and IPC boundary.

Capacity bounds must reject oversized projects with an actionable error before replacing the playing plan. Do not silently truncate notes, tracks, assets or automation. Sample processing cannot perform file IO, parse JSON, or compile music on the deadline path.
