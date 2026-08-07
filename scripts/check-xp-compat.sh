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
# Usage: scripts/check-xp-compat.sh [--target=win32-core2] [--xp-system32=DIR] [exe-name ...]
#   (defaults to ffmpeg.exe ffplay.exe ffprobe.exe in the win32-core2 FFmpeg build dir)
# --target= is the build_subdir name cross_compile_ffmpeg.sh used, e.g. "win32-pentium3" or
# "win64-sandybridge" (see scripts/build-matrix.sh for the full tier list). A "win64-*" target
# switches to the x86_64-w64-mingw32 objdump and raises the PE subsystem ceiling to 5.2 (Windows
# XP x64 Edition/Server 2003's actual floor) instead of regular 32-bit XP's 5.1.
#
# --xp-system32=DIR switches check 2 from a hand-maintained blocklist to a ground-truth check:
# DIR should contain real Windows XP system DLLs (kernel32.dll, msvcrt.dll, advapi32.dll, ...) --
# every imported symbol is then verified against that DLL's *actual* export table (via objdump),
# instead of against a list of "Vista+-only symbols we happen to already know about". This is
# strictly more accurate -- the blocklist has already missed real cases twice (see git log) simply
# because nobody had enumerated every post-XP addition to every DLL in advance. DLLs referenced by
# the .exe but not found in DIR fall back to the blocklist check, so a partial DLL set still helps.
# Never commit real Windows DLLs to this repo -- they're Microsoft copyrighted binaries; keep DIR
# out of version control (e.g. under a gitignored ffmpeg_local_builds/xp-reference-dlls/).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE=ffmpeg-xp-builder:baseline
TARGET=win32-core2
XP_SYSTEM32=""

exe_names=()
for arg in "$@"; do
  case "$arg" in
    --target=*) TARGET="${arg#*=}" ;;
    --xp-system32=*) XP_SYSTEM32="${arg#*=}" ;;
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

if [[ -n "$XP_SYSTEM32" ]]; then
  if [[ ! -d "$XP_SYSTEM32" ]]; then
    echo "--xp-system32 path '$XP_SYSTEM32' is not a directory" >&2
    exit 1
  fi
  echo "Ground-truth mode: verifying imports against real DLLs in $XP_SYSTEM32"
  echo "(DLLs not found there fall back to the blocklist check below.)"
  echo
fi

# Symbols first introduced in Windows Vista (or later) that have bitten this
# build before, or are classic mingw/FFmpeg-on-XP landmines. Not exhaustive --
# add to this list if a new one turns up in a runtime "procedure entry point
# not found" error. Used as-is when --xp-system32 isn't given, and as a
# fallback for any DLL --xp-system32 doesn't have a reference copy of.
# The trailing '[a-zA-Z_][a-zA-Z0-9_]*_s' branch is a generic backstop for the whole "secure CRT" function
# family (fopen_s, strncpy_s, strtok_s, _ftime32_s, ...): these were added to msvcrt.dll's newer VC2005+
# side-by-side redistributables (msvcr80.dll+) but never backported into Windows XP's own system msvcrt.dll --
# mingw-w64's headers declare them regardless (assuming a newer CRT), so any dependency that calls one creates a
# static import XP's msvcrt.dll can't satisfy. No legitimate pre-XP Win32/CRT export uses this naming
# convention, so this catch-all is safe and exists specifically because enumerating each one by name (as the
# first few entries below still do, for documentation) has already missed real cases twice.
BLOCKLIST_REGEX='\<(CancelIoEx|BCryptGenRandom|BCryptOpenAlgorithmProvider|BCryptCloseAlgorithmProvider|InitOnceExecuteOnce|InitOnceBeginInitialize|InitOnceComplete|InitializeSRWLock|AcquireSRWLockExclusive|AcquireSRWLockShared|ReleaseSRWLockExclusive|ReleaseSRWLockShared|TryAcquireSRWLockExclusive|TryAcquireSRWLockShared|InitializeConditionVariable|WakeConditionVariable|WakeAllConditionVariable|SleepConditionVariableCS|SleepConditionVariableSRW|GetTickCount64|CreateSymbolicLinkA|CreateSymbolicLinkW|SetThreadDescription|GetFileInformationByHandleEx|SetFileInformationByHandle|GetLogicalProcessorInformation|GetLogicalProcessorInformationEx|K32EnumProcesses|CreateWaitableTimerExA|CreateWaitableTimerExW|GetSystemTimePreciseAsFileTime|WSAPoll|GetAddrInfoExA|GetAddrInfoExW|inet_ntop|inet_pton|WSASendMsg|GetActiveProcessorCount|GetActiveProcessorGroupCount|GetMaximumProcessorCount|GetThreadGroupAffinity|SetThreadGroupAffinity|GetNumaProcessorNodeEx|GetNumaNodeProcessorMaskEx|GetNumaHighestNodeNumberEx|CreateFile2|InitializeProcThreadAttributeList|UpdateProcThreadAttribute|IsWow64Process2|[a-zA-Z_][a-zA-Z0-9_]*_s)\>'

if ! podman image exists "$IMAGE"; then
  echo "Image $IMAGE not found -- run scripts/build.sh first." >&2
  exit 1
fi

# Run objdump -p on a file (exe or real DLL) inside the build image. Caches nothing itself --
# callers cache as needed.
objdump_p() {
  podman run --rm -v "$(pwd)":/work:Z "$IMAGE" bash -lc "/work/$OBJDUMP -p '/work/$1'"
}

