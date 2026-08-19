#!/usr/bin/env bash
# ffmpeg windows cross compile helper/download script, see github repo README
# Copyright (C) 2012 Roger Pack, the script is under the GPLv3, but output FFmpeg's executables aren't

yes_no_sel() {
  unset user_input
  local question="$1"
  shift
  local default_answer="$1"
  while [[ "$user_input" != [YyNn] ]]; do
    echo -n "$question"
    read user_input
    if [[ -z "$user_input" ]]; then
      echo "using default $default_answer"
      user_input=$default_answer
    fi
    if [[ "$user_input" != [YyNn] ]]; then
      clear; echo 'Your selection was not vaild, please try again.'; echo
    fi
  done
  # downcase it
  user_input=$(echo $user_input | tr '[A-Z]' '[a-z]')
}

set_box_memory_size_bytes() {
  local ram_kilobytes=`grep MemTotal /proc/meminfo | awk '{print $2}'`
  local swap_kilobytes=`grep SwapTotal /proc/meminfo | awk '{print $2}'`
  box_memory_size_bytes=$[ram_kilobytes * 1024 + swap_kilobytes * 1024]
}

check_missing_packages() {
  # zeranoe's build scripts use wget, though we don't here...
  local check_packages=('7z' 'autoconf' 'autogen' 'automake' 'bison' 'bzip2' 'cmake' 'cvs' 'ed' 'flex' 'g++' 'gcc' 'git' 'gperf' 'hg' 'libtool' 'libtoolize' 'make' 'makeinfo' 'patch' 'pax' 'pkg-config' 'svn' 'unzip' 'wget' 'xz' 'yasm')
  for package in "${check_packages[@]}"; do
    type -P "$package" >/dev/null || missing_packages=("$package" "${missing_packages[@]}")
  done
  if [[ -n "${missing_packages[@]}" ]]; then
    clear
    echo "Could not find the following execs (7z = p7zip, hg = mercurial, makeinfo = texinfo, svn = subversion): ${missing_packages[@]}"
    echo 'Install the missing packages before running this script.'
    exit 1
  fi

  if [ ! -f $HOME/.hgrc ]; then # 'hg purge' (the Mercurial equivalent of 'git clean') isn't enabled by default.
    mkdir -p "$HOME"
    cat > $HOME/.hgrc <<EOF
[extensions]
purge =
EOF
  fi

  if [[ ! -f /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.done ]]; then # Update SSL certificates.
    wget --no-check-certificate -O /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem https://curl.se/ca/cacert.pem
    touch /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.done
  fi # Prevents wget error-messages like "ERROR: The certificate of `<some website>' is not trusted" by updating 'tls-ca-bundle.pem'.
}


intro() {
  echo `date`
  cat <<EOL
     ##################### Welcome ######################
  Welcome to the ffmpeg cross-compile builder-helper script.
  Downloads and builds will be installed to directories within $cur_dir
  If this is not ok, then exit now, and cd to the directory where you'd
  like them installed, then run this script again from there.
  NB that once you build your compilers, you can no longer rename/move
  the sandbox directory, since it will have some hard coded paths in there.
  You can, of course, rebuild ffmpeg from within it, etc.
EOL
  if [[ $sandbox_ok != 'y' && ! -d sandbox ]]; then
    echo -e "\nBuilding in $PWD/sandbox, will use ~ 4GB space!\n"
  fi
  mkdir -p "$cur_dir"
  cd "$cur_dir"
}

install_cross_compiler() {
  # $mingw_w64_build_type/$mingw_arch_dir/$host_target are set from --arch= above (32 -> win32/i686, 64 -> win64/x86_64).
  # The two arches' toolchains live in separate cross_compilers/mingw-w64-{i686,x86_64}/ subdirectories and don't
  # collide, so all 32-bit CPU tiers share one toolchain build and both 64-bit tiers share the other -- only the
  # per-tier dependency/FFmpeg build tree (win${target_arch}-${cpu_target_label}/, set up further below) differs.
  local target_gcc="cross_compilers/${mingw_arch_dir}/bin/${host_target}-gcc"
  if [[ -f $target_gcc ]]; then
    echo -e "MinGW-w64 compilers for ${mingw_w64_build_type} already installed, not re-installing.\n"
  else
    mkdir -p cross_compilers
    cd cross_compilers
      unset CFLAGS # don't want these "windows target" settings used the compiler itself since it creates executables to run on the local box (we have a parameter allowing them to set them for the script "all builds" basically)
      # pthreads version to avoid having to use cvs for it
      echo -e "Starting to download and build cross compile version of gcc [requires working internet access] with thread count $gcc_cpu_count.\n"

      # --disable-shared allows c++ to be distributed at all...which seemed necessary for some random dependency which happens to use/require c++...
      echo "Building ${mingw_w64_build_type} cross compiler."
      cp -v $patch_dir/mingw-w64-build-r33 .   # https://files.1f0.de/mingw/scripts/
      ./mingw-w64-build-r33 --build-type=$mingw_w64_build_type --default-configure --cpu-count=$gcc_cpu_count --pthreads-w32-ver=2-9-1 --disable-shared --clean-build --verbose || exit 1
      if [[ ! -f ../$target_gcc ]]; then
        echo "Failure building ${target_arch}-bit gcc? Recommend nuke sandbox (rm -fr sandbox) and start over."
        exit 1
      fi

      rm -f build.log # left over stuff...
      reset_cflags
    cd ..
    echo "Done building (or already built) MinGW-w64 cross-compiler(s) successfully."
    echo -e "$(date)\n" # so they can see how long it took :)
  fi
}

do_svn_checkout() {
  local dir="$2"
  if [ ! -d $dir ]; then
    echo -e "\e[1;33mDownloading (svn checkout) ${1##*/} to $dir.\e[0m"
    if [[ $3 ]]; then
      svn checkout -r $3 $1 $dir.tmp || exit 1
    else
      svn checkout $1 $dir.tmp --non-interactive --trust-server-cert-failures=unknown-ca || exit 1
    fi
    mv $dir.tmp $dir
  else
    cd $dir
      if [[ $(svn info --show-item revision) != $(svn info --show-item revision $1) ]]; then
        echo -e "\e[1;33mUpdating $dir to latest svn revision.\e[0m"
        svn revert . -R # Return files to their original state.
        svn cleanup --remove-ignored # Clean the working tree; build- ...
        svn cleanup --remove-unversioned # ...as well as untracked files.
        svn update || exit 1
      else
        echo -e "\e[1;33mLocal $dir is up-to-date.\e[0m"
      fi
    cd ..
  fi
}

do_git_checkout() {
  if [[ $2 ]]; then
    local dir="$2"
  else
    local dir=$(basename ${1/.git/_git}) # http://y/abc.git -> abc_git
  fi
  if [[ $3 ]]; then
    local branch="$3"
  else
    local branch="master" # http://y/abc.git -> abc_git
  fi
  if [ ! -d $dir ]; then
    rm -fr $dir.tmp # just in case it was interrupted previously...
    echo -e "\e[1;33mDownloading (git clone) $1 to $dir.\e[0m"
    # Retry git clone with backoff -- some upstreams are intermittently
    # unreachable from CI runners (e.g. gitlab.com SVT-AV1); a single failure
    # should not abort the entire build.
    local clone_ok=0 max_attempts=5 attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
      attempt=$((attempt + 1))
      if git clone --branch "$branch" --single-branch "$1" "$dir.tmp" 2>/dev/null; then
        clone_ok=1
        break
      fi
      echo -e "\e[1;33m  git clone attempt $attempt/$max_attempts failed, retrying...\e[0m"
      rm -fr "$dir.tmp"
      sleep $((attempt * 5))
    done
    [[ $clone_ok -eq 0 ]] && { echo "fatal: git clone of $1 failed after $max_attempts attempts" >&2; exit 1; }
    # prevent partial checkouts by renaming it only after success
    mv $dir.tmp $dir
    if [[ $4 ]]; then
      cd $dir
        echo -e "\e[1;33mChanging head of $dir to ${4:0:7}.\e[0m"
        git checkout $4 || exit 1
      cd ..
    fi
  else
    cd $dir
      if [[ $4 ]]; then
        if [[ $(git rev-parse HEAD) != $4 ]]; then
          echo -e "\e[1;33mChanging head of $dir to ${4:0:7}.\e[0m"
          git checkout $4 || exit 1
        else
          echo -e "\e[1;33mHead of $dir is already at ${4:0:7}.\e[0m"
        fi
      elif [[ $(git rev-parse HEAD) != $(git ls-remote -h $1 $branch | head -c +40) ]]; then
        echo -e "\e[1;33mUpdating $dir to latest git head on 'origin/$branch'.\e[0m"
        git reset --hard # Return files to their original state.
        git clean -fdx # Clean the working tree; build- as well as untracked files.
        git fetch # Fetch list of changes.
        git checkout $branch || exit 1 # Show amount of commits behind 'origin/$branch'.
        git merge origin/$branch || exit 1 # Apply changes to local repo.
      else
        echo -e "\e[1;33mLocal $dir is up-to-date.\e[0m"
      fi
    cd ..
  fi
}

download_and_unpack_file() {
  local name="${1##*/}"
  if [[ $2 ]]; then
    local dir="$2"
  else
    local dir="${name/.tar*/}" # remove .tar.xx
  fi
  if [ ! -f "$dir/unpacked.successfully" ]; then
    echo -e "\e[1;33mDownloading (wget) $1.\e[0m"
    if [[ -f $name ]]; then
      rm $name || exit 1
    fi
    wget -t 5 "$1" || exit 1
    tar -xf "$name" || unzip "$name" || exit 1
    touch "$dir/unpacked.successfully" || exit 1
    rm "$name" || exit 1
  fi
}

get_small_touchfile_name() { # have to call with assignment like a=$(get_small...)
  echo "$1_$(echo -- "$@" $CFLAGS $LDFLAGS | /usr/bin/env md5sum | sed "s/ //g")" # md5sum to make it smaller, cflags to force rebuild if changes and sed to remove spaces that md5sum introduced.
}

do_configure() {
  if [ "${1:0:2}" == "./" ]; then
    local configure_name=$1
    local configure_options=("${@:2}")
  else
    local configure_name=./configure
    local configure_options=("${@}")
  fi
  local name=$(get_small_touchfile_name already_configured "${configure_options[@]}")
  if [ ! -f "$name" ]; then # This is to generate 'configure', 'Makefile.in' and some other files.
    if [ ! -f $configure_name ]; then
      echo -e "\e[1;33mGenerating 'configure' script.\e[0m"
      if [ -f autogen.sh ]; then
        NOCONFIGURE=1 ./autogen.sh # Without NOCONFIGURE=1 TwoLame's 'autogen.sh' will run 'configure' with no arguments.
      elif [ -f autobuild ]; then
        ./autobuild
      elif [ -f buildconf ]; then
        ./buildconf
      elif [ -f bootstrap ]; then
        ./bootstrap
      elif [ -f bootstrap.sh ]; then
        ./bootstrap.sh
      else
        autoreconf -fiv
      fi
    fi
    echo -e "\e[1;33mConfiguring ${PWD##*/} as \"${configure_options[@]}\".\e[0m"
    $configure_name "${configure_options[@]}" || exit 1
    touch $name || exit 1
  #  echo -e "\e[1;33mDoing preventative make clean.\e[0m"
  #  make -j $cpu_count clean # sometimes useful when files change, etc.
  #else
  #  echo -e "\e[1;33mAlready configured ${PWD##*/}.\e[0m"
  fi
}

generic_configure() {
  do_configure --host=$host_target --prefix=$mingw_w64_x86_64_prefix --disable-shared --enable-static "$@"
}

do_cmake() {
  # NB: no '.exe' suffix on the cross-toolchain binary names here -- that's only
  # correct when the cross-compiler itself was built under Cygwin (PE host tools).
  # Built natively on Linux (as this fork's mingw-w64-build-r33 step does), the
  # host-side gcc/g++/ranlib/windres are plain ELF binaries with no extension.
  local cmake_options=(-DENABLE_STATIC_RUNTIME=1 -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_FIND_ROOT_PATH=$mingw_w64_x86_64_prefix -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY -DCMAKE_RANLIB=${cross_prefix}ranlib -DCMAKE_C_COMPILER=${cross_prefix}gcc -DCMAKE_CXX_COMPILER=${cross_prefix}g++ -DCMAKE_RC_COMPILER=${cross_prefix}windres -DCMAKE_INSTALL_PREFIX=$mingw_w64_x86_64_prefix "${@:2}" $1)
  local name=$(get_small_touchfile_name already_ran_cmake "${cmake_options[@]}")
  if [ ! -f $name ]; then
    echo -e "\e[1;33mConfiguring ${1##*/} as \"cmake -G \"Unix Makefiles\" ${cmake_options[@]}\".\e[0m"
    cmake -G "Unix Makefiles" "${cmake_options[@]}" || exit 1
    touch $name || exit 1
  #else
  #  echo -e "\e[1;33mAlready configured ${1##*/}.\e[0m"
  fi
}

do_meson() { # $1: source dir, "$@" (rest): extra meson options. Run from the desired (out-of-source) build dir.
  local source_dir=$1
  shift
  local meson_options=(--prefix=$mingw_w64_x86_64_prefix --libdir=lib --default-library=static --buildtype=release --cross-file=$meson_cross_file "$@")
  local name=$(get_small_touchfile_name already_ran_meson "${meson_options[@]}" "$source_dir")
  if [ ! -f $name ]; then
    echo -e "\e[1;33mConfiguring ${source_dir##*/} as \"meson setup ${meson_options[@]} . $source_dir\".\e[0m"
    meson setup "${meson_options[@]}" . "$source_dir" || exit 1
    touch $name || exit 1
  fi
}

do_ninja_install() {
  local name=$(get_small_touchfile_name already_ran_ninja "$@")
  if [ ! -f $name ]; then
    echo -e "\e[1;33mCompiling and installing ${PWD%/*} as \"ninja $@ && ninja install\".\e[0m"
    ninja "$@" || exit 1
    ninja install || exit 1
    touch $name || exit 1
  fi
}

do_make() {
  local dir="${PWD/$cur_dir\/$build_subdir\/}"
  local make_options=(-j $cpu_count "$@")
  local name=$(get_small_touchfile_name already_ran_make "${make_options[@]}")
  if [ ! -f $name ]; then
    if [[ $1 == install* ]]; then
      echo -e "\e[1;33mCompiling and installing ${dir%%/*} as \"make ${make_options[@]}\".\e[0m"
    else
      echo -e "\e[1;33mCompiling ${dir%%/*} as \"make ${make_options[@]}\".\e[0m"
    fi
  #  if [ ! -f configure ]; then
  #    make -j $cpu_count clean # just in case helpful if old junk left around and this is a 're make' and wasn't cleaned at reconfigure time
  #  fi
    make "${make_options[@]}" || exit 1
    touch $name || exit 1 # only touch if the build was OK
  else
    if [[ $1 == install* ]]; then
      echo -e "\e[1;33mAlready made and installed ${dir%%/*}.\e[0m"
    else
      echo -e "\e[1;33mAlready made ${dir%%/*}.\e[0m"
    fi
  fi
}

