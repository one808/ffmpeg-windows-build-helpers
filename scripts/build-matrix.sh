#!/usr/bin/env bash
# Build every CPU tier in the supported target matrix, one after another.
#
# Each tier gets its own independently resumable podman container (via
# scripts/build.sh --tier=NAME) and its own dependency-build subdirectory
# under ffmpeg_local_builds/sandbox/ (win32-<tier> or win64-<tier>) -- only
# the mingw-w64 cross-compiler toolchain is shared between tiers of the same
# bitness (cross_compilers/mingw-w64-i686 or cross_compilers/mingw-w64-x86_64),
# so the first 32-bit tier and the first 64-bit tier you build each pay the
# one-time cost of building their toolchain; every other tier of that
# bitness reuses it.
#
# Usage: scripts/build-matrix.sh [--only=tier1,tier2,...] [--audit] [--cpus N]
#   --only=LIST  Comma-separated subset of tier names (see MATRIX below).
#                Default: build every tier.
#   --audit      Run scripts/check-xp-compat.sh against each tier right
#                after it finishes building.
#   --cpus N     Passed through to scripts/build.sh (default: 4, or
#                $FFMPEG_XP_CPUS).
#
# Each tier is a full from-scratch dependency + FFmpeg build (only the
# toolchain is shared) -- expect several hours per tier on top of the first
# one. Safe to interrupt and re-run: scripts/build.sh resumes each tier's
# container rather than recreating it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# tier:arch:cflags
# Concrete -march= names only (not x86-64-v2/v3 -- this toolchain's GCC
# 10.4.0 predates that microarch-level syntax).
MATRIX=(
  "pentium3:32:-O2 -march=pentium3 -mtune=pentium3"
  "pentium-m:32:-O2 -march=pentium-m -mtune=pentium-m"
  "athlon64:32:-O2 -march=athlon64 -mtune=athlon64"
  "core2:32:-O2 -march=core2 -mtune=core2"
  "amdfam10:32:-O2 -march=amdfam10 -mtune=amdfam10"
  "nehalem:32:-O2 -march=nehalem -mtune=nehalem"
  "athlon64-64:64:-O2 -march=athlon64 -mtune=athlon64"
  "sandybridge-64:64:-O2 -march=sandybridge -mtune=sandybridge"
)

only=""
audit=0
cpus="${FFMPEG_XP_CPUS:-4}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only=*) only="${1#*=}"; shift ;;
    --audit) audit=1; shift ;;
    --cpus) cpus="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

wanted() {
  [[ -z "$only" ]] && return 0
  local t="$1" name
  IFS=',' read -ra names <<<"$only"
  for name in "${names[@]}"; do
    [[ "$name" == "$t" ]] && return 0
  done
  return 1
}

for entry in "${MATRIX[@]}"; do
  IFS=':' read -r tier arch cflags <<<"$entry"
  wanted "$tier" || continue

  echo
  echo "=== Building tier '$tier' (arch=$arch, cflags: $cflags) ==="
  scripts/build.sh --cpus "$cpus" --arch="$arch" --cflags="$cflags" --tier="$tier"

  if [[ "$audit" == 1 ]]; then
    echo "=== Auditing tier '$tier' ==="
    scripts/check-xp-compat.sh --target="win${arch}-${tier}"
  fi
done

echo
echo "Matrix build complete. Release archives are under redist/ (one dated"
echo "folder per tier per run -- see BUILD_INFO.txt in each for the exact target)."
