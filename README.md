# ffmpeg-windows-build-helpers

This script is a fork of [Roger Pack's ffmpeg-windows-build-helpers](https://github.com/rdp/ffmpeg-windows-build-helpers). It helps me to compile (FFmpeg) binaries that are Windows XP compatible _and_ will work on old CPUs without SSE2 instruction sets (like my own AMD Athlon XP 3200+).  
FFmpeg has officially dropped support for Windows XP, but I'll try to create fresh binaries and update the script nonetheless.

**Binaries:** https://rwijnsma.home.xs4all.nl/files/ffmpeg/?C=M;O=D  
**Other stuff:** https://rwijnsma.home.xs4all.nl/files  
**Discussion and more info:** https://forum.doom9.org/showthread.php?t=181802

---

## `xp-core2` branch: containerized build for a modern Linux host

The upstream script above was written for (and only ever tested on) either a
32-bit Linux box or Cygwin on real Windows. This branch makes it build
correctly on a stock 64-bit Linux host too, inside a disposable, host-isolated
[podman](https://podman.io/) container, and retargets the generated code from
the original author's SSE2-less Athlon XP at a **Core 2** class CPU (e.g. a
Q6600) instead.

Nothing here touches the host system outside this repo's directory: the
podman image builds its own toolchain and never installs anything on the
host, and networking is pinned IPv4-only so it can't leak outside a VPN.

### Prerequisites

- `podman` (tested with 5.x). Rootless is fine.
- ~15 GB free disk for the build sandbox (cross-compiler + all dependency
  sources + build artifacts).
- A working internet connection. Slow connections are fine as long as you
  avoid forcing re-downloads (see "How caching works" below) -- a normal
  resumed build re-fetches nothing.

### Quick start

```sh
scripts/build.sh                  # build (or resume) everything, incl. FFmpeg
scripts/check-xp-compat.sh        # audit the resulting .exe files for XP-safety
```

`scripts/build.sh` builds the podman image on first run, creates the build
container, and runs the upstream script inside it with sane defaults
(`-d --sandbox-ok=y`, i.e. no interactive prompts). Output is both streamed to
your terminal and saved to `logs/build.log`. Run it again any time -- it
resumes the *same* container and only rebuilds what actually changed.

The finished binaries land at:

```
ffmpeg_local_builds/sandbox/win<arch>-<tier>/FFmpeg_git/{ffmpeg,ffplay,ffprobe}.exe
```

e.g. `win32-core2/FFmpeg_git/ffmpeg.exe` for the default target (see
"Building multiple CPU targets" below for the other tiers).

and a packaged release archive at
`redist/<timestamp>_ffmpeg-<version>_winxp-<cpu>-<bits>/ffmpeg-*-static-winxp-*.7z`
-- each build run gets its own dated folder (e.g.
`redist/2026_08_07_14_30_00_ffmpeg-n8.1.2_winxp-core2-32bit/`), containing a
`BUILD_INFO.txt` (version/target/CFLAGS summary) and a `SHA256SUMS` alongside
every `.7z` produced that run.

`scripts/check-xp-compat.sh [--target=win32-core2]` inspects those `.exe`
files' PE headers and import tables (via `objdump`, run inside the same
podman image) and fails if it finds either a subsystem version above the
target's ceiling (5.1 for 32-bit XP, 5.2 for the `win64-*` targets/XP x64
Edition), or an imported symbol known to exist only on Windows Vista or
later (`CancelIoEx`, `BCryptGenRandom`, `InitializeSRWLock`,
`GetTickCount64`, the `_s`-suffixed "secure" CRT functions, etc.). This is a
static check, not a substitute for actually running the result on real XP
(or an XP VM) -- see "What this doesn't catch" below.