do_make_install() {
  local dir="${PWD/$cur_dir\/$build_subdir\/}"
  local make_install_options=(install "$@")
  local name=$(get_small_touchfile_name already_ran_make_install "${make_install_options[@]}")
  if [ ! -f $name ]; then
    echo -e "\e[1;33mInstalling ${dir%%/*} as \"make ${make_install_options[@]}\".\e[0m"
    make "${make_install_options[@]}" || exit 1
    touch $name || exit 1
  else
    echo -e "\e[1;33mAlready installed ${dir%%/*}.\e[0m"
  fi
}

apply_patch() {
  if [[ $2 ]]; then
    local type=$2 # Git patches need '-p1' (also see https://unix.stackexchange.com/a/26502).
  else
    local type="-p0"
  fi
  local name="${1##*/}"
  if [[ ! -e $name.done ]]; then
    if [[ -f $name ]]; then
      rm $name || exit 1 # remove old version in case it has been since updated on the server...
    fi
    cp -v $1 . || exit 1
    echo -e "\e[1;33mApplying patch '$name'.\e[0m"
    patch $type -i "$name" || exit 1
    touch $name.done || exit 1
    rm -f already_ran* # if it's a new patch, reset everything too, in case it's really really really new
  else
    echo -e "\e[1;33mPatch '$name' already applied.\e[0m"
  fi
}

gen_ld_script() {
  lib=$mingw_w64_x86_64_prefix/lib/$1
  lib_s="${1:3:-2}_s"
  if [ "$1" -nt "$mingw_w64_x86_64_prefix/lib/lib$lib_s.a" ]; then
    rm -f $mingw_w64_x86_64_prefix/lib/lib$lib_s.a
  fi
  if [ ! -f "$mingw_w64_x86_64_prefix/lib/lib$lib_s.a" ]; then
    echo -e "\e[1;33mGenerating linker script for $1, adding $2.\e[0m"
    mv $lib $mingw_w64_x86_64_prefix/lib/lib$lib_s.a
    echo "echo \"GROUP ( -l$lib_s $2 )\" > $lib"
    echo "GROUP ( -l$lib_s $2 )" > $lib
  else
    echo -e "\e[1;33mAlready generated linker script for '$1'.\e[0m"
  fi
} # gen_ld_script libxxx.a -lxxx

build_mingw_std_threads() {
  do_git_checkout https://github.com/meganz/mingw-std-threads.git "" "" c931bac289dd431f1dd30fc4a5d1a7be36668073
  cd mingw-std-threads_git
    for header in *.h; do
      install -m644 ${header} ${mingw_w64_x86_64_prefix}/include/${header}
    done
  cd ..
}

build_python() {
  download_and_unpack_file https://www.python.org/ftp/python/3.4.10/Python-3.4.10.tar.xz
  cd Python-3.4.10
    apply_patch $patch_dir/python-3.4.10_cygwin.patch # Patches from http://cygwinxp.cathedral-networks.org/x86/release/python3/python3-3.4.3-1-src.tar.xz.
    ac_cv_func_bind_textdomain_codeset=yes do_configure --prefix=/usr --with-dbmliborder=gdbm --with-libm=-lm --without-ensurepip # 'configure'-options from 'python3.cygport' from within http://cygwinxp.cathedral-networks.org/x86/release/python3/python3-3.4.3-1-src.tar.xz. NB: '--with-libm=' (empty) is a Cygwin-ism (its libc already has libm); a native glibc host needs '-lm' explicitly or the final link fails with "undefined reference to fmod/pow/sqrt/...".
    do_make install
  cd ..
}

build_cmake() {
  download_and_unpack_file https://cmake.org/files/v3.29/cmake-3.29.2.tar.gz
  cd cmake-3.29.2
    do_configure --prefix=/usr -- -DBUILD_CursesDialog=0 -DBUILD_TESTING=0 # Don't build 'ccmake' (ncurses), or './configure' will fail otherwise.
    # Options after "--" are passed to CMake (Usage: ./bootstrap [<options>...] [-- <cmake-options>...])
    do_make install/strip # This overwrites Cygwin's 'cmake.exe', 'cpack.exe' and 'ctest.exe'.
  cd ..
}

build_nasm() {
  download_and_unpack_file https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/nasm-2.16.03.tar.xz
  cd nasm-2.16.03
    if [[ ! -f Makefile.in.bak ]]; then # Library only and install nasm stripped.
      sed -i.bak '/man1/d;/install:/a\\t$(STRIP) --strip-unneeded nasm$(X) ndisasm$(X)' Makefile.in
    fi
    do_configure --prefix=/usr
    # No '--prefix=$mingw_w64_x86_64_prefix', because NASM has to be built with Cygwin's GCC. Otherwise it can't read Cygwin paths and you'd get errors like "nasm: fatal: unable to open output file `/cygdrive/c/DOCUME~1/Admin/LOCALS~1/Temp/ffconf.Ld8518el/test.o'" while configuring FFmpeg for instance.
    do_make install # 'nasm.exe' and 'ndisasm.exe' will be installed in '/usr/bin' (Cygwin's bin map).
  cd ..
}

build_dlfcn() {
  do_git_checkout https://github.com/dlfcn-win32/dlfcn-win32.git "" "" 8bfddb5aa345ce10ba98e925acbc7bfb53639679
  cd dlfcn-win32_git
    if [[ ! -f Makefile.bak ]]; then # Change GCC optimization level.
      sed -i.bak "s/CFLAGS =/CFLAGS +=/;s/-O3/-O2/" Makefile
    fi
    do_configure --prefix=$mingw_w64_x86_64_prefix --cross-prefix=$cross_prefix # rejects some normal cross compile options so custom here
    do_make
    do_make_install
    gen_ld_script libdl.a -lpsapi # dlfcn-win32's 'README.md': "If you are linking to the static 'dl.lib' or 'libdl.a', then you would need to explicitly add 'psapi.lib' or '-lpsapi' to your linking command, depending on if MinGW is used."
  cd ..
}

build_bzip2() {
  download_and_unpack_file https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz
  cd bzip2-1.0.8
    if [[ ! -f bzlib.h.bak ]]; then # See https://github.com/sherpya/mplayer-be/blob/master/packages/bzip2/patches/00_sherpya_mingw-cross.diff.
      sed -i.bak "s/WINAPI func/func/" bzlib.h
    fi
    cp -vu $patch_dir/bzip2_CMakeLists.txt CMakeLists.txt # See https://github.com/sherpya/mplayer-be/blob/master/packages/bzip2/install/CMakeLists.txt.
    do_cmake $PWD
    do_make install
  cd ..
}

build_liblzma() {
  download_and_unpack_file https://sourceforge.net/projects/lzmautils/files/xz-5.8.3.tar.xz
  cd xz-5.8.3
    generic_configure --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-scripts --disable-doc --disable-nls
    do_make install
  cd ..
} # [dlfcn]

build_zlib() {
  download_and_unpack_file https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.xz # zlib.net doesn't reliably serve older point releases (site only serves the latest 1-2 versions, not even under /fossils).
  cd zlib-1.3.2
    if [[ ! -f Makefile.in.bak ]]; then # Library only.
      sed -i.bak "/man3dir/d" Makefile.in
    fi
    # zlib's hand-written configure (not autoconf) looks for a plain unprefixed
    # "gcc"/"ar" unless told otherwise; there is none in the cross-toolchain bin
    # dir (only i686-w64-mingw32-gcc etc.), so without this it silently falls
    # through PATH to the native host gcc, which then rejects the XP -march flags.
    CC=${cross_prefix}gcc AR=${cross_prefix}ar RANLIB=${cross_prefix}ranlib do_configure --prefix=$mingw_w64_x86_64_prefix --static
    do_make install $make_prefix_options
  cd ..
}

build_iconv() {
  download_and_unpack_file https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.19.tar.gz
  cd libiconv-1.19
    generic_configure --disable-nls
    do_make install-lib # No need for 'do_make_install', because 'install-lib' already has install-instructions.
  cd ..
} # [dlfcn]

build_sdl2() {
  download_and_unpack_file https://libsdl.org/release/SDL2-2.32.10.tar.gz
  cd SDL2-2.32.10
    if [[ ! -f Makefile.in.bak ]]; then
      sed -i.bak "/aclocal/d" Makefile.in # Library only.
      sed -i.bak "/#ifndef DECLSPEC/i\#define DECLSPEC" include/begin_code.h # Needed for building shared FFmpeg libraries.
    fi
    generic_configure --bindir=$mingw_bin_path --enable-libiconv
    do_make install
    if [[ ! -f $mingw_bin_path/${host_target}-sdl2-config ]]; then
      mv -v "$mingw_bin_path/sdl2-config" "$mingw_bin_path/${host_target}-sdl2-config" # At the moment FFmpeg's 'configure' doesn't use 'sdl2-config', because it gives priority to 'sdl2.pc', but when it does, it expects 'i686-w64-mingw32-sdl2-config' in 'cross_compilers/mingw-w64-i686/bin'.
    fi
  cd ..
} # [iconv, dlfcn]

build_libwebp() {
  do_git_checkout https://chromium.googlesource.com/webm/libwebp.git libwebp_git main 506cf14d5fe7f5d908b25ea01e72270052cc82dc
  cd libwebp_git
    apply_patch $patch_dir/libwebp_winxp-compatible_no-srwlock.patch -p1 # src/dsp/cpu.h hard-#errors below Vista because its threaded DSP-init lazy-lock uses SRWLOCK; MinGW already links winpthreads, so just route it onto the existing (already XP-safe) pthread_mutex_t branch instead of the native-Win32 one.
    apply_patch $patch_dir/libwebp_winxp-compatible_no-srwlock-thread-utils.patch -p1 # src/utils/thread_utils.c has its own SRWLOCK-based "simplistic pthread emulation" for _WIN32 (also Vista+ only); route MinGW onto its existing '#include <pthread.h>' branch instead, same reasoning as above.
    if [[ ! -f Makefile.am.bak ]]; then # Library only.
      sed -i.bak "s/src.*/src/;4,\$d" Makefile.am
    fi
    generic_configure --disable-gl --disable-sdl --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic --disable-avx2 # gl/sdl/png/jpeg/tiff/gif/wic are only necessary for building the bundled tools/binaries. avx2: GCC 10.4 fails to inline the _mm256_cvtsi256_si32 intrinsic used in lossless_avx2.c ("undefined reference"); moot anyway since no WinXP-era CPU has AVX2.
    do_make install
  cd ..
} # [dlfcn]