# Extract the exported symbol names from a real DLL's objdump -p output (its
# "[Ordinal/Name Pointer] Table" section -- one name per line, name is always
# the last whitespace-separated token).
extract_exports() {
  awk '
    /\[Ordinal\/Name Pointer\] Table/ { f=1; next }
    f && /^[[:space:]]*$/ { exit }
    f && /^\t\[/ { print $NF }
  '
}

# Cache of "dllname -> newline-separated export list" for real DLLs already looked up this run,
# keyed by lowercase DLL name. Associative array survives across the exe loop below.
declare -A real_exports_cache
declare -A real_dll_path_cache  # lowercase name -> resolved path, or "" if not found (checked once)

find_real_dll() {
  local name_lc="$1"
  if [[ -v real_dll_path_cache["$name_lc"] ]]; then
    printf '%s' "${real_dll_path_cache[$name_lc]}"
    return
  fi
  local found=""
  # Case-insensitive filename match anywhere directly under XP_SYSTEM32.
  while IFS= read -r -d '' f; do found="$f"; break; done < <(find "$XP_SYSTEM32" -maxdepth 1 -iname "$name_lc" -print0 2>/dev/null)
  real_dll_path_cache["$name_lc"]="$found"
  printf '%s' "$found"
}

get_real_exports() {
  local name_lc="$1" dll_path="$2"
  if [[ -v real_exports_cache["$name_lc"] ]]; then
    printf '%s' "${real_exports_cache[$name_lc]}"
    return
  fi
  local exports
  exports=$(objdump_p "$dll_path" | extract_exports | sort -u)
  real_exports_cache["$name_lc"]="$exports"
  printf '%s' "$exports"
}

overall_fail=0
for name in "${exe_names[@]}"; do
  exe_rel="$FFMPEG_DIR/$name"
  if [[ ! -f "$exe_rel" ]]; then
    echo "SKIP $name (not found at $exe_rel -- build it first)"
    continue
  fi

  echo "== $name =="
  dump=$(objdump_p "$exe_rel")

  major=$(grep -m1 -i "MajorSubsystemVersion" <<<"$dump" | awk '{print $2}')
  minor=$(grep -m1 -i "MinorSubsystemVersion" <<<"$dump" | awk '{print $2}')
  echo "  PE subsystem version: ${major}.${minor} (ceiling: ${subsys_ceiling_major}.${subsys_ceiling_minor})"
  if (( major > subsys_ceiling_major || (major == subsys_ceiling_major && minor > subsys_ceiling_minor) )); then
    echo "  FAIL: subsystem version exceeds XP -- will refuse to launch on real XP."
    overall_fail=1
  fi

  if [[ -z "$XP_SYSTEM32" ]]; then
    # Blocklist-only mode (original behavior): scan the whole dump at once.
    hits=$(grep -oE "$BLOCKLIST_REGEX" <<<"$dump" | sort -u || true)
    if [[ -n "$hits" ]]; then
      echo "  FAIL: Vista+-only import(s) found:"
      sed 's/^/    /' <<<"$hits"
      overall_fail=1
    else
      echo "  OK: no known Vista+-only imports."
    fi
    echo
    continue
  fi

  # Ground-truth mode: walk each imported DLL's own symbol list separately.
  dll_names=$(grep -oE '^\s*DLL Name: .+$' <<<"$dump" | sed -E 's/^\s*DLL Name: //' | sort -u)
  any_fail_this_exe=0
  while IFS= read -r dll_name; do
    [[ -z "$dll_name" ]] && continue
    dll_lc=$(tr '[:upper:]' '[:lower:]' <<<"$dll_name")
    imports=$(awk -v dn="$dll_name" '
      $0 ~ ("DLL Name: " dn "$") { f=1; next }
      f && /DLL Name:/ { exit }
      f && /^\t[0-9a-fx]+\t/ { print $NF }
    ' <<<"$dump")
    [[ -z "$imports" ]] && continue

    real_dll=$(find_real_dll "$dll_lc")
    if [[ -n "$real_dll" ]]; then
      real_list=$(get_real_exports "$dll_lc" "$real_dll")
      missing=$(comm -23 <(sort -u <<<"$imports") <(sort -u <<<"$real_list"))
      if [[ -n "$missing" ]]; then
        echo "  FAIL: $dll_name -- import(s) not in real DLL's export table ($real_dll):"
        sed 's/^/    /' <<<"$missing"
        overall_fail=1
        any_fail_this_exe=1
      else
        echo "  OK: $dll_name -- all $(wc -l <<<"$imports") import(s) verified against $real_dll."
      fi
    else
      # No reference DLL available -- fall back to the blocklist for this DLL's imports only.
      hits=$(grep -oE "$BLOCKLIST_REGEX" <<<"$imports" | sort -u || true)
      if [[ -n "$hits" ]]; then
        echo "  FAIL: $dll_name (no reference DLL found, checked via blocklist) -- known-bad import(s):"
        sed 's/^/    /' <<<"$hits"
        overall_fail=1
        any_fail_this_exe=1
      else
        echo "  (unverified: no reference DLL for $dll_name -- blocklist-only check, found nothing)"
      fi
    fi
  done <<<"$dll_names"
  [[ $any_fail_this_exe -eq 0 ]] && echo "  OK: all imports verified against real DLLs (or blocklist-clean where unverified)."
  echo
done

if [[ $overall_fail -eq 0 ]]; then
  echo "All checked binaries look XP-safe. This is a static/import-level check,"
  echo "not a substitute for actually running them on XP (or an XP VM)."
else
  echo "One or more binaries FAILED the XP-compatibility audit." >&2
fi
exit $overall_fail