By default this is a hand-maintained blocklist -- accurate for everything
that's bitten this build before, but not exhaustive by construction (it has
already missed real cases twice: see git log). For a ground-truth check
instead, pass `--xp-system32=DIR` pointing at a folder of real Windows XP
system DLLs (`kernel32.dll`, `msvcrt.dll`, `advapi32.dll`, `user32.dll`,
`ws2_32.dll`, ...); every imported symbol is then verified against that
DLL's *actual* export table instead of against a list of known landmines.
DLLs the `.exe` imports but that aren't present in `DIR` fall back to the
blocklist, so a partial set still helps. **Never download these from
"DLL download" sites** -- besides the copyright issue, that's one of the
most common malware-distribution vectors around, and a doctored DLL would
defeat the whole point of a ground-truth check. The only legitimate source
is a real Windows XP install you're already licensed for: copy the DLLs
from its `C:\Windows\system32\` yourself. Keep them out of version control
(e.g. under the already-gitignored `ffmpeg_local_builds/xp-reference-dlls/`)
-- they're Microsoft copyrighted binaries.

### `scripts/build.sh` options

```
scripts/build.sh [--rebuild-image] [--clean] [--cpus N] [--arch=32|64] [--cflags=STRING] [--tier=NAME]
```

- `--rebuild-image` -- rebuild the podman image from `Containerfile` even if
  it already exists (use after editing `Containerfile`).
- `--clean` -- remove the build container before starting, so the native
  host-tool installs (python/cmake/nasm, which live in the container's own
  `/usr`, not the bind-mounted sandbox) start fresh. This does **not** touch
  `ffmpeg_local_builds/sandbox/` -- your downloaded sources and built
  cross-compiler are untouched.
- `--cpus N` -- CPU limit passed to `podman run --cpus` (default `4`, or set
  `$FFMPEG_XP_CPUS`).
- `--arch=32|64` -- target bitness (default `32`). `64` targets Windows XP
  x64 Edition/Windows Server 2003 (NT 5.2), not regular 32-bit XP (NT 5.1) --
  a much more niche target, but the same codebase/patch set covers both.
- `--cflags=STRING` -- CPU tuning flags, e.g. `-O2 -march=pentium3
  -mtune=pentium3` for a pre-SSE2 machine (default: the script's own,
  currently `-O2 -march=core2 -mtune=core2`).
- `--tier=NAME` -- short label for this build target (e.g. `pentium3`,
  `sandybridge-64`). Selects the container name (`ffmpeg-xp-NAME`) and log
  file (`logs/build-NAME.log`) so each CPU tier/arch combo gets its own
  independently resumable container and dependency-build subdirectory
  (`ffmpeg_local_builds/sandbox/win<arch>-<tier>/`). Omit for the original
  single-target behavior (container `ffmpeg-xp-baseline`, log
  `logs/build.log`, subdirectory `win32-core2/`).

### Building multiple CPU targets (`scripts/build-matrix.sh`)

To build every supported CPU tier in one go:

```sh
scripts/build-matrix.sh                          # build all 8 targets
scripts/build-matrix.sh --only=pentium3,nehalem  # build a subset
scripts/build-matrix.sh --audit                  # + run check-xp-compat.sh after each tier
```

The full matrix:

| Tier             | Arch | CFLAGS                                  |
|------------------|------|------------------------------------------|
| `pentium3`       | 32   | `-O2 -march=pentium3 -mtune=pentium3`     |
| `pentium-m`      | 32   | `-O2 -march=pentium-m -mtune=pentium-m`   |
| `athlon64`       | 32   | `-O2 -march=athlon64 -mtune=athlon64`     |
| `core2`          | 32   | `-O2 -march=core2 -mtune=core2`           |
| `amdfam10`       | 32   | `-O2 -march=amdfam10 -mtune=amdfam10`     |
| `nehalem`        | 32   | `-O2 -march=nehalem -mtune=nehalem`       |
| `athlon64-64`    | 64   | `-O2 -march=athlon64 -mtune=athlon64`     |
| `sandybridge-64` | 64   | `-O2 -march=sandybridge -mtune=sandybridge` |

All CPU names are concrete `-march=` values, not the `x86-64-v2`/`v3`
microarchitecture-level syntax -- this toolchain's GCC (10.4.0) predates that
syntax (introduced in GCC 11). Every tier of the same bitness shares one
mingw-w64 cross-compiler toolchain (`cross_compilers/mingw-w64-i686/` or
`cross_compilers/mingw-w64-x86_64/`) but gets its own from-scratch dependency
tree, so only the *first* 32-bit tier and the *first* 64-bit tier you build
pay the toolchain build cost -- every other tier of that bitness reuses it.
Each tier is otherwise a full independent build (~63 dependencies + FFmpeg),
so budget several hours per tier and correspondingly more disk space (each
tier's dependency tree is on the order of the ~15 GB quoted above, on top of
the shared toolchain).

### How caching works (read this before deleting anything)

- **Downloaded/built sources** live in `ffmpeg_local_builds/sandbox/`, bind-
  mounted from the host. They survive container restarts, `--clean`, and
  even `podman rm`. `git`-based dependencies are updated in place (a cheap
  `git fetch` + compare, not a re-clone) unless the directory doesn't exist
  yet.
- **Native host-tool installs** (python/cmake/nasm -- built *for the build
  machine*, not for Windows) are installed to `/usr` **inside the
  container**, not the bind-mounted sandbox. They do **not** survive the
  container being recreated. This is why `scripts/build.sh` resumes the
  existing container instead of recreating it on every run, and why
  `--clean` exists as an explicit opt-in rather than being the default.
- If you need to force a full rebuild after a global setting changes (e.g.
  `original_cflags` in `cross_compile_ffmpeg.sh`), **do not** just
  `rm -rf ffmpeg_local_builds/sandbox/win<arch>-<tier>` -- that deletes the
  `.git` checkouts too and forces every dependency to be re-cloned from
  scratch (~50 git repositories, some large: FFmpeg itself, x265, aom, libjxl
  + submodules, AviSynthPlus, libvpx, libwebp, SVT-AV1, ...). For those, force
  a recompile *without* re-cloning instead:
  ```sh
  # inside a throwaway container, since the sandbox is root-owned:
  podman run --rm -v "$(pwd)":/work:Z ffmpeg-xp-builder:baseline \
    bash -lc 'cd /work/ffmpeg_local_builds/sandbox/win<arch>-<tier> && for d in */; do
      [ -d "$d/.git" ] && (cd "$d" && git clean -fdx && git reset --hard)
    done'
  ```
  This keeps every `.git` history intact (no re-clone) and wipes compiled
  `.o`/`.a`/configure-cache state (all untracked files) back to a pristine
  checkout, forcing a real recompile -- and correctly re-applies this
  fork's XP patches too, since those are plain working-tree edits `git
  reset --hard` also undoes; the build script's own patch-tracking
  touchfiles get removed by `git clean -fdx` in the same pass, so it
  reapplies them cleanly on the next run.

  A handful of dependencies are plain tarball downloads, not git checkouts
  (zlib, bzip2, freetype, gmp, mbedtls, fontconfig, ...) -- those don't
  have a `.git` safety net, but they're all small (low single-digit MB), so
  just deleting those specific directories and letting them re-download is
  fine even on a slow connection. The git-based ones above are the
  bandwidth-heavy part worth protecting.

### Target CPU

`original_cflags` in `ffmpeg_local_builds/cross_compile_ffmpeg.sh` defaults
to `-march=core2 -mtune=core2` when no `--cflags=` is passed. Override it via
`scripts/build.sh --cflags='...'` (see "Building multiple CPU targets"
above for the full pre-defined tier matrix, from pre-SSE2 `pentium3` up
through modern `sandybridge-64`) instead of editing the script for one-off
targets.

### Dependency versions

This build pulls in **63 third-party libraries** on top of FFmpeg itself (codecs,
containers, filters, TLS, fonts, ...) aiming for a "full" module list comparable to
mainstream builds like BtbN's -- minus anything that needs Vista+ APIs or a modern
GPU (Vulkan, D3D11VA/D3D12VA, AMF, NVENC/QSV), which are out of scope for a
Windows XP target by definition.

Every dependency is pinned to a specific commit (or tarball version), not a
floating branch -- see [`DEPENDENCY_VERSIONS.md`](DEPENDENCY_VERSIONS.md) for
the full table: what's pinned, when it was pinned, what's newest upstream, and
why anything that isn't bleeding-edge is that way (frozen/legacy upstream,
mirror lag, or a deliberate compatibility pin). SSL/TLS (mbedTLS, used for
FFmpeg's own HTTPS support) is kept current as a priority.

A handful of dependencies needed source patches beyond the version pin to stay
XP-compatible -- most commonly a library unconditionally using a Windows
Vista+-only API (`SRWLOCK`/`CONDITION_VARIABLE`/`InitOnce*`/`BCryptGenRandom`)
in its Windows code path instead of falling back to the POSIX `pthread`/legacy
CryptoAPI path this build already provides via `pthreads-win32`. All such
patches live in `patches/` and are referenced from the relevant `build_X()`
function in `cross_compile_ffmpeg.sh` with a comment explaining the issue.

### What this doesn't catch

`scripts/check-xp-compat.sh` only checks the PE header and the *statically
imported* symbol table. It cannot catch:
- APIs loaded dynamically via `GetProcAddress` at runtime (harder to abuse
  accidentally, but not impossible).
- Behavioral differences where a function exists on XP but behaves
  differently (rare, but not zero).
- Anything that only manifests at actual runtime on XP hardware/VM (timing,
  driver, or codec-specific issues).

Treat a clean audit as "very likely fine", not "guaranteed" -- an actual test
run on real XP hardware (or a VM) remains the real verification step. As of
2026-08-07 the `win32-core2` target has been built, audited clean (including
via `--xp-system32=` against a real XP SP3 DLL set), **and confirmed working
on real Windows XP SP3 32-bit hardware**. The other CPU/arch tiers in
`scripts/build-matrix.sh` haven't been built or tested yet.

### Known flaky upstream mirrors

A few upstream download URLs baked into `cross_compile_ffmpeg.sh` have gone
stale or unreliable over time (this is unrelated to XP-compatibility, just
normal link rot on a script whose dependencies track moving git branches):
- `zlib.net` dropped the pinned 1.3.1 tarball -- now fetched from the GitHub
  release asset instead.
- `download.savannah.gnu.org` intermittently/persistently 502s on the
  freetype tarball -- now fetched from SourceForge instead.

If a fresh mirror also goes down, that's not a code bug in this fork --
just swap `download_and_unpack_file`'s URL for a working mirror of the same
version.