build_libjxl() {
  do_git_checkout https://github.com/libjxl/libjxl.git libjxl_git main e8ff09762481785938d8e4e01333ed3917571161
  cd libjxl_git
    if [[ ! -d .git/modules ]]; then
      echo -e "\e[1;33mDownloading submodules.\e[0m" # 'Brotli' and 'skcms' are the main focus.
       git submodule update --init --recursive
    else
      if [[ $(git --git-dir=.git/modules/third_party/testdata rev-parse HEAD) != $(git ls-remote -h https://github.com/libjxl/testdata.git | head -c +40) ]]; then
        git submodule foreach -q 'git reset --hard' # Return files to their original state.
        git submodule foreach -q 'git clean -fdx' # Clean the working tree; build- as well as untracked files.
        echo -e "\e[1;33mUpdating submodules to latest git head on 'main'.\e[0m"
        git submodule foreach git fetch
        git submodule update --init
        rm -f already_* # Force recompiling.
      else
        echo -e "\e[1;33mLocal submodules are up-to-date.\e[0m"
      fi
    fi
    if [[ ! -f lib/threads/resizable_parallel_runner.cc.bak ]]; then
      sed -i.bak 's/<condition_variable>/"mingw.condition_variable.h"/;s/<mutex>/"mingw.mutex.h"/;s/<thread>/"mingw.thread.h"/' lib/threads/resizable_parallel_runner.cc # Use "mingw-std-threads" implementation of standard C++11 threading classes, which are currently still missing on MinGW GCC.
      sed -i.bak 's/<condition_variable>/"mingw.condition_variable.h"/;s/<mutex>/"mingw.mutex.h"/;s/<thread>/"mingw.thread.h"/' lib/threads/thread_parallel_runner_internal.h # Otherwise you'd get errors like "'std::thread' has not been declared" and "invalid use of incomplete type 'class std::future<void>'".
    fi
    if [[ ! -f lib/threads/libjxl_threads.pc.in.bak ]]; then
      sed -i.bak "s/-lm/& -lstdc++/" lib/threads/libjxl_threads.pc.in # Otherwise you'd get for example "undefined reference to `operator new(unsigned int)'", amongst MANY other variants, while configuring FFmpeg. See https://github.com/libjxl/libjxl/pull/1444.
    fi
    mkdir -p build_dir
    cd build_dir # Out-of-source build.
      # -D_WIN32_WINNT=0x0501/-DWINVER=0x0501 (XP): without an explicit value, mingw-std-threads' own
      # mingw.condition_variable.h (used above) picks its 'vista::condition_variable' implementation
      # (native CONDITION_VARIABLE / SleepConditionVariableCS, Vista+ only) purely based on this macro's
      # default from the MinGW headers -- it already has a complete, tested XP-safe 'xp::condition_variable'
      # (semaphore+event based) that activates automatically once this is set correctly; no source patch needed.
      do_cmake ${PWD%/*} -DBUILD_SHARED_LIBS=0 -DBUILD_TESTING=0 -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS="$CFLAGS -D_WIN32_WINNT=0x0501 -DWINVER=0x0501" -DCMAKE_CXX_FLAGS="$CFLAGS -D_WIN32_WINNT=0x0501 -DWINVER=0x0501" -DJPEGXL_ENABLE_BENCHMARK=0 -DJPEGXL_ENABLE_DOXYGEN=0 -DJPEGXL_ENABLE_EXAMPLES=0 -DJPEGXL_ENABLE_JNI=0 -DJPEGXL_ENABLE_JPEGLI=0 -DJPEGXL_ENABLE_JPEGLI_LIBJPEG=0 -DJPEGXL_ENABLE_MANPAGES=0 -DJPEGXL_ENABLE_OPENEXR=0 -DJPEGXL_ENABLE_SJPEG=0 -DJPEGXL_ENABLE_TOOLS=0
      if [[ ! -f lib/include/jxl/jxl_export.h.bak ]]; then
        sed -i.bak "s/ __declspec(dll.*//" lib/include/jxl/jxl_export.h # Otherwise you'd get "undefined reference to `_imp__JxlDecoderVersion'" while configuring FFmpeg.
      fi
      do_make install
    cd ..
  cd ..
} # python 3

build_freetype() {
  download_and_unpack_file https://sourceforge.net/projects/freetype/files/freetype2/2.14.3/freetype-2.14.3.tar.xz/download freetype-2.14.3 # savannah.gnu.org started returning persistent 502s for this file; SourceForge's URL ends in '/download', not the filename, so pass the dir explicitly.
  cd freetype-2.14.3
    if [[ ! -f builds/unix/install.mk.bak ]]; then
      sed -i.bak "/config \\\/s/\s*\\\//;/bindir) /s/\s*\\\//;/aclocal/d;/man1/d;/PLATFORM_DIR/d;/docs/d" builds/unix/install.mk # Library only.
    fi
    # Upstream forces '--build=i686-pc-cygwin' here to dodge a Cygwin /cygdrive path-translation bug.
    # On native Linux that override is wrong (autoconf already detects the real build machine
    # correctly via config.guess) and would make freetype's build system take Cygwin-only code paths.
    generic_configure --with-harfbuzz=no --with-brotli=no
    do_make install
  cd ..
} # [zlib, bzip2, libpng]

build_libxml2() {
  download_and_unpack_file https://download.gnome.org/sources/libxml2/2.15/libxml2-2.15.3.tar.xz # xmlsoft.org no longer serves current releases.
  cd libxml2-2.15.3
    # The old lib-only/static Makefile.in patch was hand-rolled against 2.9.12's *generated* Makefile.in
    # (not configure.ac), so it doesn't apply to a different version at all; its CVE-2017-8872 fix has long
    # since been merged upstream anyway. --with-ftp/--with-http/--with-python=no below already skip the extras.
    apply_patch $patch_dir/libxml2_winxp-compatible-threads.patch -p1 # include/private/threads.h unconditionally selects native Win32 threading (CRITICAL_SECTION-only, no CONDITION_VARIABLE actually used here, but it also force-bumps _WIN32_WINNT to at least Vista as a side effect) whenever _WIN32 is defined, regardless of pthread.h availability. Route MinGW onto the POSIX pthread branch instead (real pthreads-win32, already linked elsewhere in this build), same reasoning as the dav1d patches.
    apply_patch $patch_dir/libxml2_winxp-compatible-entropy.patch -p1 # dict.c's xmlInitRandom() calls BCryptGenRandom (bcrypt.dll / CNG) unconditionally on _WIN32 -- Vista+ only. Switch to the legacy CryptoAPI (CryptGenRandom), same fix as mbedtls's and librist's own entropy sources.
    LDFLAGS=-pthread generic_configure --with-ftp=no --with-http=no --with-python=no # Now that threads.h (patched above) routes to real pthreads-win32, both libxml2.a itself and its bundled xmllint/xmlcatalog tools need '-pthread' on the link line -- same story as libssh/librist/dav1d's own '-pthread' fixes elsewhere in this build.
    do_make install
  cd ..
} # [zlib, liblzma, iconv, dlfcn]

build_fontconfig() {
  download_and_unpack_file https://ftp.osuosl.org/pub/blfs/conglomeration/fontconfig/fontconfig-2.16.0.tar.xz # 2.18.x exists as a git tag but was never packaged as an official release tarball; 2.16.0 is the newest one actually published.
  cd fontconfig-2.16.0
    if [[ ! -f Makefile.in.bak ]]; then
      cp Makefile.in Makefile.in.bak
      # Library only: collapse the (possibly backslash-continued, so plain sed line-ranges aren't safe across
      # versions) SUBDIRS list down to just fontconfig+src, and drop the doc/man/xml install targets.
      perl -0777 -pi -e 's/^SUBDIRS = .*?[^\\]\n/SUBDIRS = fontconfig src\n/ms' Makefile.in
      sed -i "/^install-data-am/s/:.*/: install-pkgconfigDATA/;/\tinstall-xmlDATA$/d" Makefile.in
    fi
    generic_configure --enable-libxml2 --disable-docs # Use Libxml2 instead of Expat.
    do_make install
  cd ..
} # freetype, libxml >= 2.6, python >= 3, [iconv, dlfcn]

build_gmp() {
  download_and_unpack_file https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz
  cd gmp-6.3.0
    if [[ ! -f Makefile.in.bak ]]; then # Library only.
      sed -i.bak "/^SUBDIRS/c\SUBDIRS = mpn mpz mpq mpf printf scanf rand cxx tune" Makefile.in
    fi
    generic_configure
    do_make install
  cd ..
} # [dlfcn]

build_mbedtls() {
  # 2.28 is the old LTS branch (essentially EOL); 3.6.x is the current stable/LTS-ish line. mbedTLS 4.x
  # also exists now but is very new (first 4.0 release was recent) -- staying one line behind on purpose.
  # A plain tarball doesn't work as of 3.6: CMakeLists.txt itself (not just the tests) now hard-requires the
  # 'framework' and 'tf-psa-crypto' git submodules ("mbedtls_framework" Python module / CMakeLists.txt not
  # found "and does not appear to be a git checkout"), so this needs an actual git checkout with submodules.
  do_git_checkout https://github.com/Mbed-TLS/mbedtls.git mbedtls_git mbedtls-3.6 627361b09e6f6e3eac756297a370a591cf310ab9 # mbedtls-3.6.7. Point-release tags live on the mbedtls-3.6 maintenance branch, not main/master.
  cd mbedtls_git
    if [[ ! -d framework/.git ]]; then
      echo -e "\e[1;33mDownloading mbedtls submodules.\e[0m"
      git submodule update --init framework # tf-psa-crypto doesn't exist as a submodule on the mbedtls-3.6 branch (only on newer/main), so just 'framework' here.
    fi
    apply_patch $patch_dir/mbedtls-2.28.9_mingw-stdio.diff # Windows XP compatibility; see if this 2.28-era patch (platform.h snprintf/vsnprintf conflict) still applies as-is to 3.6's platform.h.
    apply_patch $patch_dir/mbedtls-3.6.7_winxp-compatible-entropy.diff # library/entropy_poll.c unconditionally uses BCryptGenRandom (bcrypt.dll / CNG), which doesn't exist before Vista; switch to the legacy CryptoAPI (advapi32/CryptGenRandom), same fix pattern as libavutil/random_seed.c's own bcrypt-optional patch.
    mkdir -p build_dir
    cd build_dir # Out-of-source build.
      do_cmake ${PWD%/*} -DCMAKE_C_FLAGS="$CFLAGS -D__USE_MINGW_ANSI_STDIO=1" -DENABLE_PROGRAMS=0 -DENABLE_TESTING=0 -DENABLE_ZLIB_SUPPORT=1
      do_make install
    cd ..
  cd ..
}

build_libogg() {
  do_git_checkout https://github.com/xiph/ogg.git "" main 06a5e0262cdc28aa4ae6797627a783b5010440f0 # Xiph's repos default to 'main', not 'master'.
  cd ogg_git
    if [[ ! -f Makefile.am.bak ]]; then # Library only.
      sed -i.bak "s/ doc//;/m4data/,+2d" Makefile.am
    fi
    ac_cv_sizeof_u_int16_t=2 ac_cv_sizeof_u_int32_t=4 generic_configure # Both are set to 0 otherwise. See https://github.com/sherpya/mplayer-be/blob/master/packages/libogg/build.sh.
    do_make install
  cd ..
} # [dlfcn]

build_libvorbis() {
  do_git_checkout https://github.com/xiph/vorbis.git "" main 1b75110b5a2754ba1931d82dd83cb822b266a21d # Xiph's repos default to 'main', not 'master'.
  cd vorbis_git
    if [[ ! -f Makefile.am.bak ]]; then
      sed -i.bak "s/ test doc//;/m4data/,+2d" Makefile.am # Library only.
      sed -i.bak "s|if(samples>length/bytespersample)|if(bytespersample \&\& samples>length/bytespersample)|" lib/vorbisfile.c # Avoid SIGFPE when bytespersample is zero. See https://github.com/sherpya/mplayer-be/blob/master/packages/libvorbis/patches/01_debian_avoid-sigfpe.diff
    fi
    generic_configure --disable-docs --disable-examples --disable-oggtest
    do_make install
  cd ..
} # libogg >= 1.0, [dlfcn]

build_libopus() {
  do_git_checkout https://github.com/xiph/opus.git opus_git main 3da9f7a6db1c05c3996cb363a9d1931a978bf1be
  cd opus_git
    if [[ ! -f Makefile.am.bak ]]; then
      sed -i.bak "/m4data/,+2d;/install-data-local/,+2d" Makefile.am # Library only.
      sed -i.bak "/#ifndef OPUS_EXPORT/i\#define OPUS_EXPORT" include/opus_defines.h # Static library.
      sed -i.bak "s/@LIBM@/& -lssp/" opus.pc.in # Otherwise you'd get "undefined reference to `__memcpy_chk'" while configuring FFmpeg. The alternative is to use '--disable-stack-protector'.
    fi
    generic_configure --disable-doc --disable-extra-programs
    do_make install
  cd ..
} # [dlfcn]

build_lame() {
  do_svn_checkout https://svn.code.sf.net/p/lame/svn/trunk/lame lame_svn 6751 # Pinned for reproducibility, unlike most git deps here which float to a specific commit rather than a moving branch tip -- trunk itself has no release tags to pin to instead.
  cd lame_svn
    if [[ ! -f Makefile.in.bak ]]; then # Library only.
      sed -i.bak "/^SUBDIRS/s/ frontend//;/^SUBDIRS/s/ doc//" Makefile.in
    fi
    generic_configure --enable-nasm --disable-decoder --disable-frontend
    do_make install
  cd ..
} # [dlfcn]

build_twolame() {
  do_git_checkout https://github.com/njh/twolame.git twolame_git main 6fced852d4d5cfad58cf9dbe3ea619b08e87d398
  cd twolame_git
    if [[ ! -f Makefile.am.bak ]]; then # Library only.
      sed -i.bak "/^SUBDIRS/s/ frontend.*//;/pkgdocdir/,+6d;/pkgdoc_DATA/d" Makefile.am
      sed -i.bak "/#ifdef TL_API/i\#ifndef LIBTWOLAME_STATIC\\n#define LIBTWOLAME_STATIC\\n#endif\\n" libtwolame/twolame.h # Static library.
    fi
    generic_configure
    do_make install
  cd ..
} # [dlfcn]

build_fdk-aac() {
  do_git_checkout https://github.com/mstorsjo/fdk-aac.git "" "" d8e6b1a3aa606c450241632b64b703f21ea31ce3
  cd fdk-aac_git
    do_configure --host=$host_target --prefix=$mingw_w64_x86_64_prefix --disable-static # Build shared library ('libfdk-aac-2.dll').
    do_make install-strip

    mkdir -p $redist_dir
    archive="$redist_dir/libfdk-aac-$(git describe | tail -c +2 | sed 's/g//')-${target_suffix}"
    if [[ ! -f $archive.7z ]]; then # Pack shared library.
      sed "s/$/\r/" NOTICE > NOTICE.txt
      7z a -mx=9 -bb3 $archive.7z $mingw_w64_x86_64_prefix/bin/libfdk-aac-2.dll NOTICE.txt
      rm -v NOTICE.txt
    else
      echo -e "\e[1;33mAlready made '${archive##*/}.7z'.\e[0m"
    fi
  cd ..
} # [dlfcn]

build_libmpg123() {
  download_and_unpack_file https://sourceforge.net/projects/mpg123/files/mpg123/1.32.7/mpg123-1.32.7.tar.bz2
  cd mpg123-1.32.7
    if [[ ! -f Makefile.in.bak ]]; then # Library only
      sed -i.bak "/^all-am/s/\$(PROG.*/\\\/;/^install-data-am/s/ install-man//;/^install-exec-am/s/ install-binPROGRAMS//" Makefile.in
    fi
    generic_configure
    # '--enable-yasm' results in: "configure: error: Yasm for AVX is currently broken and might go away.".
    do_make install
  cd ..
} # [dlfcn]

build_libopenmpt() {
  download_and_unpack_file https://lib.openmpt.org/files/libopenmpt/src/libopenmpt-0.7.9+release.autotools.tar.gz
  cd libopenmpt-0.7.9+release.autotools
    if [[ ! -f Makefile.in.bak ]]; then # Library only
      sed -i.bak "/^install-data-am/s/:.*/: install-includelibopenmptHEADERS install-pkgconfigDATA/;/\tinstall-man /d" Makefile.in
    fi
    CFLAGS="$CFLAGS -D_WIN32_WINNT=_WIN32_WINNT_WINXP" CXXFLAGS="-D_WIN32_WINNT=_WIN32_WINNT_WINXP" generic_configure --disable-openmpt123 --disable-examples --disable-tests
    do_make install
  cd ..
} # zlib, libmpg123 >= 1.14.0, libogg, libvorbis, [dlfcn, mingw-std-threads]
# GCC11's own std::thread implementation conflicts with mingw-std-threads resulting in "libopenmpt/libopenmpt_impl.cpp:85:2: warning: #warning "Warning: Building libopenmpt with MinGW-w64 without std::thread support is not recommended and is deprecated. Please use MinGW-w64 with posix threading model (as opposed to win32 threading model), or build with mingw-std-threads." [-Wcpp]". See https://forum.openmpt.org/index.php?topic=6822.0.

build_libgme() {
  do_git_checkout https://github.com/libgme/game-music-emu.git "" "" fe8da4b6d3876d7542c2fb69d94487e19836d678
  cd game-music-emu_git
    if [[ ! -f CMakeLists.txt.bak ]]; then
      sed -i.bak "/EXCLUDE_FROM_ALL/d" CMakeLists.txt # Library only.
      sed -i.bak "s/gme \${libgme_SRCS}/gme STATIC \${libgme_SRCS}/" gme/CMakeLists.txt # Static library.
    fi
    do_cmake $PWD -DBUILD_SHARED_LIBS=0
    do_make install
  cd ..
} # zlib

build_libsoxr() {
  do_git_checkout https://git.code.sf.net/p/soxr/code soxr_git "" 945b592b70470e29f917f4de89b4281fbbd540c0
  cd soxr_git
    if [[ ! -f CMakeLists.txt.bak ]]; then # Library only.
      sed -i.bak "/^install/,+5d" CMakeLists.txt
    fi
    do_cmake $PWD -DBUILD_SHARED_LIBS=0 -DHAVE_WORDS_BIGENDIAN_EXITCODE=0 -DWITH_OPENMP=0 -DBUILD_TESTS=0 -DBUILD_EXAMPLES=0
    do_make install
  cd ..
}

build_libflite() {
  download_and_unpack_file http://www.festvox.org/flite/packed/flite-2.1/flite-2.1-release.tar.bz2
  cd flite-2.1-release
    apply_patch $patch_dir/libflite-2.1.0_mingw-w64-fixes.diff # Fix MinGW-w64 stuff and library only. Without the patch it fails with "../build/i386-mingw32/lib/libflite.a(cst_val.o):cst_val.c:(.text+0xdcd): undefined reference to `c99_snprintf'".
    do_configure --host=$host_target --prefix=$mingw_w64_x86_64_prefix --disable-shared
    do_make
    do_make_install
  cd ..
}

build_libsamplerate() {
  do_git_checkout https://github.com/libsndfile/libsamplerate.git "" "" 2ccde9568cca73c7b32c97fefca2e418c16ae5e3
  cd libsamplerate_git
    if [[ ! -f Makefile.am.bak ]]; then # Library only.
      sed -i.bak "53,\$d" Makefile.am
    fi
    generic_configure --disable-fftw
    do_make install
  cd ..
}

build_fftw() {
  download_and_unpack_file http://fftw.org/fftw-3.3.10.tar.gz
  cd fftw-3.3.10
    if [[ ! -f Makefile.in.bak ]]; then # Library only.
      sed -i.bak "/^SUBDIRS/s/api.*/api/;/^libbench2/d" Makefile.in
    fi
    generic_configure --disable-doc
    do_make install
  cd ..
}

build_librubberband() {
  do_git_checkout https://github.com/breakfastquay/rubberband.git rubberband_git default e4296ac80b1170018a110bc326fd0d45a0eb27d6 # Was stuck on a Feb-2021 commit (3 major versions behind); bumped past the v4.0.0 tag to current branch tip.
  cd rubberband_git
    # Meson-only as of v4.x (no more configure/Makefile.in) -- same story as libbluray/libdvdread/libdvdnav
    # elsewhere in this build. The old rubberband_git_static-lib.patch (hand-rolled against the old Makefile.in)
    # no longer applies and isn't needed: meson already has a proper static-lib + pkg-config install path.
    mkdir -p build_dir
    cd build_dir
      do_meson .. -Dfft=fftw -Dresampler=libsamplerate -Dladspa=disabled -Dlv2=disabled -Dvamp=disabled -Dcmdline=disabled -Dtests=disabled -Djni=disabled # Reuse the fftw/libsamplerate already built above instead of rubberband's builtin fallbacks.
      do_ninja_install
    cd ..
  cd ..
} # libsamplerate, fftw

build_libzimg() {
  do_git_checkout https://github.com/sekrit-twc/zimg.git "" "" f6cc75ad23db1bb9c53673c15523e6b6e960ffc6
  cd zimg_git
    if [[ ! -d .git/modules ]]; then
      echo -e "\e[1;33mDownloading submodule 'graphengine'.\e[0m"
      git submodule update --init --remote graphengine # Without it results in: "make[1]: *** No rule to make target 'graphengine/graphengine/cpuinfo.cpp', needed by 'graphengine/graphengine/libzimg_internal_la-cpuinfo.lo'.  Stop.". This can also be done with 'git clone --recursive', but since this is the only dependency that actually requires a submodule, it's undesirable to have it in 'do_git_checkout()'.
    else
      if [[ $(git --git-dir=.git/modules/graphengine rev-parse HEAD) != $(git ls-remote -h https://github.com/sekrit-twc/graphengine.git | sed "s/\s.*//") ]]; then
        git submodule foreach -q 'git reset --hard' # Return files to their original state.
        git submodule foreach -q 'git clean -fdx' # Clean the working tree; build- as well as untracked files.
        echo -e "\e[1;33mUpdating submodule 'graphengine' to latest git head on 'origin/master'.\e[0m"
        git submodule update --remote graphengine
        rm -f already_* # Force recompiling libzimg.
      else
        echo -e "\e[1;33mLocal submodule 'graphengine' is up-to-date.\e[0m"
      fi
    fi
    if [[ ! -f Makefile.am.bak ]]; then # Library only.
      sed -i.bak "/dist_doc_DATA/,+19d" Makefile.am
    fi
    generic_configure
    do_make install
  cd ..
} # [dlfcn]

build_vidstab() {
  do_git_checkout https://github.com/georgmartius/vid.stab.git "" "" b85fa835351c9eeddd4364153600dcd43ccc3745
  cd vid.stab_git
    do_cmake $PWD -DBUILD_SHARED_LIBS=0 -DUSE_OMP=0 # '-DUSE_OMP' is on by default, but somehow libgomp ('cygwin_local_install/lib/gcc/i686-pc-cygwin/5.4.0/include/omp.h') can't be found, so '-DUSE_OMP=0' to prevent a compilation error.
    do_make install
  cd ..
}

build_frei0r() {
  do_git_checkout https://github.com/dyne/frei0r.git "" "" 253addfd4bea3c90b0bf765589ca28ea18f3ddc0
  cd frei0r_git
    if [[ ! -f src/filter/kaleid0sc0pe/kaleid0sc0pe.cpp.bak ]]; then
      sed -i.bak 's/<future>/"mingw.future.h"/' src/filter/kaleid0sc0pe/kaleid0sc0pe.cpp # Use "mingw-std-threads" implementation of standard C++11 threading classes, which are currently still missing on MinGW GCC.
      sed -i.bak 's/<future>/\\"mingw.future.h\\"/' src/filter/kaleid0sc0pe/CMakeLists.txt # Otherwise you'd get errors like "'std::thread' has not been declared" and "invalid use of incomplete type 'class std::future<void>'".
    fi
    do_cmake $PWD -DCMAKE_BUILD_TYPE=Release -DWITHOUT_OPENCV=1 -DWITHOUT_CAIRO=1 -DWITHOUT_GAVL=1 -DBUILD_TESTING=0 # None of opencv/cairo/gavl are built for the cross target; upstream now defaults to requiring all three. BUILD_TESTING=0 also skips test/CMakeLists.txt, which wants a CMake-config-package dlfcn-win32 our autotools-built one doesn't provide.
    do_make -f Makefile install # frei0r's repo ships its own top-level 'GNUmakefile' (a ninja/build-dir wrapper); GNU Make prefers GNUmakefile over Makefile by default, silently shadowing the CMake-generated one, hence "No rule to make target 'install'" despite it existing.

    mkdir -p $redist_dir
    archive="$redist_dir/frei0r-plugins-$(git describe --tags | tail -c +2 | sed 's/g//')-${target_suffix}"
    if [[ ! -f $archive.7z ]]; then # Pack shared libraries.
      for doc in AUTHORS ChangeLog COPYING README.md; do
        sed "s/$/\r/" $doc > $mingw_w64_x86_64_prefix/lib/frei0r-1/$doc.txt
      done
      7z a -mx=9 -bb3 $archive.7z $mingw_w64_x86_64_prefix/lib/frei0r-1
      rm -v $mingw_w64_x86_64_prefix/lib/frei0r-1/*.txt
    else
      echo -e "\e[1;33mAlready made '${archive##*/}.7z'.\e[0m"
    fi
  cd ..
} # dlfcn

build_fribidi() {
  do_git_checkout https://github.com/behdad/fribidi.git "" "" 069a7e3d31e6aa74f2068a8e0804106ce7906639
  cd fribidi_git
    if [[ ! -f Makefile.am.bak ]]; then
      sed -i.bak "s/ bin doc test//" Makefile.am # Library only.
      sed -i.bak "/#define _FRIBIDI_COMMON_H/a\\\n#ifndef FRIBIDI_LIB_STATIC\n#define FRIBIDI_LIB_STATIC 1\n#endif" lib/fribidi-common.h # Static library. See https://github.com/sherpya/mplayer-be/blob/master/packages/fribidi/patches/01_sherpya_static-lib.diff.
    fi
    generic_configure --disable-deprecated
    do_make install
  cd ..
} # [dlfcn]

build_harfbuzz() {
  download_and_unpack_file https://github.com/harfbuzz/harfbuzz/archive/refs/tags/14.3.0.tar.gz harfbuzz-14.3.0
  cd harfbuzz-14.3.0
    sed -i.bak "s|setlocale|//setlocale|" util/options.hh # See https://github.com/sherpya/mplayer-be/blob/master/packages/harfbuzz/patches/01_sherpya_no-setlocale.diff.
    mkdir -p build_dir
    cd build_dir # Out-of-source build.
      do_cmake ${PWD%/*} -DBUILD_SHARED_LIBS=0 -DHB_HAVE_FREETYPE=1
      do_make install
    cd ..
  cd ..
} # [freetype]

build_libass() {
  do_git_checkout https://github.com/libass/libass.git "" "" 89cc0f4e450d64f74281a17d7f11ed05229665e8
  cd libass_git
    generic_configure --disable-directwrite
    # See https://github.com/libass/libass/blob/master/Changelog, libass (0.13.0): "The DirectWrite backend only works on Windows Vista and later. On XP, fontconfig is still needed.".
    # Without '--disable-directwrite' you'd get:
    # LD      ffmpeg_g.exe
    # [...]/libass.a(ass_directwrite.o):ass_directwrit:(.text+0x776): undefined reference to `_imp__GetTextFaceW@12'
    # [...]/libass.a(ass_directwrite.o):ass_directwrit:(.text+0xef0): undefined reference to `_imp__EnumFontFamiliesW@16'
    do_make install
  cd ..
} # freetype >= 9.10.3 (see https://bugs.launchpad.net/ubuntu/+source/freetype1/+bug/78573 o_O), fribidi >= 0.19.0, harfbuzz >= 1.2.3, [fontconfig >= 2.10.92, iconv, dlfcn]

build_avisynth() {
  do_git_checkout https://github.com/AviSynth/AviSynthPlus.git "" "" cfdaf8eb8a0a05b14edf7e73736df382bb876592
  mkdir -p AviSynthPlus_git/avisynth-build
  cd AviSynthPlus_git/avisynth-build # Out-of-source build.
    do_cmake ${PWD%/*} -DHEADERS_ONLY=1
    do_make VersionGen install
  cd ../..
}

build_libxvid() {
  download_and_unpack_file https://downloads.xvid.com/downloads/xvidcore-1.3.7.tar.gz xvidcore
  cd xvidcore
    cp -vu $patch_dir/libxvid_CMakeLists.txt CMakeLists.txt # See https://github.com/sherpya/mplayer-be/blob/master/packages/xvidcore/install/CMakeLists.txt.
    do_cmake $PWD
    do_make install
  cd ..
}

build_libx264() {
  do_git_checkout https://github.com/one808/x264.git "" "" 0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee
  cd x264_git
    if [[ ! -f configure.bak ]]; then # Change GCC optimization level.
      sed -i.bak "s/O3 -/O2 -/" configure
    fi
    do_configure --host=$host_target --cross-prefix=$cross_prefix --prefix=$mingw_w64_x86_64_prefix --enable-static --disable-cli --disable-win32thread # Use pthreads instead of win32threads.
    do_make install-lib-static
  cd ..
} # nasm >= 2.13 (unless '--disable-asm' is specified)

build_libx265() {
  do_git_checkout https://bitbucket.org/multicoreware/x265_git.git x265_git "" b81f650e21e8aacbe6a9ad04ce14aefc05b932c0
  cd x265_git
    if [[ ! -f source/CMakeLists.txt.bak ]]; then # Fix "noasm". See https://github.com/rdp/ffmpeg-windows-build-helpers/pull/738.
      sed -i.bak "s/if(X86MATCH GREATER \"-1\")/if(\"\${SYSPROC}\" STREQUAL \"\" OR X86MATCH GREATER \"-1\")/" source/CMakeLists.txt
    fi
    mkdir -p 8bit 10bit 12bit
    cd 12bit
      do_cmake ${PWD%/*}/source -DENABLE_SHARED=0 -DENABLE_CLI=0 -DWINXP_SUPPORT=1 -DHIGH_BIT_DEPTH=1 -DMAIN12=1 -DEXPORT_C_API=0 -DENABLE_ASSEMBLY=0
      do_make
    cd ../10bit
      do_cmake ${PWD%/*}/source -DENABLE_SHARED=0 -DENABLE_CLI=0 -DWINXP_SUPPORT=1 -DHIGH_BIT_DEPTH=1 -DEXPORT_C_API=0 -DENABLE_ASSEMBLY=0
      do_make
    cd ../8bit
      ln -sf ../10bit/libx265.a libx265_main10.a
      ln -sf ../12bit/libx265.a libx265_main12.a
      do_cmake ${PWD%/*}/source -DENABLE_SHARED=0 -DENABLE_CLI=0 -DWINXP_SUPPORT=1 -DEXTRA_LIB="libx265_main10.a;libx265_main12.a" -DEXTRA_LINK_FLAGS=-L. -DLINKED_10BIT=1 -DLINKED_12BIT=1
      do_make
      # rename the 8bit library, then combine all three into libx265.a
      mv libx265.a libx265_main.a
      ${cross_prefix}ar -M <<EOF
CREATE libx265.a
ADDLIB libx265_main.a
ADDLIB libx265_main10.a
ADDLIB libx265_main12.a
SAVE
END
EOF
      do_make install
    cd ..
  cd ..
} # nasm >= 2.13 (unless '-DENABLE_ASSEMBLY=0' is specified)

build_libvpx() {
  do_git_checkout https://chromium.googlesource.com/webm/libvpx.git libvpx_git main 251f0168c042861763f73b744f0b3583c70431a2
  cd libvpx_git
    if [[ ! -f vp8/common/threading.h.bak ]]; then
      sed -i.bak "/<semaphore.h/i\#include <sys/types.h>" vp8/common/threading.h # With 'cross_compilers/mingw-w64-i686/include/semaphore.h' you'd otherwise get: "semaphore.h:152:8: error: unknown type name 'mode_t'".
    fi
    CROSS="$cross_prefix" do_configure --target=x86-win32-gcc --prefix=$mingw_w64_x86_64_prefix --enable-static --disable-shared --disable-examples --disable-tools --disable-docs --disable-unit-tests --enable-vp9-highbitdepth
    do_make install
  cd ..
}

build_libaom() {
  do_git_checkout https://aomedia.googlesource.com/aom libaom_git main 01fd4524390f5230b22e9449a79d5df5a1b76dc4
  cd libaom_git
    apply_patch $patch_dir/libaom_restore-winxp-compatibility_use-pthreads.patch -p1 # See https://aomedia.googlesource.com/aom/+/64545cb00a29ff872473db481a57cdc9bc4f1f82%5E!/#F1, https://aomedia.googlesource.com/aom/+/e5eec6c5eb14e66e2733b135ef1c405c7e6424bf%5E!/#F0 and https://github.com/sherpya/mplayer-be/blob/master/packages/aom/patches/00_sherpya_use-pthreads.diff.
    mkdir -p aom_build
    cd aom_build # Out-of-source build.
      do_cmake ${PWD%/*} -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/x86-mingw-gcc.cmake -DENABLE_DOCS=0 -DENABLE_EXAMPLES=0 -DENABLE_NASM=1 -DENABLE_TESTS=0 -DENABLE_TOOLS=0 # aom dropped the 'build/' prefix from its cmake/ dir upstream.
      do_make install
    cd ..
  cd ..
} # cmake >= 3.5

build_ffmpeg() {
  do_git_checkout https://github.com/FFmpeg/FFmpeg.git "" release/8.1 1c2c67c0b9f7f66ab32c19dcf7f227bcd290aa4c # n8.1.2. Note: release tags live on their own release/X.Y branch, not master -- that's why the branch arg matters here.
  cd FFmpeg_git
    apply_patch $patch_dir/0001-make-bcrypt-optional.patch -p1 # WinXP doesn't have 'bcrypt'. See https://github.com/FFmpeg/FFmpeg/commit/aedbf1640ced8fc09dc980ead2a387a59d8f7f68 and https://github.com/sherpya/mplayer-be/blob/master/patches/ff/0001-make-bcrypt-optional-on-win32.patch.
    apply_patch $patch_dir/0002-windows-xp-compatible-CancelIoEx.patch -p1 # Otherwise you'd get "The procedure entry point CancelIoEx could not be located in the dynamic link library KERNEL32.dll" while running ffmpeg.exe, ffplay.exe, or ffprobe.exe, because 'CancelIoEx()' is only available on Windows Vista and later. See https://github.com/FFmpeg/FFmpeg/commit/53aa76686e7ff4f1f6625502503d7923cec8c10e, https://trac.ffmpeg.org/ticket/5717 and https://github.com/sherpya/mplayer-be/blob/master/patches/ff/0002-windows-xp-compatible-CancelIoEx.patch.
    apply_patch $patch_dir/0003-windows-xp-compatible-wcscp.patch -p1 # Otherwise you'd get "The procedure entry point wcscpy_s could not be located in the dynamic link library msvcrt.dll" while running ffmpeg.exe, ffplay.exe, or ffprobe.exe, because 'wcscpy()' is only available on Windows Vista and later. See https://github.com/FFmpeg/FFmpeg/commit/daf61dddc8e27424c320d5c3abe3e0c5182cd5c0.
    apply_patch $patch_dir/0004-load-shared-libfdk-aac-library-dynamically.patch -p1 # See https://github.com/sherpya/mplayer-be/blob/master/patches/ff/0004-dynamic-loading-of-shared-fdk-aac-library.patch.
    apply_patch $patch_dir/0004b-load-shared-libfdk-aac-configure-rebase.patch -p1 # 0004's own configure hunks bit-rotted (context changed too much for fuzzy matching, e.g. a new neighboring 'libmpeghdec' nonfree entry) between the old pinned FFmpeg commit and n8.1.2; same semantic change, rebased.
    apply_patch $patch_dir/0005-load-shared-frei0r-libraries-dynamically.patch -p1 # See https://github.com/sherpya/mplayer-be/blob/master/patches/ff/0005-avfilters-better-behavior-of-frei0r-on-win32.patch.
    init_options=(--arch=x86 --target-os=mingw32 --prefix=$mingw_w64_x86_64_prefix --cross-prefix=$cross_prefix --extra-cflags="$CFLAGS" --extra-libs=-lssp --extra-ldflags=-Wl,--allow-multiple-definition) # '-lssp': some static deps (e.g. libmp3lame) are built with stack-protector, referencing __stack_chk_guard/__stack_chk_fail from libssp.a; without it explicitly on the link line, FFmpeg's own configure lib-detection link tests (and the final link) fail with "undefined reference". '--allow-multiple-definition': libssh and librist each vendor their own MinGW gettimeofday() shim (MSVCRT doesn't provide one) under the same symbol name, which collide at final-link time; both implementations are equivalent GetSystemTimeAsFileTime()-based polyfills, so it's safe to just let the linker keep whichever it sees first.
    if [[ $1 == "shared" ]]; then
      init_options+=(--enable-shared --disable-static) # Building a static FFmpeg is the default, so no need to specify '--enable-static --disable-shared'.
    fi
    init_options+=(--pkg-config=pkg-config --pkg-config-flags=--static --extra-version=Reino --enable-gpl --enable-gray --enable-version3 --disable-bcrypt --disable-debug --disable-doc --disable-htmlpages --disable-manpages --disable-mediafoundation --disable-podpages --disable-txtpages --disable-w32threads)
    init_options+=(--disable-vulkan --disable-d3d11va --disable-d3d12va --disable-dxva2 --disable-amf --disable-ffnvcodec) # None of these have a hope of working on WinXP (need Vista+ APIs and/or modern GPU drivers); explicitly off rather than relying on the mingw sysroot happening to lack the headers.
    do_configure "${init_options[@]}" --enable-avisynth --enable-frei0r --enable-gmp --enable-lcms2 --enable-chromaprint --enable-libaom --enable-libass --enable-libbluray --enable-libdav1d --enable-libfdk-aac --enable-libflite --enable-libfontconfig --enable-libfreetype --enable-libfribidi --enable-libgme --enable-libgsm --enable-libharfbuzz --enable-libjxl --enable-libmp3lame --enable-libopencore-amrnb --enable-libopencore-amrwb --enable-libopenmpt --enable-libopus --enable-librist --enable-librubberband --enable-libsoxr --enable-libspeex --enable-libssh --enable-libsvtav1 --enable-libtheora --enable-libtwolame --enable-libvidstab --enable-libvo-amrwbenc --enable-libvorbis --enable-libvpx --enable-libwebp --enable-libx264 --enable-libx265 --enable-libxml2 --enable-libxvid --enable-libzimg --enable-libzvbi --enable-mbedtls --enable-libopenh264 --enable-libopenjpeg --enable-libbs2b --enable-libcodec2 --enable-libdvdnav --enable-libdvdread --enable-libvmaf --enable-libqrencode --enable-libsnappy
    # Deliberately NOT do_make here: its touchfile hash is based only on the make arguments (none, in this
    # plain call), never on what './configure' just produced -- so once it succeeds once, EVERY later run
    # with a changed --enable-* list (e.g. adding a new library) gets silently skipped as "Already made",
    # even though config.h/ffbuild/config.mak changed and a real rebuild is needed. GNU Make's own
    # dependency tracking on the actual source tree already does the right incremental-rebuild thing here,
    # so just call it directly instead of going through the coarse per-invocation touchfile wrapper.
    make -j $cpu_count || exit 1 # Build 'ffmpeg.exe', 'ffplay.exe' and 'ffprobe.exe' (+ '*.dll' for shared build). No install.

    mkdir -p $redist_dir
    archive="$redist_dir/ffmpeg-${ffmpeg_version_tag}-$1-${target_suffix}"
    if [[ $1 == "shared" ]]; then
      do_make_install
      if [[ ! -f $archive.7z ]]; then # Pack shared build.
        sed "s/$/\r/" COPYING.GPLv3 > COPYING.GPLv3.txt
        7z a -mx=9 -bb3 $archive.7z $mingw_w64_x86_64_prefix/bin/{ff*.exe,{av,sw,postproc}*.dll} COPYING.GPLv3.txt
        rm -v COPYING.GPLv3.txt
      else
        echo -e "\e[1;33mAlready made '${archive##*/}.7z'.\e[0m"
      fi
      if [[ ! -f ${archive/shared/dev}.7z ]]; then # Pack shared dev build.
        cd $mingw_w64_x86_64_prefix
          cp -v bin/*.lib lib
          7z a -mx=9 -bb3 ${archive/shared/dev}.7z include/lib{av,sw,postproc}* lib/{*.lib,*.def,lib{av,sw,postproc}*.dll.a} share/ffmpeg
          rm -v lib/*.lib
        cd $OLDPWD
      else
        echo -e "\e[1;33mAlready made '$(basename ${archive/shared/dev}.7z)'.\e[0m"
      fi
    else
      if [[ ! -f $archive.7z ]]; then # Pack static build.
        sed "s/$/\r/" COPYING.GPLv3 > COPYING.GPLv3.txt
        # The Cygwin build of p7zip has a "Can't allocate required memory!" bug, which is why upstream
        # shells out to a native Windows 7-Zip.exe via /cygdrive instead. That path doesn't exist here
        # (native Linux host, no Cygwin), and native Linux p7zip doesn't have that bug, so plain 7z works.
        7z a -mx=9 -bb3 $archive.7z ffmpeg.exe ffplay.exe ffprobe.exe COPYING.GPLv3.txt
        rm -v COPYING.GPLv3.txt
      else
        echo -e "\e[1;33mAlready made '${archive##*/}.7z'.\e[0m"
      fi
    fi
  cd ..
} # SDL2 (only for FFplay)

build_dav1d() {
  do_git_checkout https://github.com/videolan/dav1d.git dav1d_git "" 54706fc6bc0cdecab7e9593974a4039cc038fca7
  cd dav1d_git
    apply_patch $patch_dir/dav1d_winxp-compatible_no-srwlock.patch -p1 # src/thread.h unconditionally uses native
    # Win32 SRWLOCK/CONDITION_VARIABLE/INIT_ONCE for _WIN32 (Vista+ only) instead of ever considering the
    # POSIX pthread.h path meson.build could otherwise select -- route MinGW onto the existing pthreads-win32
    # (already linked elsewhere in this build, e.g. libssh) branch instead, same reasoning as the libwebp patches.
    apply_patch $patch_dir/dav1d_winxp-compatible_no-srwlock-win32-thread.patch -p1 # src/win32/thread.c is the
    # matching implementation file for the above (dav1d_pthread_create/join/once) -- same guard, same fix.
    apply_patch $patch_dir/dav1d_winxp-compatible_no-processor-groups.patch -p1 # src/cpu.c unconditionally calls
    # GetThreadGroupAffinity on any WINAPI_PARTITION_DESKTOP Windows build -- that's a Windows 7+-only kernel32
    # export (processor groups), not merely Vista+; since it's a *statically* imported symbol, Windows refuses to
    # load the entire .exe on XP ("procedure entry point ... could not be located") even though the code path is
    # never reached at runtime. Route MinGW onto the same GetNativeSystemInfo fallback this file already uses for
    # the non-desktop-partition case (available since XP).
    mkdir -p build_dir
    cd build_dir
      do_meson .. -Denable_tools=false -Denable_tests=false -Denable_examples=false
      do_ninja_install
      # dav1d.pc doesn't declare '-pthread': meson.build's Windows branch never adds a threads dependency at
      # all (it assumes its own win32/thread.c covers threading), so now that MinGW uses real pthreads-win32
      # via the patches above, this needs to be added by hand -- same story as libssh's '-pthread' fix.
      local pc=$mingw_w64_x86_64_prefix/lib/pkgconfig/dav1d.pc
      grep -q -- -pthread $pc || sed -i 's/^Libs:.*/& -pthread/' $pc
    cd ..
  cd ..
} # Fast AV1 decoder (meson).

build_svtav1() {
  do_git_checkout https://gitlab.com/AOMediaCodec/SVT-AV1.git SVT-AV1_git "" 13438c1f4386ac96b4be1d9a8a9b9184f64a55f3
  cd SVT-AV1_git
    apply_patch $patch_dir/svt-av1_winxp-compatible-threads.patch -p1 # Source/Lib/Codec/svt_threads.h's CondVar
    # struct and OnceType typedef unconditionally use native CRITICAL_SECTION+CONDITION_VARIABLE / INIT_ONCE
    # for _WIN32 -- Vista+ only (CONDITION_VARIABLE, INIT_ONCE) -- even though this same file already has a
    # complete, working POSIX pthread_mutex_t/pthread_cond_t/pthread_once_t implementation right next to it
    # for the non-Windows case. Route MinGW onto that existing pthread branch instead, same reasoning as dav1d.
    apply_patch $patch_dir/svt-av1_winxp-compatible-threads-impl.patch -p1 # Matching implementation in svt_threads.c (svt_create_cond_var/svt_set_cond_var/svt_wait_cond_var/svt_run_once) -- same guard, same fix.
    apply_patch $patch_dir/svt-av1_winxp-compatible-processor-count.patch -p1 # Source/Lib/Globals/enc_handle.c's
    # get_num_processors() unconditionally calls GetActiveProcessorCount -- a Windows 7+-only kernel32 export
    # (processor groups), same class of bug as dav1d's GetThreadGroupAffinity fix above: a statically imported
    # symbol the target DLL doesn't export blocks the whole .exe from loading on XP, not just that code path.
    # Route MinGW onto a GetSystemInfo-based count instead (available since Windows 2000).
    apply_patch $patch_dir/svt-av1_winxp-compatible-fopen.patch -p1 # Source/Lib/Codec/definitions.h's FOPEN macro
    # unconditionally expands to fopen_s -- a "secure CRT" function from VC2005+ that Microsoft never backported
    # into Windows XP's system msvcrt.dll (only into the newer, non-default msvcrt80/90/100+ redistributables).
    # Route MinGW onto plain fopen instead, same as the non-Windows branch already does.
    apply_patch $patch_dir/svt-av1_winxp-compatible-strncpy.patch -p1 # Source/Lib/Codec/svt_threads.c's
    # SetThreadDescription helper calls strncpy_s -- same "secure CRT, not on XP's msvcrt.dll" issue as the
    # FOPEN macro above. Route MinGW onto plain strncpy (the code already null-terminates manually right after).
    apply_patch $patch_dir/svt-av1_winxp-compatible-ftime.patch -p1 # Source/Lib/Codec/svt_time.c's
    # svt_av1_get_time() calls _ftime_s (mingw-w64's headers #define _ftime_s to _ftime32_s) -- same "secure CRT,
    # not on XP's msvcrt.dll" issue. Route MinGW onto the plain _ftime, already used safely elsewhere (x264/x265).
    mkdir -p Build_cmake
    cd Build_cmake
      do_cmake ${PWD%/*} -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_APPS=OFF -DBUILD_DEC=ON -DBUILD_ENC=ON -DBUILD_TESTING=OFF
      do_make install
    cd ..
  cd ..
} # Fast AV1 encoder (cmake).

build_libsrt() {
  do_git_checkout https://github.com/Haivision/srt.git libsrt_git "" fcae57145c000a9e7b72aa777adb8f85c2463242
  cd libsrt_git
    mkdir -p build_dir
    cd build_dir
      do_cmake ${PWD%/*} -DENABLE_SHARED=0 -DENABLE_STATIC=1 -DENABLE_APPS=0 -DENABLE_EXAMPLES=0 -DENABLE_UNITTESTS=0 -DENABLE_STDCXX_SYNC=ON -DUSE_ENCLIB=mbedtls -DENABLE_ENCRYPTION=1 -DMBEDTLS_LIBRARIES="$mingw_w64_x86_64_prefix/lib/libmbedtls.a;$mingw_w64_x86_64_prefix/lib/libmbedx509.a;$mingw_w64_x86_64_prefix/lib/libmbedcrypto.a" -DMBEDTLS_INCLUDE_DIR=$mingw_w64_x86_64_prefix/include
      do_make install
    cd ..
  cd ..
} # SRT streaming protocol; reuses the mbedtls we already build for FFmpeg's own TLS instead of adding yet another crypto lib.

build_librist() {
  do_git_checkout https://github.com/one808/librist.git librist_git "" 4f45ef8f78983892d52ccd52d9f675435b23738f
  cd librist_git
    apply_patch $patch_dir/librist_winpthreads-scalar-pthread_t.patch -p1 # rist.c does "if (some_pthread_t)"; under winpthreads pthread_t is a struct (no implicit bool conversion), so this fails to compile ("used struct type value where scalar is required"). memcmp against a zeroed pthread_t works on both winpthreads and POSIX.
    apply_patch $patch_dir/librist_winxp-compatible-entropy.patch -p1 # src/crypto/random.c seeds its mbedTLS DRBG via BCryptGenRandom (bcrypt.dll / CNG) on _WIN32 unconditionally, regardless of the have_mingw_pthreads=true option above -- Vista+ only. Switch to the legacy CryptoAPI (CryptGenRandom), same fix as mbedtls's own entropy_poll.c patch.
    apply_patch $patch_dir/librist_winxp-compatible-inet-ntop-pton.patch -p1 # Adds src/xp-inet-compat.h: a
    # from-scratch IPv4+IPv6 inet_ntop/inet_pton implementation for MinGW. mingw-w64's <ws2tcpip.h> declares
    # both as plain DLL imports from ws2_32.dll regardless of target OS, but Windows XP's real ws2_32.dll never
    # exported them (added in Vista) -- librist calls them unconditionally across several files, so the missing
    # static import blocks the whole .exe from loading on XP entirely, not just RIST's IPv6 code path.
    apply_patch $patch_dir/librist_winxp-compatible-inet-ntop-pton-tun_cidr.patch -p1 # src/tun_cidr.c: #include the new shim.
    apply_patch $patch_dir/librist_winxp-compatible-inet-ntop-pton-udpsocket.patch -p1 # src/udpsocket.c: #include the new shim.
    apply_patch $patch_dir/librist_winxp-compatible-inet-ntop-pton-udp.patch -p1 # src/udp.c: #include the new shim.
    apply_patch $patch_dir/librist_winxp-compatible-inet-ntop-pton-rist-common.patch -p1 # src/rist-common.c: #include the new shim.
    apply_patch $patch_dir/librist_winxp-compatible-wsasendto.patch -p1 # src/proto/gre.c calls WSASendMsg,
    # another Vista+-only ws2_32.dll export not on real XP -- same static-import-blocks-load-entirely issue.
    # This call never used WSAMSG's ancillary/control-data fields (no IP_PKTINFO etc.), so WSASendTo -- a base
    # Winsock2 function available since Windows 2000 -- covers the exact same scatter-gather-to-address need.
    mkdir -p build_dir
    cd build_dir
      do_meson .. -Dtest=false -Dbuilt_tools=false -Dhave_mingw_pthreads=true # No 'http' option in this version; use_mbedtls already defaults to true, matching the mbedtls we already build.
      do_ninja_install
    cd ..
  cd ..
} # RIST streaming protocol (meson), SRT's sibling.

build_libssh() {
  do_git_checkout https://github.com/libssh/libssh-mirror.git libssh_git "" ac6d2fad4a8bf07277127736367e90387646363f # git.libssh.org is unreachable from here; use the official GitHub mirror instead.
  cd libssh_git
    mkdir -p build_dir
    cd build_dir
      do_cmake ${PWD%/*} -DBUILD_SHARED_LIBS=OFF -DWITH_EXAMPLES=OFF -DWITH_SERVER=OFF -DUNIT_TESTING=OFF -DWITH_GSSAPI=OFF -DWITH_MBEDTLS=OFF -DWITH_GCRYPT=OFF # Force OpenSSL (build_openssl3 must run first): both mbedTLS and GCrypt are cached CMake options, so without explicit =OFF a stale CMakeCache.txt from an earlier experiment (or a future one) can silently keep the mbedTLS backend selected even once the flag is dropped from this command line.
      do_make install
      # Same story as chromaprint above: libssh.h defaults to __declspec(dllimport) unless LIBSSH_STATIC is
      # defined, and the installed .pc's Libs is missing its OpenSSL dependency, so pkg-config consumers
      # (FFmpeg's configure) fail with "undefined reference to `_imp__sftp_init'" otherwise.
      local pc=$mingw_w64_x86_64_prefix/lib/pkgconfig/libssh.pc
      grep -q LIBSSH_STATIC $pc || sed -i 's/^Cflags:.*/& -DLIBSSH_STATIC/' $pc
      grep -q lssl $pc || sed -i 's/^Libs:.*/& -lssl -lcrypto -lz -lws2_32 -lcrypt32/' $pc
      # libssh's own threads/pthread.c calls pthread_self/pthread_mutex_* directly; this toolchain's GCC
      # uses the win32 thread model (no built-in winpthreads), so those symbols come from the separate
      # pthreads-win32 (pthreads4w) lib instead -- '-pthread' pulls it in the same way librist's .pc does.
      grep -q -- -pthread $pc || sed -i 's/^Libs:.*/& -pthread/' $pc
    cd ..
  cd ..
} # SFTP protocol support. NB: different project from libssh2 (already built above for curl/hlsdl).

build_libzvbi() {
  do_git_checkout https://github.com/zapping-vbi/zvbi.git libzvbi_git main 4e222f98798d7afc0140b41a7c890257ac26e321
  cd libzvbi_git
    generic_configure --disable-dvb --disable-bktr --disable-nls --disable-proxy --without-doxygen
    do_make install
  cd ..
} # Teletext decoding.

build_chromaprint() {
  do_git_checkout https://github.com/acoustid/chromaprint.git chromaprint_git "" aed8eba2202dd9d7b3b0a56c77904cc805490d72
  cd chromaprint_git
    mkdir -p build_dir
    cd build_dir
      do_cmake ${PWD%/*} -DBUILD_SHARED_LIBS=OFF -DBUILD_TOOLS=OFF -DBUILD_TESTS=OFF -DFFT_LIB=fftw3 # Reuse the fftw we already build instead of adding kissfft or (circularly) avfft.
      do_make install
      # The installed .pc is incomplete for static linking: chromaprint.h defaults to __declspec(dllimport)
      # unless CHROMAPRINT_NODLL is defined; it's a C++ lib (uses fftw3's C++-ish wrapper) but doesn't list
      # -lfftw3 or the C++ runtime in Libs, and consumers here link with plain gcc (not g++), so libstdc++
      # isn't pulled in automatically either. Without all of this, anything consuming it via pkg-config
      # (like FFmpeg's configure) fails with "undefined reference" to chromaprint/fftw3/C++-runtime symbols.
      local pc=$mingw_w64_x86_64_prefix/lib/pkgconfig/libchromaprint.pc
      grep -q CHROMAPRINT_NODLL $pc || sed -i 's/^Cflags:.*/& -DCHROMAPRINT_NODLL/' $pc
      grep -q lfftw3 $pc || sed -i 's/^Libs:.*/& -lfftw3 -lstdc++/' $pc
    cd ..
  cd ..
} # Audio fingerprinting (MusicBrainz-style).

build_libbluray() {
  do_git_checkout https://github.com/one808/libbluray.git libbluray_git "" 64bcf07f47452fb4724eef3febc40aaf7720d42a
  cd libbluray_git
    git submodule update --init contrib/libudfread # contrib/libudfread is a submodule; --single-branch clone skips it.
    apply_patch $patch_dir/libbluray_winxp-compatible-strtok.patch -p1 # contrib/libudfread/src/udfread.c
    # unconditionally #defines strtok_r to strtok_s for _WIN32 -- a "secure CRT" function (VC2005+) never
    # backported into Windows XP's system msvcrt.dll. mingw-w64 already provides a real strtok_r natively, so
    # just let MinGW use that instead of rerouting to the missing secure variant.
    # Meson-only these days, no autotools left (no configure.ac).
    mkdir -p build_dir
    cd build_dir
      do_meson .. -Denable_tools=false -Denable_examples=false -Dbdj_jar=disabled -Dfontconfig=disabled -Dfreetype=disabled -Dlibxml2=disabled # Disc structure reading only, no menu/BD-J rendering -- keeps this out of the Java/font-stack dependency chain.
      do_ninja_install
    cd ..
  cd ..
} # Blu-ray disc structure reading.

build_opencore_amr() {
  do_git_checkout https://github.com/BelledonneCommunications/opencore-amr.git opencore-amr_git "" 3b67218fb8efb776bcd79e7445774e02d778321d
  cd opencore-amr_git
    generic_configure --disable-shared
    do_make install
  cd ..
} # AMR-NB/WB decode.

build_vo_amrwbenc() {
  do_git_checkout https://github.com/BelledonneCommunications/vo-amrwbenc.git vo-amrwbenc_git "" 3b3fcd0d250948e74cd67e7ea81af431ab3928f9
  cd vo-amrwbenc_git
    generic_configure --disable-shared
    do_make install
  cd ..
} # AMR-WB encode.

build_libilbc() {
  do_git_checkout https://github.com/TimothyGu/libilbc.git libilbc_git main 6adb26d4a4e159cd66d4b4c5e411cd3de0ab6b5e
  cd libilbc_git
    mkdir -p build_dir
    cd build_dir
      do_cmake ${PWD%/*} -DBUILD_SHARED_LIBS=OFF
      do_make install
    cd ..
  cd ..
} # VoIP speech codec.

build_speex() {
  do_git_checkout https://github.com/xiph/speex.git speex_git "" 05895229896dc942d453446eba6f9f5ddcf95422
  cd speex_git
    generic_configure --disable-binaries
    do_make install
  cd ..
} # VoIP speech codec.

build_theora() {
  do_git_checkout https://github.com/xiph/theora.git theora_git main 28fd5ec77f0ad0e07a371cef1047828116f6bd8a
  cd theora_git
    generic_configure --disable-examples --disable-oggtest --disable-vorbistest --disable-spec
    do_make install
  cd ..
} # Ogg Theora encode (decode is already native in FFmpeg).

build_wavpack() {
  do_git_checkout https://github.com/dbry/WavPack.git wavpack_git "" eccf998c7acce58e18dedd354e6b025728dcf6da
  cd wavpack_git
    mkdir -p build_dir
    cd build_dir
      do_cmake ${PWD%/*} -DBUILD_SHARED_LIBS=OFF -DWAVPACK_BUILD_PROGRAMS=OFF -DWAVPACK_BUILD_DOCS=OFF -DWAVPACK_BUILD_COOLEDIT_PLUGIN=OFF -DWAVPACK_BUILD_WINAMP_PLUGIN=OFF -DWAVPACK_ENABLE_ASM=OFF # src/pack_x86.S doesn't assemble cleanly with this binutils (operand-size-mismatch errors); the plain-C fallback is plenty fast for lossless audio.
      do_make install
    cd ..
  cd ..
} # Lossless audio.

build_lcms2() {
  do_git_checkout https://github.com/mm2/Little-CMS.git lcms2_git "" a8183f542072ad4e941116ed921dc6e411077049
  cd lcms2_git
    generic_configure --without-jpeg --without-tiff
    do_make install
  cd ..
} # Color management (colorspace/lut filters, libjxl's cms hook).

build_gsm() {
  do_git_checkout https://github.com/timothytylee/libgsm.git libgsm_git "" 98f1708fb5e06a0dfebd58a3b40d610823db9715
  cd libgsm_git
    # No CMakeLists.txt here after all (it's the classic Jutta Degener 1.0.17 source, no configure/CMake at
    # all) -- build it by hand: it's just a dozen .c files into a static archive, not worth chasing a build
    # system for.
    local name=$(get_small_touchfile_name already_built_gsm "$CFLAGS")
    if [ ! -f $name ]; then
      rm -f src/*.o
      for f in src/*.c; do
        ${cross_prefix}gcc $CFLAGS -DNeedFunctionPrototypes=1 -Iinc -c "$f" -o "${f%.c}.o" || exit 1
      done
      ${cross_prefix}ar rc src/libgsm.a src/*.o || exit 1
      ${cross_prefix}ranlib src/libgsm.a || exit 1
      mkdir -p $mingw_w64_x86_64_prefix/include/gsm
      install -m644 inc/gsm.h $mingw_w64_x86_64_prefix/include/gsm/gsm.h || exit 1
      install -m644 src/libgsm.a $mingw_w64_x86_64_prefix/lib/libgsm.a || exit 1
      touch $name || exit 1
    fi
  cd ..
} # GSM 06.10 codec (old mobile telephony).

build_libopenh264() {
  do_git_checkout https://github.com/cisco/openh264.git libopenh264_git "" 35325f4040c2be0f86246c4a8923f7fc04c1a998
  cd libopenh264_git
    do_make OS=mingw_nt ARCH=x86 ASM_ARCH=x86 CC=${cross_prefix}gcc CXX=${cross_prefix}g++ AR=${cross_prefix}ar RANLIB=${cross_prefix}ranlib STRIP=${cross_prefix}strip PREFIX=$mingw_w64_x86_64_prefix install-static
    # 'openh264-static.pc' already gets '-lstdc++' baked into its Libs by openh264's own Makefile (its
    # STATIC_LDFLAGS variable) and gets installed as plain 'openh264.pc' -- unlike chromaprint/libssh above,
    # this one's pkg-config file is already complete for static linking, no fixup needed.
  cd ..
} # Cisco's openly-licensed H.264 codec (own Makefile build system, not autotools/CMake/meson).

build_libopenjpeg() {
  do_git_checkout https://github.com/uclouvain/openjpeg.git libopenjpeg_git "" 402ef5862195b177ea0a7788f2a6ef2804e62285
  cd libopenjpeg_git
    do_cmake $PWD -DBUILD_SHARED_LIBS=0 -DBUILD_STATIC_LIBS=1 -DBUILD_CODEC=0 -DBUILD_DOC=0 -DBUILD_TESTING=0
    do_make install
  cd ..
} # JPEG2000.

build_libbs2b() {
  download_and_unpack_file http://downloads.sourceforge.net/project/bs2b/libbs2b/3.1.0/libbs2b-3.1.0.tar.gz
  cd libbs2b-3.1.0
    if [[ ! -f src/Makefile.in.bak ]]; then # Library only: 'bin_PROGRAMS' isn't behind any --disable flag (there
      # is no such flag -- '--disable-static-bins' isn't a real option this configure.ac defines), so
      # bs2bconvert/bs2bstream get built unconditionally otherwise, and bs2bconvert needs '-lsndfile', which
      # we don't build (nothing else here needs it -- libbs2b.la itself only links '-lm').
      sed -i.bak '/^bin_PROGRAMS/d;/^PROGRAMS = \$(bin_PROGRAMS)/d' src/Makefile.in
    fi
    # configure.ac also has an unconditional top-level 'PKG_CHECK_EXISTS([sndfile], ..., AC_MSG_ERROR(...))'
    # sanity check -- completely unused by the library itself, just a pkg-config *existence* probe. Satisfy it
    # with a throwaway fake .pc (only visible to this one configure invocation) instead of building real libsndfile.
    mkdir -p fake_pkgconfig
    printf 'Name: sndfile\nDescription: fake stub, only its existence is ever checked\nVersion: 1.0.0\n' > fake_pkgconfig/sndfile.pc
    # configure.ac's AC_FUNC_MALLOC can't actually run a test program while cross-compiling, so it
    # conservatively assumes malloc(0) isn't GNU-compatible and '#define malloc rpl_malloc' in config.h,
    # expecting bs2b to ship its own rpl_malloc() replacement (it doesn't) -- "undefined reference to
    # `rpl_malloc'" at link time. MinGW's malloc actually IS GNU-compatible; this is autoconf's own
    # documented cross-compiling workaround (same idiom as this script's global ac_cv_func__mktemp_s=no).
    PKG_CONFIG_PATH="$PWD/fake_pkgconfig:$PKG_CONFIG_PATH" ac_cv_func_malloc_0_nonnull=yes generic_configure
    do_make install
  cd ..
} # Bauer stereophonic-to-binaural DSP filter ('bs2b' audio filter). Dormant upstream (last release 2009) but complete/stable.

build_libcodec2() {
  do_git_checkout https://github.com/drowe67/codec2.git libcodec2_git main 310777b1c6f1af0bc7c72f5b32f80f6fd9136962
  cd libcodec2_git
    if [[ ! -f CMakeLists.txt.bak ]]; then
      # No flag disables the demo/utility .exe's (UNITTEST=0 only covers unit tests), and their WIN32-only
      # 'install(SCRIPT GetDependencies.cmake)' step (CPack/NSIS installer DLL-bundling helper, irrelevant to
      # us) fails at install time with "could not find requested file: cmake/GetPrerequisites.cmake" -- that
      # file genuinely doesn't exist in this repo. Just drop the one line; the demo .exe's still get built
      # (harmless, unused) but no longer block 'make install' of the actual static library.
      sed -i.bak '/install(SCRIPT \${CMAKE_BINARY_DIR}\/cmake\/GetDependencies.cmake)/d' CMakeLists.txt
    fi
    mkdir -p build_dir
    cd build_dir
      do_cmake ${PWD%/*} -DBUILD_SHARED_LIBS=0 -DUNITTEST=0 -DLPCNET=0
      do_make install
    cd ..
  cd ..
} # Very-low-bitrate speech codec (digital voice/ham radio use case).

build_libdvdread() {
  do_git_checkout https://github.com/one808/libdvdread.git libdvdread_git "" 3a1a072755a121d418359964f27451c28d9853e8
  cd libdvdread_git
    # Meson-only these days, no autotools left (no configure.ac) -- same story as libbluray earlier.
    mkdir -p build_dir
    cd build_dir
      do_meson .. -Dlibdvdcss=disabled -Denable_docs=false # Explicitly disabled (not just left at its 'auto'
      # default) to keep this build free of CSS-decryption code even if a stray libdvdcss.pc ever showed up
      # in the prefix. libdvdread can still dlopen() a system-provided libdvdcss DLL at runtime if the user
      # drops one in next to ffmpeg.exe, but nothing here links or ships it -- unencrypted/homemade DVDs read
      # fine either way.
      do_ninja_install
    cd ..
  cd ..
} # DVD structure/sector reading (libdvdnav's dependency).

build_libdvdnav() {
  do_git_checkout https://github.com/one808/libdvdnav.git libdvdnav_git "" e0c02b973c62081ee8dc109726e511e94c10f70e
  cd libdvdnav_git
    # Meson-only, same as libdvdread above. 'enable_examples' already defaults to false.
    mkdir -p build_dir
    cd build_dir
      do_meson .. -Denable_docs=false
      do_ninja_install
    cd ..
  cd ..
} # DVD menu/navigation (dvdnav:// input), needs libdvdread above.

build_libvmaf() {
  do_git_checkout https://github.com/Netflix/vmaf.git libvmaf_git "" 4991d2b5aeb26391fbb85b63e3e86e7ad7a94b6e
  cd libvmaf_git/libvmaf # Meson project lives in the 'libvmaf' subdirectory, not the repo root.
    mkdir -p build_dir
    cd build_dir
      do_meson .. -Denable_tests=false -Denable_docs=false -Denable_tools=false -Denable_avx512=false # avx512 is moot on a Core2 target; keep baseline SSE/SSSE3 asm (enable_asm stays default-on).
      do_ninja_install
      # Same C++-runtime story as chromaprint above: libvmaf.a bundles one C++ compilation unit (svm.cpp, its
      # SVM model parser) needing libstdc++/RTTI/exception-handling symbols, but the installed .pc's Libs
      # doesn't list it and FFmpeg's configure link-tests with plain gcc, not g++ -- "undefined reference to
      # `operator delete(void*)'" etc. otherwise.
      local pc=$mingw_w64_x86_64_prefix/lib/pkgconfig/libvmaf.pc
      grep -q lstdc++ $pc || sed -i 's/^Libs:.*/& -lstdc++/' $pc
    cd ..
  cd ../..
} # Netflix's objective video-quality metric ('-lavfi libvmaf' filter, '-vmaf' output).

build_libqrencode() {
  do_git_checkout https://github.com/fukuchi/libqrencode.git libqrencode_git "" 715e29fd4cd71b6e452ae0f4e36d917b43122ce8
  cd libqrencode_git
    if [[ ! -f qrencode.c.bak ]]; then # Upstream bug: configure.ac's AC_INIT/AM_INIT_AUTOMAKE never actually
      # AC_DEFINEs a plain 'VERSION' macro (config.h.in only has '#undef PACKAGE_VERSION'), but
      # QRcode_APIVersionString() in qrencode.c references bare VERSION anyway -- "'VERSION' undeclared".
      # Use the macro that config.h actually defines.
      sed -i.bak 's/return VERSION;/return PACKAGE_VERSION;/' qrencode.c
    fi
    generic_configure --without-tools --without-png --without-tests
    do_make install
  cd ..
} # QR-code generation ('qrencode' bitstream filter).

build_libsnappy() {
  do_git_checkout https://github.com/google/snappy.git libsnappy_git main 6af9287fbdb913f0794d0148c6aa43b58e63c8e3 # v1.2.2. Repo defaults to 'main', not 'master'. Pinned to a release tag commit rather than tip -- unlike most git deps here, Google's snappy 'main' branch isn't guaranteed build-stable.
  cd libsnappy_git
    mkdir -p build_dir
    cd build_dir
      do_cmake ${PWD%/*} -DBUILD_SHARED_LIBS=0 -DSNAPPY_BUILD_TESTS=0 -DSNAPPY_BUILD_BENCHMARKS=0 -DSNAPPY_INSTALL=1
      do_make install
      # Same C++-runtime story as chromaprint: snappy doesn't generate a .pc at all, and FFmpeg's configure
      # check for it (require, not require_pkg_config) links plain '-lsnappy -lstdc++' directly -- so nothing
      # to patch here, just needs libstdc++ present on the link line, which FFmpeg's own check already adds.
    cd ..
  cd ..
} # Google Snappy compression (used by a handful of muxers/demuxers).

build_dependencies() {
  build_mingw_std_threads
  # Deliberately NOT building our own Python/CMake/NASM here (upstream does, as build_python()/build_cmake()/
  # build_nasm() further down still show): that's a Cygwin-only need (no adequate system versions there).
  # On native Linux those --prefix=/usr installs actively hurt more than they help:
  #  - Python: it overwrote /usr/bin/python3 with an ancient 3.4.10 for the rest of the container's life, and
  #    newer host-side build-time codegen scripts (e.g. fontconfig's fc-case.py) use f-strings, needing 3.6+.
  #  - CMake/NASM: their WinXP-target CFLAGS leak into the native compile and break it on 64-bit hosts ("CPU
  #    you selected does not support x86-64 instruction set") unless carefully unset/reset around them; and
  #    worse, since they install to /usr (not the bind-mounted sandbox), that install does NOT survive this
  #    container being recreated (e.g. after an image rebuild) even though the sandbox's own "already built"
  #    touchfile does -- so the script silently skips reinstalling them into a container that doesn't actually
  #    have them, which surfaces later, confusingly, as some unrelated dependency's build failing to find nasm.
  # apt's python3/cmake/nasm (pulled in directly or via the 'meson' package) are fine substitutes.
  build_dlfcn
  build_bzip2 # Bzlib (bzip2) in FFmpeg is autodetected, so no need for --enable-bzlib.
  build_liblzma # Lzma in FFmpeg is autodetected, so no need for --enable-lzma.
  build_zlib # Zlib in FFmpeg is autodetected, so no need for --enable-zlib.
  build_iconv # Iconv in FFmpeg is autodetected, so no need for --enable-iconv.
  build_sdl2 # Sdl2 in FFmpeg is autodetected, so no need for --enable-sdl2.
  build_libwebp
  build_libjxl
  build_freetype
  build_libxml2 # For DASH support configure FFmpeg with --enable-libxml2.
  build_fontconfig
  build_lcms2 # Color management; used by FFmpeg's colorspace/lut filters.
  build_gmp # For RTMP support configure FFmpeg with --enable-gmp.
  build_mbedtls # For HTTPS TLS 1.2 support on WinXP configure FFmpeg with --enable-mbedtls.
  # build_libsrt intentionally not called: SRT's own CMakeLists.txt only has first-class support for
  # "real Windows" (MSVC, detected via the MICROSOFT var) or POSIX, not MinGW cross-compilation, which
  # falls into neither bucket. Forcing -DENABLE_STDCXX_SYNC=ON gets further but then srtcore/api.cpp fails
  # with "'ScopedLock' was not declared" -- sync.h mixes '#ifdef ENABLE_STDCXX_SYNC' (defined-check) and
  # '#if ENABLE_STDCXX_SYNC' (value-check) in ways that don't agree on how CMake passes the flag. This
  # looks like a genuine upstream MinGW-support gap, not something to patch around here. librist below
  # covers the same "reliable streaming ingest" use case with a build that Just Works.
  build_librist
  build_openssl3 static # For libssh below, which defaults to (and is better-tested with) OpenSSL over its mbedTLS backend.
  build_libssh
  build_libogg
  build_libvorbis
  build_libopus
  build_lame
  build_twolame
  build_fdk-aac
  build_libmpg123
  build_libopenmpt
  build_libgme
  build_libsoxr
  build_libflite
  build_libsamplerate
  build_fftw
  build_chromaprint # Reuses fftw above -- must come after it.
  build_librubberband
  build_libzimg
  build_vidstab
  build_frei0r
  build_fribidi
  build_harfbuzz
  build_libass
  build_avisynth
  build_libxvid
  build_libx264
  build_libx265
  build_libvpx
  build_libaom
  build_dav1d
  build_svtav1
  build_libzvbi
  build_libbluray
  build_opencore_amr
  build_vo_amrwbenc
  # build_libilbc intentionally not called: this fork is a vendored copy of WebRTC's iLBC implementation
  # (its source tree layout is literally WebRTC's modules/audio_coding/codecs/ilbc/), which pulls in
  # Google's Abseil C++ library that we don't build. No simpler standalone iLBC fork was found. iLBC is
  # a fairly obscure 2000s VoIP codec at this point -- not worth adding Abseil as a dependency chain for.
  build_speex
  build_theora
  # build_wavpack intentionally not called: FFmpeg has a fully native WavPack encoder AND decoder
  # (ff_wavpack_encoder/ff_wavpack_decoder in libavcodec/allcodecs.c) -- no external lib or configure
  # flag for it exists at all. Same situation as AC-3/FLAC: nothing to add here.
  build_gsm
  build_libopenh264
  build_libopenjpeg
  build_libbs2b
  build_libcodec2
  build_libdvdread # Must come before libdvdnav below, which links against it.
  build_libdvdnav
  build_libvmaf
  build_libqrencode
  build_libsnappy
}

build_apps() {
  if [[ $build_ffmpeg_static = "y" ]]; then
    build_ffmpeg static
  else
    build_ffmpeg shared
  fi
}

build_openssl3() {
  download_and_unpack_file https://www.openssl.org/source/openssl-3.6.3.tar.gz
  cd openssl-3.6.3
    if [[ ! -f Configurations/10-main.conf.bak ]]; then # Change GCC optimization level.
      sed -i.bak "s/-O3/-O2/" Configurations/10-main.conf
    fi
    local config_options=(./Configure --prefix=$mingw_w64_x86_64_prefix mingw zlib no-async)
    # "Note: on older OSes, like CentOS 5, BSD 5, and Windows XP or Vista, you will need to configure with no-async when building OpenSSL 1.1.0 and above. The configuration system does not detect lack of the Posix feature on the platforms." (https://wiki.openssl.org/index.php/Compilation_and_Installation)
    if [ "$1" = "static" ]; then
      #if [[ -f Makefile ]]; then
      #  make distclean
      #fi
      CC="${cross_prefix}gcc" AR="${cross_prefix}ar" RANLIB="${cross_prefix}ranlib" do_configure "${config_options[@]}" no-shared no-dso # No 'no-engine' because Curl needs it when built with Libssh2.
      do_make install_dev
    else
      CC="${cross_prefix}gcc" AR="${cross_prefix}ar" RANLIB="${cross_prefix}ranlib" do_configure "${config_options[@]}" shared
      do_make build_libs

      mkdir -p $redist_dir
      archive="$redist_dir/openssl-3.6.3-${target_suffix}"
      if [[ ! -f $archive.7z ]]; then # Pack shared libraries.
        ${cross_prefix}strip -ps libcrypto-3.dll libssl-3.dll
        7z a -mx=9 -bb3 $archive.7z libcrypto-3.dll libssl-3.dll LICENSE.txt
      else
        echo -e "\e[1;33mAlready made '${archive##*/}.7z'.\e[0m"
      fi
    fi
  cd ..
} # This is to compile 'libcrypto-3.dll' and 'libssl-3.dll' for Xidel, or a static library for hlsdl.

build_libssh2() {
  do_git_checkout https://github.com/libssh2/libssh2.git
  cd libssh2_git
    if [[ ! -f Makefile.am.bak ]]; then
      sed -i.bak "/^SUBDIRS/s/src.*/src/" Makefile.am # Library only.
    fi
    generic_configure --disable-docker-tests --disable-sshd-tests --disable-examples-build --without-libbcrypt-prefix # Needs 'bcrypt.dll' to start otherwise.
    do_make install
  cd ..
} # openssl, [zlib, dlfcn]

build_curl() {
  download_and_unpack_file https://curl.se/download/curl-8.9.1.tar.xz
  if [ "$1" = "openssl" ]; then # Compile Curl with OpenSSL for hlsdl.
    build_openssl3 static
    cd curl-8.9.1
    PKG_CONFIG="pkg-config --static" generic_configure --with-openssl --without-brotli --without-ca-bundle --with-ca-fallback # Automatically detect all of OpenSSL its dependencies.
    do_make install-strip
  else # Compile Curl with MbedTLS and create archive.
    build_mbedtls
    build_libssh2
    cd curl-8.9.1
    if [[ ! -f cacert.pem ]]; then # See https://curl.se/docs/sslcerts.html and https://superuser.com/a/442797 for more on the CA cert file.
      echo -e "\e[1;33mDownloading 'https://curl.se/ca/cacert.pem'.\e[0m"
      wget https://curl.se/ca/cacert.pem
    fi
    LDFLAGS=-s generic_configure --with-mbedtls --with-libssh2 --without-brotli --with-ca-bundle=cacert.pem # --with-ca-fallback only works with OpenSSL or GnuTLS.
    do_make # 'curl.exe' only. No install.

    mkdir -p $redist_dir
    archive="$redist_dir/curl-8.9.1-mbedtls-zlib-ssh2-static-${target_suffix}"
    if [[ ! -f $archive.7z ]]; then # Pack static 'curl.exe'.
      sed "s/$/\r/" COPYING > COPYING.txt
      7z a -mx=9 -bb3 $archive.7z ./src/curl.exe cacert.pem COPYING.txt
      rm -v COPYING.txt
    else
      echo -e "\e[1;33mAlready made '${archive##*/}.7z'.\e[0m"
    fi
  fi
  cd ..
} # mbedtls/openssl, [zlib, dlfcn]

build_hlsdl() {
  build_curl openssl
  do_git_checkout https://github.com/selsta/hlsdl.git
  cd hlsdl_git
    LDFLAGS=-s do_make $make_prefix_options # Strip 'hlsdl.exe' during make.

    mkdir -p $redist_dir
    archive="$redist_dir/hlsdl-$(grep -Po "(?<=hlsdl v)([0-9]+\.?)+" src/misc.c)-$(git rev-parse --short HEAD)-static-${target_suffix}"
    if [[ ! -f $archive.7z ]]; then # Pack static 'hlsdl.exe'.
      sed "s/$/\r/" LICENSE > LICENSE.txt
      7z a -mx=9 -bb3 $archive.7z hlsdl.exe LICENSE.txt README.md
      rm -v LICENSE.txt
    else
      echo -e "\e[1;33mAlready made '${archive##*/}.7z'.\e[0m"
    fi
  cd ..
} # curl(openssl)

build_ffms2_cplugin() {
  if [ "$1" = "static_ffmpeg" ]; then
    do_git_checkout https://github.com/FFmpeg/FFmpeg.git FFmpeg-6.2_git "" 238f9de876c4298606ce41992e16b959d108b633
    cd FFmpeg-6.2_git
      ff_rev=$(git describe --tags | tail -c +2 | sed 's/dev-//;s/g//')
      apply_patch $patch_dir/0001-make-bcrypt-optional_ffmpeg6.2.patch -p1
      do_configure --arch=x86 --target-os=mingw32 --prefix=$mingw_w64_x86_64_prefix --cross-prefix=$cross_prefix --extra-cflags="$CFLAGS" --pkg-config=pkg-config --pkg-config-flags=--static --enable-gpl --enable-version3 --disable-bcrypt --disable-debug --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-schannel --disable-txtpages --disable-w32threads --disable-avdevice --disable-avfilter --disable-devices --disable-encoders --disable-filters --disable-hwaccels --disable-mediafoundation --disable-muxers --disable-network --disable-programs --disable-sdl2 --enable-libaom
      do_make
      do_make_install
    cd ..
  else
    build_ffmpeg shared
    cd FFmpeg_git; ff_rev=$(git describe --tags | tail -c +2 | sed 's/dev-//;s/g//'); cd ..
  fi

  do_git_checkout https://github.com/qyot27/ffms2_cplugin.git "" c_plugin
  cd ffms2_cplugin_git
    apply_patch $patch_dir/ffms2_configure-fix-various.patch -p1 # Correctly detect MingW32, use Cygwin's pkg-config and don't set GCC optimization level twice if $CFLAGS already contains one.
    if [[ ! -f src/core/ffms.cpp.bak ]]; then
      sed -i.bak 's/<mutex>/"mingw.mutex.h"/' src/core/ffms.cpp # Use "mingw-std-threads" implementation of standard C++11 threading classes, which are currently still missing on MinGW GCC.
      sed -i.bak 's/<thread>/"mingw.thread.h"/' src/core/videosource.cpp # Otherwise you'd get errors like "'mutex' in namespace 'std' does not name a type".
    fi
    do_configure --host=$host_target --prefix=$mingw_w64_x86_64_prefix --cross-prefix=$cross_prefix --enable-shared --enable-avisynth --enable-vapoursynth
    do_make
    rm -f NUL # Somehow this "file" is created and Windows Explorer can't delete it.

    mkdir -p $redist_dir
    archive="$redist_dir/ffms2-$(git describe --tags | sed 's/g//')-avs-vsp_ffmpeg-$ff_rev"
    if [ "$1" = "static_ffmpeg" ]; then
      archive="${archive}-static-${target_suffix}"
    else
      archive="${archive}-shared-${target_suffix}"
    fi
    if [[ ! -f $archive.7z ]]; then
      sed "s/$/\r/" etc/COPYING.GPLv3 > COPYING.GPLv3.txt
      7z a -mx=9 -bb3 $archive.7z ffms3.dll ffmsindex.exe ./etc/FFMS2.avsi doc COPYING.GPLv3.txt
      rm -v COPYING.GPLv3.txt
    else
      echo -e "\e[1;33mAlready made '${archive##*/}.7z'.\e[0m"
    fi
  cd ..
} # ffmpeg, mingw-std-threads

reset_cflags() {
  export CFLAGS=$original_cflags
}

finalize_redist() { # Called once at the very end, after build_apps (and whatever else) has had its chance to write into $redist_dir.
  if compgen -G "$redist_dir/*.7z" > /dev/null; then
    (cd "$redist_dir" && sha256sum -- *.7z > SHA256SUMS)
  fi
  echo -e "\e[1;33mRelease artifacts + BUILD_INFO.txt written to $redist_dir\e[0m"
}

# set some parameters initial values
cur_dir="$PWD/sandbox"
patch_dir="${PWD%/*}/patches"
redist_base_dir="${PWD%/*}/redist" # Captured here (before intro() below does 'cd $cur_dir', which would shift $PWD by one level and break a later ${PWD%/*}-based computation) -- the final, dated $redist_dir gets built from this once host_target etc. are known.
cpu_count=4 # Also drives every do_make's "-j $cpu_count", not just the gcc bootstrap; match this to the container's --cpus cap.
build_timestamp=$(date +%Y_%m_%d_%H_%M_%S) # Captured once at script start, so every archive from this run lands in the same dated redist/ folder.
build_timestamp_human=$(date +"%Y-%m-%d %H:%M:%S %Z") # Same moment, human-readable form for BUILD_INFO.txt.
ffmpeg_version_tag="n8.1.2" # Keep in sync with the pinned commit in build_ffmpeg() below -- avoids a live 'git describe' at packaging time and lets the redist folder name be known before build_dependencies even starts (FFmpeg's own checkout, where 'git describe' would normally run, doesn't happen until build_apps, long after other archives may already need $redist_dir).

set_box_memory_size_bytes
if [[ $box_memory_size_bytes -lt 600000000 ]]; then
  echo "your box only has $box_memory_size_bytes, 512MB (only) boxes crash when building cross compiler gcc, please add some swap" # 1G worked OK however...
  exit 1
fi

if [[ $box_memory_size_bytes -gt 2000000000 ]]; then
  gcc_cpu_count=$cpu_count # they can handle it seemingly...
else
  echo "low RAM detected so using only one cpu for gcc compilation"
  gcc_cpu_count=1 # compatible low RAM...
fi

# variables with their defaults
build_ffmpeg_static=y
target_arch='32' # '32' (i686-w64-mingw32) or '64' (x86_64-w64-mingw32, for Windows XP x64 Edition / Server 2003). See --arch= below.
original_cflags='-O2 -march=core2 -mtune=core2' # Targets Core 2 (e.g. Q6600): up to SSSE3, no SSE4.1/4.2/AVX. See https://gcc.gnu.org/onlinedocs/gcc/x86-Options.html, https://gcc.gnu.org/onlinedocs/gcc/Optimize-Options.html and https://stackoverflow.com/questions/19689014/gcc-difference-between-o3-and-os.
export ac_cv_func__mktemp_s=no   # _mktemp_s is not available on WinXP.
export ac_cv_func_vsnprintf_s=no # Mark vsnprintf_s as unavailable, as windows xp mscrt doesn't have it.

# parse command line parameters, if any
while true; do
  case $1 in
    -h | --help ) echo "available option=default_value:
      --build-ffmpeg-static=y  (ffmpeg.exe, ffplay.exe and ffprobe.exe)
      --build-ffmpeg-static=n  (ffmpeg.exe, ffplay.exe, ffprobe.exe and dll-files)
      --ffmpeg-git-checkout-version=[master] if you want to build a particular version of FFmpeg, ex: n3.1.1 or a specific git hash
      --sandbox-ok=n [skip sandbox prompt if y]
      -d [meaning \"defaults\" skip all prompts, just build ffmpeg static with some reasonable defaults like no git updates]
      --cflags=[default is $original_cflags, which works on any cpu, see README for options]
      --arch=[32 or 64, default is $target_arch -- 64 targets Windows XP x64 Edition/Server 2003, not regular 32-bit XP]
      --debug Make this script  print out each line as it executes
       "; exit 0 ;;
    --sandbox-ok=* ) sandbox_ok="${1#*=}"; shift ;;
    --cflags=* )
       original_cflags="${1#*=}"; echo "setting cflags as $original_cflags"; shift ;;
    --arch=* )
       target_arch="${1#*=}"; shift ;;
    -d         ) gcc_cpu_count=$cpu_count; sandbox_ok="y"; shift ;;
    --build-ffmpeg-static=* ) build_ffmpeg_static="${1#*=}"; shift ;;
    --debug ) set -x; shift ;;
    -- ) shift; break ;;
    -* ) echo "Error, unknown option: '$1'."; exit 1 ;;
    * ) break ;;
  esac
