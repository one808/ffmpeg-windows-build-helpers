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
ffmpeg_local_builds/sandbox/win32/FFmpeg_git/{ffmpeg,ffplay,ffprobe}.exe
```

and a packaged release archive at
`redist/<timestamp>_ffmpeg-<version>_winxp-<cpu>-<bits>/ffmpeg-*-static-winxp-*.7z`
-- each build run gets its own dated folder (e.g.
`redist/2026_08_07_14_30_00_ffmpeg-n8.1.2_winxp-core2-32bit/`), containing a
`BUILD_INFO.txt` (version/target/CFLAGS summary) and a `SHA256SUMS` alongside
every `.7z` produced that run.

`scripts/check-xp-compat.sh` inspects those `.exe` files' PE headers and
import tables (via `objdump`, run inside the same podman image) and fails if
it finds either a subsystem version above XP's 5.1 ceiling, or an imported
symbol known to exist only on Windows Vista or later (`CancelIoEx`,
`BCryptGenRandom`, `InitializeSRWLock`, `GetTickCount64`, the `_s`-suffixed
"secure" CRT functions, etc.). This is a static check, not a substitute for
actually running the result on real XP (or an XP VM) -- see "What this
doesn't catch" below.

### `scripts/build.sh` options

```
scripts/build.sh [--rebuild-image] [--clean] [--cpus N]
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
  `rm -rf ffmpeg_local_builds/sandbox/win32` -- that deletes the `.git`
  checkouts too and forces every dependency to be re-cloned from scratch
  (~50 git repositories, some large: FFmpeg itself, x265, aom, libjxl +
  submodules, AviSynthPlus, libvpx, libwebp, SVT-AV1, ...). For those, force a
  recompile *without* re-cloning instead:
  ```sh
  # inside a throwaway container, since the sandbox is root-owned:
  podman run --rm -v "$(pwd)":/work:Z ffmpeg-xp-builder:baseline \
    bash -lc 'cd /work/ffmpeg_local_builds/sandbox/win32 && for d in */; do
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

`original_cflags` in `ffmpeg_local_builds/cross_compile_ffmpeg.sh` is set to
`-march=core2 -mtune=core2`. Change it if your target CPU differs -- the
upstream default (`-march=pentium3 -mtune=athlon-xp -msse`) is far more
conservative (SSE-only, no SSE2) and only makes sense if you're actually
targeting a pre-SSE2 CPU.

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
run on a Windows XP SP3 VM remains the real verification step.

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
