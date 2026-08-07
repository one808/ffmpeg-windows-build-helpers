# Dependency Version Audit — FFmpeg XP Build

Generated 2026-08-07 by checking every pin in [`cross_compile_ffmpeg.sh`](ffmpeg_local_builds/cross_compile_ffmpeg.sh)
against upstream (`git ls-remote` for git-pinned deps, release listings/APIs for tarball-pinned deps).

Legend: ✅ latest available · ⚠️ genuinely behind · ℹ️ behind but not a real concern (frozen/legacy upstream, mirror lag, etc.)

## Summary

- **63 libraries** feed into the FFmpeg build, plus FFmpeg itself and the mingw-w64 cross-toolchain.
- **57 are on the latest available commit/tag** (✅), **6 are legacy/frozen upstreams or mirror-lag, not real
  concerns** (ℹ️).
- **3 remain genuinely behind by a minor/patch version** (⚠️): `libmpg123` (1.32.7 → 1.33.7), `libopenmpt`
  (0.7.9 → 0.8.7), `FFTW` (3.3.10 → 3.3.11). None are worth chasing on their own — low risk, low payoff.
- `librubberband` (was 3 major versions / ~5 years stale), `LAME` (was floating, unpinned), and `libiconv`
  (1.17 → 1.19) have all been bumped/pinned since the previous pass. `librubberband` in particular had
  switched to a Meson-only build system upstream (v4.x dropped autotools entirely), so its `build_X()`
  function was rewritten, not just re-pinned.
- Every dependency change in this pass was rebuilt and re-verified against `scripts/check-xp-compat.sh`
  (zero Vista+-only imports in `ffmpeg.exe`/`ffplay.exe`/`ffprobe.exe`).
- Separately, the **mingw-w64/GCC/binutils cross-compiler toolchain is old** (GCC 10.4.0 vs. latest 16.1.0)
  — this is inherited from the vendored `mingw-w64-build-r33` helper script, not tracked per-dependency.
  Bumping it is a much bigger, separate undertaking (risks breaking XP-era assembly/code across all 63 deps
  at once) and was deliberately left untouched.

---

## FFmpeg itself

| Component | Pinned | Pinned commit date | Latest available | Status | Note |
|---|---|---|---|---|---|
| FFmpeg | n8.1.2 (`1c2c67c0`, `release/8.1`) | 2026-06-17 | n8.1.2 is still the newest **tagged** release; `release/8.1` branch has untagged commits after it (`9b6c8969`) | ✅ | Pinning to the release tag (not branch tip) is intentional/correct practice. |

## Cross-compiler toolchain (`patches/mingw-w64-build-r33`)

| Component | Pinned | Latest available | Status | Note |
|---|---|---|---|---|
| GCC | 10.4.0 | 16.1.0 | ⚠️ | Vendored script's own default; not touched here. Bumping risks breaking XP-era code/assembly across all 63 deps — separate, higher-risk project. |
| Binutils | 2.36.1 | 2.47 | ⚠️ | Same as above. |
| mingw-w64 (headers/CRT) | 9.0.0 | v14.0.0 | ⚠️ | Same as above. |
| pthreads-win32 (pthreads4w) | 2.9.1 | not individually audited | ℹ️ | Provides `libpthreadGC2.a`/`libpthread.a`, needed because this GCC build uses the win32 (not posix) thread model — and now load-bearing for several XP-compat threading patches too (dav1d, libxml2, SVT-AV1 all route onto it). |

---

## TLS / crypto / network protocols

