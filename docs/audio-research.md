# Audio implementation sources

Aya uses ordinary GHC for synthesis and signal processing. A long-lived Haskell
thread owns the native stream, with editor/compiler allocation in another
process. This avoids entering Haskell through a foreign-export callback for
every buffer. The implementations can be read in `audio/Aya/Audio/Kernel.hs`
and `audio/Aya/Audio.hs`; generated-code and runtime observations are documented
in [audio-validation.md](audio-validation.md).

The following primary sources informed concrete implementation choices.
Equations are independently expressed in Haskell; no external synthesizer or
DSP engine is linked.

- [Microsoft: rendering a stream](https://learn.microsoft.com/en-us/windows/win32/coreaudio/rendering-a-stream)
  defines acquired buffer lifetime, padding and `GetBuffer`/`ReleaseBuffer`.
  Those calls are paired on the owning bound thread.
- [Microsoft: event and format-conversion flags](https://learn.microsoft.com/en-us/windows/win32/coreaudio/audclnt-streamflags-xxx-constants)
  supplies the event-driven pull boundary and endpoint conversion contract.
- [Microsoft: IAudioClient Initialize](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-initialize)
  supplies shared-mode period rules and device-invalidated failure meanings.
- [GHC 9.14.1 FFI](https://downloads.haskell.org/ghc/9.14.1/docs/users_guide/exts/ffi.html)
  distinguishes safe blocking waits, bound threads and foreign-export entry.
  A bound thread is not an independent GHC heap; process isolation provides
  that separation from the editing process.
- [Andrew Simper, Cytomic: linear trapezoidal state-variable filter](https://cytomic.com/files/dsp/SvfLinearTrapOptimised2.pdf)
  derives the stable two-integrator update used for the resonant lowpass.
  Aya's independent reference uses the corresponding direct-form difference
  equation, so it does not share the optimized mutable-state realization.
- [Martin Finke: PolyBLEP oscillator](https://www.martin-finke.de/articles/audio-plugins-018-polyblep-oscillator/)
  gives a concrete oscillator implementation and its discontinuity correction.
  Aya applies the polynomial correction to its saw/square oscillators. This
  reduces edge aliasing; it is not a claim that FM, noise or every transposition
  is perfectly bandlimited.
- [Microsoft: WAVEFORMATEXTENSIBLE](https://learn.microsoft.com/en-us/windows/win32/api/mmreg/ns-mmreg-waveformatextensible)
  distinguishes container bits, valid bits, channel order and subtype GUID.
  Unsupported variants are rejected rather than guessed.

Related work on [Stream Fusion](https://www.cs.tufts.edu/~nr/cs257/archive/duncan-coutts/stream-fusion.pdf)
and [join points](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/11/join-points-pldi17.pdf)
explains how functional source can become direct loops without intermediate
lists. Such compiler techniques are a reason to inspect the actual generated
code, rather than infer allocation behavior from source syntax. Aya's timing
evidence comes from its own runtime tests; these papers do not establish
realtime guarantees for the application.
