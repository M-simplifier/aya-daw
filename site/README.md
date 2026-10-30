# Aya public website

The four committed HTML pages are ready to serve without a build, package
installation, external font, CDN, account, or application backend. GitHub Pages
serves this directory at `https://m-simplifier.github.io/aya-daw/`.

- Japanese main page: `index.html`
- English main page: `en/index.html`
- Japanese developer guide: `developers/index.html`
- English developer guide: `en/developers/index.html`

`main.js` handles the navigation, the clearly labelled silent illustration,
and playback of the original exported song. It has no live Aya service calls or
browser synthesizer. The WAV uses `preload="none"` and plays only on request.

`node site/check.mjs` checks the static routes, relative links, anchors, local
assets, both languages, source links, metadata, media hashes and project example.
An optional `--url http://127.0.0.1:PORT/aya-daw/` also checks served routes,
range requests and the project download against a local preview.

The maintained musician-page copy and shared HTML layout are in
`scripts/build-pages.mjs`. The developer prose comes from
`../docs/developer-guide.ja.md` and `../docs/developer-guide.en.md`.
After editing these sources, `node site/scripts/build-guides.mjs` regenerates
all four committed pages and the original score/waveform assets. This refresh
step is for maintainers; readers and Pages deployment need no build.

`assets/media-sources.json` records provenance and content hashes. The actual
editor capture is unmodified. The music is the original stereo 48 kHz/24-bit
Aya export at `../examples/Glass-Tides.wav`; the waveform is derived from it.
The score artwork and explanatory browser illustration are original work.

Aya's own code is MIT-licensed. The Windows app's third-party dependency
notices and redistribution conditions are linked through `../THIRD-PARTY.md`;
the site does not describe the complete bundled application as solely MIT.