| Library | Pinned | Pinned date | Latest available | Status | Note |
|---|---|---|---|---|---|
| mbedTLS | 3.6.7 (`627361b0`, `mbedtls-3.6` branch) | 2026-07-01 (tag date) | 3.6.7 is still the newest **tagged** release; branch tip (`35bc09d`) has post-tag commits | ✅ | Pinned to release tag, same reasoning as FFmpeg. XP-compat entropy patch applied on top (`patches/mbedtls-3.6.7_winxp-compatible-entropy.diff`). |
| OpenSSL | 3.6.3 | — | 3.6.3 | ✅ | Used only for libssh's crypto backend (mbedTLS has an unfixed 3.x API break in libssh's own `libmbedcrypto.c`). |
| librist | `4f45ef8f` | 2026-07-30 | same | ✅ | XP-compat entropy patch applied (`patches/librist_winxp-compatible-entropy.patch`) — was calling `BCryptGenRandom` unconditionally. |
| libssh | `ac6d2fad` (libssh-mirror) | 2022-08-08 | same (mirror tip) | ℹ️ | The GitHub mirror (`libssh/libssh-mirror`) itself hasn't synced since 2022; `git.libssh.org` (unreachable from this environment) may be further ahead. We're at the latest thing reachable from here. |
| gmp | 6.3.0 | — | 6.3.0 | ✅ | For RTMPE/RTMPTE support. |

## Video codecs

| Library | Pinned | Pinned date | Latest available | Status | Note |
|---|---|---|---|---|---|
| libx264 | `0480cb05` | 2025-09-10 | same | ✅ | |
| libx265 | `b81f650e` | 2026-06-23 | same | ✅ | |
| libvpx (VP8/VP9) | `251f0168` | 2026-08-04 | same | ✅ | |
| libaom (AV1) | `01fd4524` | 2026-08-04 | same | ✅ | |
| dav1d (AV1 decode) | `54706fc6` | 2026-07-14 | same | ✅ | XP-compat threading patches applied (`patches/dav1d_winxp-compatible_no-srwlock*.patch`) — was using native SRWLOCK/CONDITION_VARIABLE/INIT_ONCE unconditionally on `_WIN32`. |
| SVT-AV1 (AV1 encode) | `13438c1f` | 2026-08-03 | v4.2.0 tag (2026-07-13); we're already past it on unreleased `master` | ✅ | Not actually behind. XP-compat threading patches applied (`patches/svt-av1_winxp-compatible-threads*.patch`) — same SRWLOCK/CONDITION_VARIABLE/INIT_ONCE issue as dav1d, found via `ld --trace-symbol` since SVT-AV1's LTO build hides it from plain `nm`. |
| libwebp | `506cf14d` | 2026-08-04 | v1.6.0 tag (2025-07-07); we're already past it on unreleased `main` | ✅ | XP-compat patches applied (SRWLOCK in `src/dsp/cpu.h` and `src/utils/thread_utils.c`). |
| libjxl (JPEG XL) | `e8ff0976` | 2026-07-31 | same (+ auto-updating `brotli`/`skcms`/`testdata` submodules) | ✅ | Submodules are re-synced to latest on every build run, not pinned to a fixed commit. Built with explicit `-D_WIN32_WINNT=0x0501` so its `mingw-std-threads` dependency picks its own already-XP-safe code path. |
| xvidcore | 1.3.7 | — | 1.3.7 | ✅ | |
| vid.stab | `b85fa835` | 2026-08-06 | same | ✅ | Video stabilization filter. |
| frei0r | `253addfd` | 2026-06-27 | same | ✅ | Loaded dynamically at runtime (dlopen), not statically linked. |
| AviSynth+ | `cfdaf8eb` | 2026-07-14 | v3.7.5 tag (2025-04-20); we're already past it on unreleased `master` | ✅ | Headers-only usage (`avisynth_c.h`). |
| openh264 | `35325f40` | 2026-08-05 | same | ✅ | Cisco's openly-licensed H.264 codec; own Makefile-based cross-compile (not autotools/CMake/meson). |

## Audio codecs