done

case "$target_arch" in
  32 ) host_target='i686-w64-mingw32';   mingw_w64_build_type='win32'; mingw_arch_dir='mingw-w64-i686';   arch_bits_label='32bit' ;;
  64 ) host_target='x86_64-w64-mingw32'; mingw_w64_build_type='win64'; mingw_arch_dir='mingw-w64-x86_64'; arch_bits_label='64bit' ;;
  * ) echo "Error: --arch must be 32 or 64, got '$target_arch'."; exit 1 ;;
esac

reset_cflags # also overrides any "native" CFLAGS, which we may need if there are some 'linux only' settings in there
check_missing_packages # do this first since it's annoying to go through prompts then be rejected
intro # remember to always run the intro, since it adjust pwd
install_cross_compiler

export PKG_CONFIG_LIBDIR= # disable pkg-config from finding [and using] normal linux system installed libs [yikes]

# Short human-readable CPU-tuning label for release naming, e.g. "core2" out of "-O2 -march=core2 -mtune=core2".
# Derived from $original_cflags (which --cflags= may have overridden above) rather than a separately-tracked
# variable, so it can't drift out of sync with what was actually built.
cpu_target_label=$(grep -oE -- '-march=[A-Za-z0-9_-]+' <<<"$original_cflags" | head -1 | sed 's/^-march=//')
cpu_target_label="${cpu_target_label:-generic}"

