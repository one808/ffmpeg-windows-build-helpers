#!/usr/bin/env bash
# Audit built FFmpeg .exe files for Windows XP compatibility:
#   1. PE subsystem version must not exceed XP's 5.1 ceiling.
#   2. No imported symbol known to be Windows Vista-or-newer only.
#
# A binary that fails check 2 will typically crash on real XP with:
#   "The procedure entry point X could not be located in the dynamic
#    link library Y.dll"
# -- at runtime, not at build time, which is why this check matters even
# after a clean build.
#
# Runs objdump via the build's own podman image, so it works even without
# i686-w64-mingw32-objdump in the host PATH.
#
# Usage: scripts/check-xp-compat.sh [--target=win32-core2] [exe-name ...]
#   (defaults to ffmpeg.exe ffplay.exe ffprobe.exe in the win32-core2 FFmpeg build dir)
# --target= is the build_subdir name cross_compile_ffmpeg.sh used, e.g. "win32-pentium3" or
# "win64-sandybridge" (see scripts/build-matrix.sh for the full tier list). A "win64-*" target
# switches to the x86_64-w64-mingw32 objdump and raises the PE subsystem ceiling to 5.2 (Windows
# XP x64 Edition/Server 2003's actual floor) instead of regular 32-bit XP's 5.1.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE=ffmpeg-xp-builder:baseline
TARGET=win32-core2

exe_names=()
for arg in "$@"; do
  case "$arg" in
    --target=*) TARGET="${arg#*=}" ;;
    *) exe_names+=("$arg") ;;
  esac
done
[[ ${#exe_names[@]} -eq 0 ]] && exe_names=(ffmpeg.exe ffplay.exe ffprobe.exe)

case "$TARGET" in
  win64-*) mingw_arch_dir=mingw-w64-x86_64; host_target=x86_64-w64-mingw32; subsys_ceiling_major=5; subsys_ceiling_minor=2 ;;
  win32-*) mingw_arch_dir=mingw-w64-i686;   host_target=i686-w64-mingw32;   subsys_ceiling_major=5; subsys_ceiling_minor=1 ;;
  *) echo "--target must start with 'win32-' or 'win64-' (got '$TARGET')" >&2; exit 1 ;;
esac
FFMPEG_DIR="ffmpeg_local_builds/sandbox/$TARGET/FFmpeg_git"
OBJDUMP="ffmpeg_local_builds/sandbox/cross_compilers/$mingw_arch_dir/bin/${host_target}-objdump"

# Symbols first introduced in Windows Vista (or later) that have bitten this
# build before, or are classic mingw/FFmpeg-on-XP landmines. Not exhaustive --
# add to this list if a new one turns up in a runtime "procedure entry point
# not found" error.
BLOCKLIST_REGEX='\<(CancelIoEx|BCryptGenRandom|BCryptOpenAlgorithmProvider|BCryptCloseAlgorithmProvider|InitOnceExecuteOnce|InitOnceBeginInitialize|InitOnceComplete|InitializeSRWLock|AcquireSRWLockExclusive|AcquireSRWLockShared|ReleaseSRWLockExclusive|ReleaseSRWLockShared|TryAcquireSRWLockExclusive|TryAcquireSRWLockShared|InitializeConditionVariable|WakeConditionVariable|WakeAllConditionVariable|SleepConditionVariableCS|SleepConditionVariableSRW|GetTickCount64|CreateSymbolicLinkA|CreateSymbolicLinkW|SetThreadDescription|GetFileInformationByHandleEx|SetFileInformationByHandle|GetLogicalProcessorInformation|GetLogicalProcessorInformationEx|K32EnumProcesses|CreateWaitableTimerExA|CreateWaitableTimerExW|GetSystemTimePreciseAsFileTime|WSAPoll|GetAddrInfoExA|GetAddrInfoExW|wcscpy_s|wcscat_s|strcpy_s|strcat_s|vsnprintf_s|_vsnprintf_s|sprintf_s|memcpy_s|_mktemp_s)\>'

if ! podman image exists "$IMAGE"; then
  echo "Image $IMAGE not found -- run scripts/build.sh first." >&2
  exit 1
fi

overall_fail=0
for name in "${exe_names[@]}"; do
  exe_rel="$FFMPEG_DIR/$name"
  if [[ ! -f "$exe_rel" ]]; then
    echo "SKIP $name (not found at $exe_rel -- build it first)"
    continue
  fi

  echo "== $name =="
  dump=$(podman run --rm -v "$(pwd)":/work:Z "$IMAGE" \
    bash -lc "/work/$OBJDUMP -p /work/$exe_rel")

  major=$(grep -m1 -i "MajorSubsystemVersion" <<<"$dump" | awk '{print $2}')
  minor=$(grep -m1 -i "MinorSubsystemVersion" <<<"$dump" | awk '{print $2}')
  echo "  PE subsystem version: ${major}.${minor} (ceiling: ${subsys_ceiling_major}.${subsys_ceiling_minor})"
  if (( major > subsys_ceiling_major || (major == subsys_ceiling_major && minor > subsys_ceiling_minor) )); then
    echo "  FAIL: subsystem version exceeds XP -- will refuse to launch on real XP."
    overall_fail=1
  fi

  hits=$(grep -oE "$BLOCKLIST_REGEX" <<<"$dump" | sort -u || true)
  if [[ -n "$hits" ]]; then
    echo "  FAIL: Vista+-only import(s) found:"
    sed 's/^/    /' <<<"$hits"
    overall_fail=1
  else
    echo "  OK: no known Vista+-only imports."
  fi
  echo
done

if [[ $overall_fail -eq 0 ]]; then
  echo "All checked binaries look XP-safe. This is a static/import-level check,"
  echo "not a substitute for actually running them on XP (or an XP VM)."
else
  echo "One or more binaries FAILED the XP-compatibility audit." >&2
fi
exit $overall_fail