| Library | Pinned | Pinned date | Latest available | Status | Note |
|---|---|---|---|---|---|
| libopus | `3da9f7a6` | 2026-06-12 | same | ✅ | |
| libvorbis | `1b75110b` | 2026-08-03 | same | ✅ | |
| libogg | `06a5e026` | 2026-03-02 | same | ✅ | |
| LAME (MP3 encode) | SVN r6751 | — | r6751 | ✅ | Now pinned to a fixed revision (was floating trunk) — trunk has no release tags to pin to instead, so this is as current as it gets while still being reproducible. |
| TwoLAME | `6fced852` | 2026-02-24 | same | ✅ | |
| fdk-aac | `d8e6b1a3` | 2025-08-21 | same | ✅ | Loaded dynamically at runtime (dlopen), not statically linked — stays "nonfree"-free in the binary. |
| libmpg123 | 1.32.7 | — | 1.33.7 | ⚠️ | One minor version behind. |
| libopenmpt (tracker music) | 0.7.9 | — | 0.8.7 | ⚠️ | A full minor version (and ~20 patch releases) behind. |
| game-music-emu (libgme) | `fe8da4b6` | 2026-07-23 | same | ✅ | Chiptune/console audio formats. |
| libsoxr | `945b592b` | — | same | ✅ | Resampler. |
| flite (TTS) | 2.1-release | — | 2.1-release | ℹ️ | A `flite-2.3` directory exists upstream but contains only voice data, no source release tarball — 2.1 is still the newest real source release. Project is essentially dormant. |
| libsamplerate | `2ccde956` | 2025-09-07 | same | ✅ | |
| FFTW | 3.3.10 | — | 3.3.11 | ⚠️ | One patch version behind (chromaprint's and now rubberband's FFT backend). |
| Chromaprint | `aed8eba2` | 2026-07-28 | same | ✅ | Audio fingerprinting. |
| Rubber Band (librubberband) | `e4296ac8` | 2025-02-27 | v4.0.0 tag (2024-10-25); we're already past it on unreleased `default` | ✅ | Bumped from a Feb-2021 pin (3 major versions stale). v4.x dropped autotools for Meson entirely, so `build_librubberband()` was rewritten, not just re-pinned; the old hand-rolled `Makefile.in` static-lib patch no longer applies (and isn't needed — Meson's own static+pkg-config install path covers it). |
| opencore-amr | `3b672189` | 2014-07-14 | same | ℹ️ | AMR-NB/WB codec is a frozen 3GPP spec from the 2000s — no upstream activity expected. |
| vo-amrwbenc | `3b3fcd0d` | 2014-11-07 | same | ℹ️ | Same as above (AMR-WB encoder). |
| speex | `05895229` | 2025-06-25 | same | ✅ | |
| GSM 06.10 (libgsm) | `98f1708f` | 2018-03-24 | same | ℹ️ | Classic 1990s GSM codec (Jutta Degener source), effectively frozen upstream. Was built but never actually wired into FFmpeg's `--enable-` list until this pass. |
| libbs2b | 3.1.0 | 2009 (release date) | 3.1.0 | ℹ️ | Bauer stereophonic-to-binaural DSP filter. Dormant upstream (last release 2009) but complete/stable. |
| codec2 | `310777b1` | 2026-03-17 | same | ✅ | Very-low-bitrate speech codec (digital voice / ham radio use case). |

## Subtitles / fonts / text

| Library | Pinned | Pinned date | Latest available | Status | Note |
|---|---|---|---|---|---|
| libass | `89cc0f4e` | 2026-08-04 | same | ✅ | |
| fribidi | `069a7e3d` | 2026-06-02 | same | ✅ | |
| HarfBuzz | 14.3.0 | — | 14.3.0 | ✅ | |
| FreeType | 2.14.3 | — | 2.14.3 | ✅ | |
| fontconfig | 2.16.0 | — | 2.16.0 (official tarball); 2.18.3 exists as an unpackaged git tag | ✅ | 2.18.x was never published as an official release tarball — 2.16.0 genuinely is the newest installable release. |
| libxml2 | 2.15.3 | — | 2.15.3 | ✅ | XP-compat patches applied (`patches/libxml2_winxp-compatible-*.patch`) — was using native Win32 threading (force-bumping `_WIN32_WINNT` to Vista as a side effect) and `BCryptGenRandom` unconditionally. |
| theora | `28fd5ec7` | 2026-05-11 | same | ✅ | |
| libzvbi (teletext) | `4e222f98` | 2026-08-04 | same | ✅ | |
| libbluray | `64bcf07f` | 2026-08-06 | 1.5.0 tag (2026-07-17); we're already past it on unreleased `master` | ✅ | Not actually behind. |

## Image / color

