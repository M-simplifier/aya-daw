# Replacing the GNU MP library

The Windows release loads `libgmp-10.dll` from the application folder. You may
modify this LGPL-covered library and reverse engineer the combined application
to debug those modifications. Aya imposes no additional restriction on doing so.
There is no signature check, activation requirement or installation key.

1. Close Aya with `Close.cmd` so Windows releases the loaded DLL.
2. Build an interface-compatible x86-64 Windows GMP DLL, or obtain one built
   from the corresponding source below. Preserve the exported ABI of GMP 6.3.0
   and its 64-bit limbs with zero nail bits. Keep the filename `libgmp-10.dll`.
3. Replace that file beside `aya.exe` and start `Launch.cmd` again. Restoring
   the original DLL restores the original runtime.

## Complete corresponding source

`sources/mingw-w64-gmp-6.3.0-2.src.tar.zst`, included with the app, is the exact
MSYS2 corresponding-source package. It contains:

- The original GNU `gmp-6.3.0.tar.xz` and its detached signature.
- `do-not-use-dllimport.diff` and `gmp-staticlib.diff`.
- The original `PKGBUILD` and `.SRCINFO` build recipe and package metadata.

Its SHA-256 is
`f288f944fd9609db220bcf6a8dd0703a5674eeb906ef35eb8485bb8192135994`.
The upstream GNU source hash, patches and build commands are preserved in that
recipe. The verified distributed binary package hash is
`8924433974c4add46cb46ea4f6ef283b5c5139d3f552375115b5580f855015cc`.

To reproduce the MSYS2 build, extract the source package in a separate MSYS2
MINGW64 build environment, install the build requirements named in `PKGBUILD`
and run `makepkg-mingw` there. Its recipe builds static and shared variants,
runs the GMP tests, then packages them. It applies the two supplied patches and
uses `--enable-fat` for x86-64. The distributed package was built with GCC
13.2.0-2 and MinGW-w64 CRT 11.0.0.r159.g0605217f5-1; a newer compatible compiler
can be used for a modified build. No MSYS2 installation is needed to run Aya.

Aya's release script uses the vendored, byte-for-byte original official binary
package, verifies its SHA-256, and uses the corresponding `libgmp.dll.a` import
library. It does not alter the installed GHC archives. The import library supplies DLL import thunks
before those archives are searched, so GMP calls resolve to the replaceable
DLL. Full musical, Integer/Rational, render and native-worker checks were run on
that result; the original example WAV is byte-identical to the earlier local
build. Normal source builds and release builds are distinguished in
[THIRD-PARTY.md](../THIRD-PARTY.md).

Original licenses are included under `licenses/runtime/` in the app and
`notices/runtime/` in the source tree. GNU MP copyright notices are preserved in
the corresponding source; GNU MP is Copyright Free Software Foundation, Inc.
and contributors. This is a shared-library distribution under LGPL v3 section
4(d)(1), with the library's corresponding source supplied as well.
