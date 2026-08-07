#!/usr/bin/env bash
# Build (or resume) the WinXP-compatible FFmpeg cross-build inside a
# disposable, host-isolated podman container.
#
# Safe to re-run: an existing container is *resumed*, not recreated, so the
# cross-compiler and the native host tools it built into the container's own
# /usr (python/cmake/nasm) survive between runs. The downloaded/compiled
# sources under ffmpeg_local_builds/sandbox/ are bind-mounted from the host
# and always survive regardless of the container's lifecycle.
#
# Usage: scripts/build.sh [--rebuild-image] [--clean] [--cpus N] [--arch=32|64] [--cflags=...] [--tier=NAME]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE=ffmpeg-xp-builder:baseline
CPUS="${FFMPEG_XP_CPUS:-4}"
ARCH=32
CFLAGS=""
TIER="" # Short label for this target, e.g. "pentium3" or "nehalem-64" -- picks the container name and log file, so
        # each CPU tier/arch combo gets its own independently resumable container. Empty (the default) preserves
        # the original single-target names exactly: container "ffmpeg-xp-baseline", log "logs/build.log".

usage() {
  cat <<EOF
Usage: $0 [--rebuild-image] [--clean] [--cpus N] [--arch=32|64] [--cflags=STRING] [--tier=NAME]

  --rebuild-image  Rebuild the podman image from Containerfile even if it
                    already exists.
  --clean          Remove the existing build container first, so native
                    host-tool installs (python/cmake/nasm under /usr) start
                    fresh. Does NOT touch ffmpeg_local_builds/sandbox/ (the
                    downloaded sources and cross-compiler) -- that only goes
                    away if you delete it yourself.
  --cpus N         CPU limit passed to 'podman run --cpus' (default: 4, or
                    \$FFMPEG_XP_CPUS).
  --arch=32|64     Passed through to cross_compile_ffmpeg.sh's --arch=
                    (default: 32). 64 targets Windows XP x64 Edition/Server
                    2003, not regular 32-bit XP.
  --cflags=STRING  Passed through to cross_compile_ffmpeg.sh's --cflags=
                    (default: the script's own, currently -march=core2).
  --tier=NAME      Short label for this build target (e.g. "pentium3",
                    "nehalem-64") -- selects the container name
                    ("ffmpeg-xp-\$TIER") and log file
                    ("logs/build-\$TIER.log") so each CPU tier gets its own
                    independently resumable container. Omit for the
                    original single-target behavior (container
                    "ffmpeg-xp-baseline", log "logs/build.log"). See
                    scripts/build-matrix.sh to build every tier in one go.

Notes:
  - Networking is forced IPv4-only ('podman run --network pasta:-4'). Some
    mirrors (e.g. savannah.gnu.org) have flaky/broken IPv6 routes that hang
    rather than fail, which otherwise looks like the build is stuck.
  - If a source tarball's URL has died, that's not a code bug -- see
    ffmpeg_local_builds/cross_compile_ffmpeg.sh's download_and_unpack_file
    calls and swap in a working mirror (git log has precedent: zlib.net and
    savannah.gnu.org both needed this).
EOF
}

rebuild_image=0
clean=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild-image) rebuild_image=1; shift ;;
    --clean) clean=1; shift ;;
    --cpus) CPUS="$2"; shift 2 ;;
    --arch=*) ARCH="${1#*=}"; shift ;;
    --cflags=*) CFLAGS="${1#*=}"; shift ;;
    --tier=*) TIER="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

CONTAINER="ffmpeg-xp-${TIER:-baseline}"
LOG="logs/build${TIER:+-$TIER}.log"

# Build the inner cross_compile_ffmpeg.sh invocation. --cflags= is only added if set, so the default run keeps
# using the script's own built-in default CFLAGS untouched (avoids re-quoting/re-stating it here).
inner_cmd="cd /work/ffmpeg_local_builds && ./cross_compile_ffmpeg.sh -d --sandbox-ok=y --arch=$ARCH"
[[ -n "$CFLAGS" ]] && inner_cmd+=" --cflags='$CFLAGS'"

mkdir -p logs

if [[ "$rebuild_image" == 1 ]] || ! podman image exists "$IMAGE"; then
  echo "Building podman image $IMAGE from Containerfile..."
  podman build -t "$IMAGE" -f Containerfile .
fi

if [[ "$clean" == 1 ]]; then
  echo "Removing existing container $CONTAINER (if any)..."
  podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
fi

set +e
if podman container exists "$CONTAINER"; then
  echo "Resuming existing container $CONTAINER..."
  podman start -a "$CONTAINER" 2>&1 | tee "$LOG"
  status=$?
else
  echo "Creating container $CONTAINER (cpus=$CPUS, arch=$ARCH${CFLAGS:+, cflags=$CFLAGS})..."
  podman run --name "$CONTAINER" --cpus="$CPUS" --network pasta:-4 \
    -v "$(pwd)":/work:Z \
    "$IMAGE" \
    bash -lc "$inner_cmd" \
    2>&1 | tee "$LOG"
  status=$?
fi
set -e

echo
if [[ $status -eq 0 ]]; then
  echo "Build succeeded. Log: $LOG"
  echo "Artifacts: see redist/ for the dated release folder (BUILD_INFO.txt inside names the exact target)."
  echo
  echo "Run scripts/check-xp-compat.sh to verify Windows XP compatibility."
else
  echo "Build FAILED (exit $status). See $LOG for the error." >&2
fi
exit $status