| Library | Pinned | Pinned date | Latest available | Status | Note |
|---|---|---|---|---|---|
| Little-CMS (lcms2) | `a8183f54` | 2026-08-05 | same | ✅ | Color management (also feeds libjxl's cms hook). |
| zimg (libzimg) | `f6cc75ad` | 2026-08-04 | same (+ auto-updating `graphengine` submodule) | ✅ | Colorspace/scaling, used by `zscale` filter. Submodule re-synced to latest on every run. |
| openjpeg | `402ef586` | 2026-07-07 | same | ✅ | JPEG2000. |

## Container / protocol support

| Library | Pinned | Pinned date | Latest available | Status | Note |
|---|---|---|---|---|---|
| zlib | 1.3.2 | — | 1.3.2 | ✅ | |
| xz / liblzma | 5.8.3 | — | 5.8.3 | ✅ | |
| bzip2 | 1.0.8 | — | 1.0.8 | ✅ | Effectively unmaintained upstream; 1.0.8 is genuinely the newest. |
| libiconv | 1.19 | — | 1.19 | ✅ | Bumped from 1.17. |
| SDL2 | 2.32.10 | — | 2.32.10 (latest of the 2.x line) | ✅ | SDL3 exists as a separate major version; not a drop-in replacement (different API), intentionally out of scope for ffplay here. |
| libdvdread | `3a1a0727` | 2026-08-05 | same | ✅ | DVD structure/sector reading. Meson-only upstream. Built **without** libdvdcss (`-Dlibdvdcss=disabled`) to stay clear of CSS-decryption code — can still `dlopen()` a user-supplied libdvdcss DLL at runtime, but nothing here links or ships one. Unencrypted/homemade DVDs read fine either way; commercial encrypted discs won't decrypt. |
| libdvdnav | `e0c02b97` | 2026-07-17 | same | ✅ | DVD menu/navigation (`dvdnav://`), depends on libdvdread above. Meson-only upstream. |
| snappy | `6af9287f` (v1.2.2) | 2025-03-26 | same | ✅ | Google Snappy compression, used by a handful of muxers/demuxers. Pinned to a release tag rather than `main` — unlike most git deps here, snappy's `main` branch isn't guaranteed build-stable. |

## Filters / analysis

| Library | Pinned | Pinned date | Latest available | Status | Note |
|---|---|---|---|---|---|
| libvmaf | `4991d2b5` | 2026-07-31 | v3.2.0 tag (2026-06-xx); we're already past it on unreleased `master` | ✅ | Netflix's objective video-quality metric (`-lavfi libvmaf` filter, `-vmaf` output). |
| libqrencode | `715e29fd` (= v4.1.1 tag) | 2020-09-28 | same | ✅ | QR-code generation (`qrencode` bitstream filter). Upstream itself hasn't moved since 2020. |

## Support / build-time libs

| Library | Pinned | Pinned date | Latest available | Status | Note |
|---|---|---|---|---|---|
| dlfcn-win32 | `8bfddb5a` | 2025-05-03 | same | ✅ | |
| mingw-std-threads | `c931bac2` | 2023-07-14 | same | ✅ | Small header-only shim, infrequently updated upstream. Already ships its own complete XP-safe `condition_variable`/`mutex` implementation (namespace `xp::`), gated behind `_WIN32_WINNT` — libjxl now explicitly requests it. |

---

## What changed in this pass

1. **9 new libraries added** to reach a "full mainstream build" module list: openh264, openjpeg, libbs2b,
   codec2, libdvdread, libdvdnav, libvmaf, libqrencode, snappy — plus wiring up `libgsm` (already built,
   never actually enabled in FFmpeg's own `--enable-` list before now).
2. **Full XP-compatibility re-audit** (`scripts/check-xp-compat.sh`) found and fixed 12 Vista+-only Win32
   API imports across 5 libraries that had crept in from the version bumps above: dav1d, librist, libxml2,
   libjxl (via mingw-std-threads), and SVT-AV1. All patched to route onto already-XP-safe code paths
   (mostly POSIX pthreads via the pthreads-win32 already used elsewhere in this build); binaries now show
   zero Vista+-only imports.
3. **Version bumps**: librubberband (2021 → current, Meson rewrite), LAME (unpinned → pinned SVN r6751),
   libiconv (1.17 → 1.19).