original_path="$PATH"
echo -e "Starting ${arch_bits_label} builds ($host_target, cpu tuning: $cpu_target_label).\n"
target_suffix="winxp-${cpu_target_label}-${arch_bits_label}" # e.g. "winxp-core2-32bit". Shared by every packaged .7z below and the redist/ folder name itself.
redist_dir="${redist_base_dir}/${build_timestamp}_ffmpeg-${ffmpeg_version_tag}_${target_suffix}"
mkdir -p "$redist_dir"
cat > "$redist_dir/BUILD_INFO.txt" <<BUILDINFOEOF
FFmpeg XP build -- build info
==============================

Build started:   $build_timestamp_human
FFmpeg version:   $ffmpeg_version_tag (FFmpeg/FFmpeg.git, release/8.1 branch -- see cross_compile_ffmpeg.sh for the exact pinned commit)
Target:           Windows XP (PE subsystem version <= 5.1), CPU tuning "$cpu_target_label", $arch_bits_label
CFLAGS:           $original_cflags

This is a from-source rebuild of every dependency (~63 libraries), each
individually pinned to a specific commit/version and XP-compatibility
patched where needed (routed off Windows Vista+-only APIs like SRWLOCK/
CONDITION_VARIABLE/InitOnce*/BCryptGenRandom and onto POSIX pthreads /
the legacy CryptoAPI). Full per-dependency version, pin date, and patch
documentation: see DEPENDENCY_VERSIONS.md in the source repository
(xp-core2 branch of ffmpeg-windows-build-helpers).

