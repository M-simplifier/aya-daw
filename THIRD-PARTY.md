# Third-party software in Aya

Aya's own source and original example project are licensed under [MIT](LICENSE).
Dependencies retain their own licenses. Saving a project does not relicense its
imported samples or its composition.

## Redistributed Windows runtime

The Windows release uses **GNU MP 6.3.0, MSYS2 package 6.3.0-2**, as the separate,
replaceable `libgmp-10.dll`. GNU MP is used under **LGPL-3.0-or-later**. It is not
relicensed under MIT. Both the GNU GPL v3 and LGPL v3 texts accompany the app in
`licenses/runtime/`. Replacement and rebuild instructions are in
[third-party/GMP-REPLACEMENT.md](third-party/GMP-REPLACEMENT.md).

The complete corresponding MSYS2 source archive, including upstream GMP source,
its two package patches and the original `PKGBUILD`, is included in the source
repository and Windows ZIP at
`third-party/sources/mingw-w64-gmp-6.3.0-2.src.tar.zst`. No separate request or
network access is needed to obtain it. Exact source and binary URLs and SHA-256
values are recorded in [runtime-lock.json](third-party/runtime-lock.json).

The exact original MSYS2 binary package is vendored in the source repository
under `third-party/binaries/` and checked against that same published hash,
so source builds and CI do not
depend on an interactive mirror/CDN download. The package is preserved verbatim.
Its original manuals retain GNU FDL 1.3-or-later terms, no invariant sections,
and the original cover texts; their notice/license and complete source are
retained. The application ZIP extracts only the needed GMP DLL from this binary
package, while retaining the complete corresponding source archive.

The DLL's PE imports are `KERNEL32.dll` and `msvcrt.dll`, supplied by Windows.
Microsoft system DLLs are not redistributed. The MSYS2 binary was built with
GCC 13.2.0; the GCC Runtime Library Exception and GPL v3 text are included for
the compiler runtime portions. Its MinGW-w64 runtime notices are also included.

GHC's runtime and Haskell libraries retain their original BSD-style notices.
The linked libffi 3.5.2 runtime is covered by its MIT notice; its exact version
and original header notice were checked in the installed GHC RTS. MinGW-w64/winpthreads
and LLVM compiler-rt notices are included as well. These are separate from
Aya's MIT license.

## Haskell dependency notices

[third-party/notices/manifest.json](third-party/notices/manifest.json) records the
dependency closure of the actual Aya executable, not every package installed on
the build machine. For each package it records its version, the package's
license declaration, the source archive hash when available, and hashes of the
original notice files. Original subdirectory names are retained, so distinct
notices in one package are not overwritten.

The audited Haskell declarations are BSD-2-Clause/BSD-3-Clause, MIT, ISC and
Zlib, including older `BSD2`/`BSD3` spelling. Crypton's BSD, MIT and ISC component
terms and notices are retained in full; its declaration uses `AND`. The manifest's declarations
are inventory data; the accompanying original texts govern each dependency.

The source snapshot is under `third-party/notices/`. Release packages contain
the same collection under `licenses/`, plus the corresponding-source archive
and this notice. `scripts/package-licenses.py` derives the closure from the
selected Cabal build plan and fails when an original license text is missing.

## Local builds and redistribution

A normal `cabal build` uses the installed compiler's default runtime linkage;
the tested GHC 9.14.1 Windows distribution bundles a static GMP implementation.
That build is suitable for local development, but this repository's release
packager does **not** redistribute it as an MIT-only executable.

Use `scripts/build.ps1 -Release -Tests` and `scripts/package.ps1` to create a
redistribution-ready Windows package. The release path verifies the pinned GMP
package from the vendored original, links its import library ahead of GHC's
static archives, checks that the result imports `libgmp-10.dll`, collects notices
and includes corresponding source. It does not modify the installed compiler
or package database.