Binaries in this build were verified with scripts/check-xp-compat.sh to
import zero Windows Vista+-only Win32 APIs. That is a static/import-level
check, not a substitute for an actual run on real XP hardware/a VM.
BUILDINFOEOF
mingw_w64_x86_64_prefix="$cur_dir/cross_compilers/${mingw_arch_dir}/$host_target" # Variable name is legacy/misleading (kept as-is to avoid touching all 36+ build_X() references to it) -- holds whichever arch's ($target_arch) sysroot is actually active.
mingw_bin_path="$cur_dir/cross_compilers/${mingw_arch_dir}/bin"
export PKG_CONFIG_PATH="$mingw_w64_x86_64_prefix/lib/pkgconfig"
export PATH="$mingw_bin_path:$original_path"
cross_prefix="$mingw_bin_path/${host_target}-"
make_prefix_options="CC=${cross_prefix}gcc AR=${cross_prefix}ar PREFIX=$mingw_w64_x86_64_prefix RANLIB=${cross_prefix}ranlib LD=${cross_prefix}ld STRIP=${cross_prefix}strip CXX=${cross_prefix}g++"
meson_cross_file="$cur_dir/meson-cross-${host_target}.txt" # Filename is now arch-specific too, so concurrent/alternating 32- and 64-bit runs sharing the same $cur_dir don't clobber each other's cross-file mid-build.
cat > "$meson_cross_file" <<EOF
[binaries]
c = '${cross_prefix}gcc'
cpp = '${cross_prefix}g++'
ar = '${cross_prefix}ar'
strip = '${cross_prefix}strip'
windres = '${cross_prefix}windres'
pkgconfig = 'pkg-config'

[host_machine]
system = 'windows'
cpu_family = '$([[ $target_arch == 64 ]] && echo x86_64 || echo x86)'
cpu = '$([[ $target_arch == 64 ]] && echo x86_64 || echo i686)'
endian = 'little'
EOF
build_subdir="win${target_arch}-${cpu_target_label}" # Tier+arch-specific dependency/FFmpeg build tree, e.g. "win32-pentium3" or "win64-sandybridge" -- keeps every CPU tier's compiled .a/.o files (which aren't binary-compatible across -march= flags) fully separate, while cross_compilers/ above stays shared per-arch.
mkdir -p "$build_subdir"
cd "$build_subdir"
  build_dependencies
  build_apps
cd ..
finalize_redist
