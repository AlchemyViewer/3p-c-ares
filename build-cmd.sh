#!/usr/bin/env bash

cd "$(dirname "$0")"

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain about unset env variables
set -u

if [ -z "$AUTOBUILD" ] ; then
    exit 1
fi

if [ "$OSTYPE" = "cygwin" ] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

CARES_SOURCE_DIR="c-ares"
CARES_BUILD_DIR="build"

top="$(pwd)"
stage="$(pwd)/stage"

# load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

CARES_VERSION_HEADER_DIR="${CARES_SOURCE_DIR}"/include
version=$(perl -ne 's/#define ARES_VERSION_STR "([^"]+)"/$1/ && print' "${CARES_VERSION_HEADER_DIR}/ares_version.h" | tr -d '\r' )
echo "${version}" > "${stage}/VERSION.txt"

# Restore all .sos
restore_sos ()
{
    for solib in "${stage}"/packages/lib/release/lib*.so*.disable; do
        if [ -f "$solib" ]; then
            mv -f "$solib" "${solib%.disable}"
        fi
    done
}


# Restore all .dylibs
restore_dylibs ()
{
    for dylib in "$stage/packages/lib"/release/*.dylib.disable; do
        if [ -f "$dylib" ]; then
            mv "$dylib" "${dylib%.disable}"
        fi
    done
}

# Read the version of a particular installable package from autobuild.xml.
# Optional $2 specifies number of version-number parts to report.
get_installable_version ()
{
    set +x
    # This command dumps the autobuild.xml data for the specified installable
    # in Python literal syntax.
    pydata="$("$autobuild" installables print "$1")"
    # Now harvest the version key.
    # It's important to use ''' syntax because of newlines in output. Specify
    # raw literal syntax too in case of backslashes.
    # Use ast.literal_eval(), safer than plain builtin eval.
    # Once we have the Python dict, extract "version" key.
    # Split version number on '.'.
    # Keep up to $2 version-number parts.
    # Rejoin them on '.' again and print.
    # On Windows, change '\r\n' to plain '\n': the '\r' is NOT removed by
    # bash, so it becomes part of the string contents, which confuses both
    # scripted comparisons and human readers.
    python -c "from ast import literal_eval
print('.'.join(literal_eval(r'''$pydata''')['version'].split('.')[:${2:-}]))" \
    | tr -d '\r'
    set -x
}

# Given an (e.g. version) string possibly containing periods, escape those
# periods with backslashes.
escape_dots ()
{
    echo "${1//./\\.}"
}

pushd "$CARES_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in
        windows*)
            load_vsvars

            packages="$(cygpath -m "$stage/packages")"

            if [ "$AUTOBUILD_ADDRSIZE" = 32 ]
            then
                targetarch=x86
            else
                targetarch=x64
            fi

            export INSTALL_DIR="$(cygpath -w "$stage")"

            export INSTALL_DIR_LIB="$(cygpath -w "$stage\lib\debug")"
            nmake /f Makefile.msvc CFG=lib-debug
            nmake /f Makefile.msvc CFG=lib-debug install

            export INSTALL_DIR_LIB="$(cygpath -w "$stage\lib\release")"
            nmake /f Makefile.msvc CFG=lib-release
            nmake /f Makefile.msvc CFG=lib-release install
        ;;
    
        darwin*)
            # Force libz and openssl static linkage by moving .dylibs out of the way
            trap restore_dylibs EXIT
            for dylib in "$stage"/packages/lib/release/lib{z,crypto,ssl}*.dylib; do
                if [ -f "$dylib" ]; then
                    mv "$dylib" "$dylib".disable
                fi
            done

            # Setup osx sdk platform
            SDKNAME="macosx"
            export SDKROOT=$(xcodebuild -version -sdk ${SDKNAME} Path)
            export MACOSX_DEPLOYMENT_TARGET=10.15

            # Setup build flags
            ARCH_FLAGS="-arch x86_64"
            SDK_FLAGS="-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} -isysroot ${SDKROOT}"
            DEBUG_COMMON_FLAGS="$ARCH_FLAGS $SDK_FLAGS -Og -g -msse4.2 -fPIC -DPIC"
            RELEASE_COMMON_FLAGS="$ARCH_FLAGS $SDK_FLAGS -O3 -g -msse4.2 -fPIC -DPIC -fstack-protector-strong"
            DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
            RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
            DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
            RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
            DEBUG_CPPFLAGS="-DPIC"
            RELEASE_CPPFLAGS="-DPIC"
            DEBUG_LDFLAGS="$ARCH_FLAGS $SDK_FLAGS -Wl,-headerpad_max_install_names"
            RELEASE_LDFLAGS="$ARCH_FLAGS $SDK_FLAGS -Wl,-headerpad_max_install_names"

            mkdir -p "$stage/include/curl"
            mkdir -p "$stage/lib/debug"
            mkdir -p "$stage/lib/release"

            mkdir -p "build_debug"
            pushd "build_debug"
                CFLAGS="$DEBUG_CFLAGS" \
                CXXFLAGS="$DEBUG_CXXFLAGS" \
                CPPFLAGS="$DEBUG_CPPFLAGS" \
                LDFLAGS="$DEBUG_LDFLAGS" \
                cmake .. -GNinja -DCMAKE_BUILD_TYPE=Debug -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_C_FLAGS="$DEBUG_CFLAGS" \
                    -DCMAKE_CXX_FLAGS="$DEBUG_CXXFLAGS" \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_OPTIMIZATION_LEVEL="0" \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_FAST_MATH=NO \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=YES \
                    -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT=dwarf \
                    -DCMAKE_XCODE_ATTRIBUTE_LLVM_LTO=NO \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_X86_VECTOR_INSTRUCTIONS=sse4.2 \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD="c++17" \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LIBRARY="libc++" \
                    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
                    -DCMAKE_OSX_ARCHITECTURES:STRING=x86_64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DCMAKE_OSX_SYSROOT=${SDKROOT} \
                    -DCMAKE_MACOSX_RPATH=YES -DCMAKE_INSTALL_PREFIX=$stage \
                    -DENABLE_THREADED_RESOLVER:BOOL=ON \
                    -DCURL_USE_OPENSSL:BOOL=TRUE \
                    -DZLIB_LIBRARIES="${stage}/packages/lib/debug/libz.a" \
                    -DZLIB_INCLUDE_DIRS="${stage}/packages/include/zlib" \
                    -DNGHTTP2_LIBRARIES="${stage}/packages/lib/debug/libnghttp2.a" \
                    -DNGHTTP2_INCLUDE_DIRS="${stage}/packages/include/nghttp2" \
                    -DOPENSSL_LIBRARIES="${stage}/packages/lib/debug/libcrypto.a;${stage}/packages/lib/debug/libssl.a" \
                    -DOPENSSL_INCLUDE_DIR="${stage}/packages/include/"

                cmake --build . --config Debug
                
                mkdir -p "${stage}/install_debug"
                cmake --install . --config Debug --prefix "${stage}/install_debug"

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Debug
                fi

                # Run 'curl' as a sanity check. Capture just the first line, which
                # should have versions of stuff.
                curlout="$("${stage}"/install_debug/bin/curl --version | tr -d '\r' | head -n 1)"
                # With -e in effect, any nonzero rc blows up the script --
                # so plain 'expr str : pattern' asserts that str contains pattern.
                # curl version - should be start of line
                expr "$curlout" : "curl $(escape_dots "$version")" > /dev/null
                # libcurl/version
                expr "$curlout" : ".* libcurl/$(escape_dots "$version")" > /dev/null
                # OpenSSL/version
                expr "$curlout" : ".* OpenSSL/$(escape_dots "$(get_installable_version openssl 3)")" > /dev/null
                # zlib/version
                expr "$curlout" : ".* zlib/1.2.11.zlib-ng" > /dev/null
                # nghttp2/versionx
                expr "$curlout" : ".* nghttp2/$(escape_dots "$(get_installable_version nghttp2 3)")" > /dev/null

                cp -a ${stage}/install_debug/lib/libcurld.a "${stage}/lib/debug/libcurl.a"
            popd

            mkdir -p "build_release"
            pushd "build_release"
                CFLAGS="$RELEASE_CFLAGS" \
                CXXFLAGS="$RELEASE_CXXFLAGS" \
                CPPFLAGS="$RELEASE_CPPFLAGS" \
                LDFLAGS="$RELEASE_LDFLAGS" \
                cmake .. -GNinja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_C_FLAGS="$RELEASE_CFLAGS" \
                    -DCMAKE_CXX_FLAGS="$RELEASE_CXXFLAGS" \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_OPTIMIZATION_LEVEL="3" \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_FAST_MATH=NO \
                    -DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=YES \
                    -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT=dwarf \
                    -DCMAKE_XCODE_ATTRIBUTE_LLVM_LTO=NO \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_X86_VECTOR_INSTRUCTIONS=sse4.2 \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD="c++17" \
                    -DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LIBRARY="libc++" \
                    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
                    -DCMAKE_OSX_ARCHITECTURES:STRING=x86_64 \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DCMAKE_OSX_SYSROOT=${SDKROOT} \
                    -DCMAKE_MACOSX_RPATH=YES -DCMAKE_INSTALL_PREFIX=$stage \
                    -DENABLE_THREADED_RESOLVER:BOOL=ON \
                    -DCURL_USE_OPENSSL:BOOL=TRUE \
                    -DZLIB_LIBRARIES="${stage}/packages/lib/release/libz.a" \
                    -DZLIB_INCLUDE_DIRS="${stage}/packages/include/zlib" \
                    -DNGHTTP2_LIBRARIES="${stage}/packages/lib/release/libnghttp2.a" \
                    -DNGHTTP2_INCLUDE_DIRS="${stage}/packages/include/nghttp2" \
                    -DOPENSSL_LIBRARIES="${stage}/packages/lib/release/libcrypto.a;${stage}/packages/lib/release/libssl.a" \
                    -DOPENSSL_INCLUDE_DIR="${stage}/packages/include/"

                cmake --build . --config Release

                mkdir -p "${stage}/install_debug"
                cmake --install . --config Release --prefix "${stage}/install_release"

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release
                fi

                # Run 'curl' as a sanity check. Capture just the first line, which
                # should have versions of stuff.
                curlout="$("${stage}"/install_release/bin/curl --version | tr -d '\r' | head -n 1)"
                # With -e in effect, any nonzero rc blows up the script --
                # so plain 'expr str : pattern' asserts that str contains pattern.
                # curl version - should be start of line
                expr "$curlout" : "curl $(escape_dots "$version")" > /dev/null
                # libcurl/version
                expr "$curlout" : ".* libcurl/$(escape_dots "$version")" > /dev/null
                # OpenSSL/version
                expr "$curlout" : ".* OpenSSL/$(escape_dots "$(get_installable_version openssl 3)")" > /dev/null
                # zlib/version
                expr "$curlout" : ".* zlib/1.2.11.zlib-ng" > /dev/null
                # nghttp2/versionx
                expr "$curlout" : ".* nghttp2/$(escape_dots "$(get_installable_version nghttp2 3)")" > /dev/null

                cp -a ${stage}/install_release/lib/libcurl.a "${stage}/lib/release/libcurl.a"

                cp -a ${stage}/install_release/include/curl/* "$stage/include/curl"
            popd
            #cp "$NGHTTP2_VERSION_HEADER_DIR"/*.h "$stage/include/nghttp2/"
        ;;
    
        linux*)
            # Linux build environment at Linden comes pre-polluted with stuff that can
            # seriously damage 3rd-party builds.  Environmental garbage you can expect
            # includes:
            #
            #    DISTCC_POTENTIAL_HOSTS     arch           root        CXXFLAGS
            #    DISTCC_LOCATION            top            branch      CC
            #    DISTCC_HOSTS               build_name     suffix      CXX
            #    LSDISTCC_ARGS              repo           prefix      CFLAGS
            #    cxx_version                AUTOBUILD      SIGN        CPPFLAGS
            #
            # So, clear out bits that shouldn't affect our configure-directed build
            # but which do nonetheless.
            #
            unset DISTCC_HOSTS CC CXX CFLAGS CPPFLAGS CXXFLAGS
            
            # Default target per --address-size
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE}"
            DEBUG_COMMON_FLAGS="$opts -Og -g -fPIC"
            RELEASE_COMMON_FLAGS="$opts -O3 -g -fPIC -fstack-protector-strong"
            DEBUG_CFLAGS="$DEBUG_COMMON_FLAGS"
            RELEASE_CFLAGS="$RELEASE_COMMON_FLAGS"
            DEBUG_CXXFLAGS="$DEBUG_COMMON_FLAGS -std=c++17"
            RELEASE_CXXFLAGS="$RELEASE_COMMON_FLAGS -std=c++17"
            DEBUG_CPPFLAGS="-DPIC -DNGHTTP2_STATICLIB"
            RELEASE_CPPFLAGS="-DPIC -D_FORTIFY_SOURCE=2 -DNGHTTP2_STATICLIB"
            
            JOBS=`cat /proc/cpuinfo | grep processor | wc -l`
            
            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="$TARGET_CPPFLAGS"
            fi
            
            # Force static linkage to libz and openssl by moving .sos out of the way
            trap restore_sos EXIT
            for solib in "${stage}"/packages/lib/{release}/lib{z,ssl,crypto}.so*; do
                if [ -f "$solib" ]; then
                    mv -f "$solib" "$solib".disable
                fi
            done
            
            mkdir -p "$stage/lib/release"
            mkdir -p "$stage/lib/debug"
            
            # Fix up path for pkgconfig
            if [ -d "$stage/packages/lib/release/pkgconfig" ]; then
                fix_pkgconfig_prefix "$stage/packages"
            fi
            
            OLD_PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"
            
            # force regenerate autoconf
            autoreconf -fvi
            
            # Autoconf's configure will do some odd things to flags.  '-I' options
            # will get transferred to '-isystem' and there's a problem with quoting.
            # Linking and running also require LD_LIBRARY_PATH to locate the OpenSSL
            # .so's.  The '--with-ssl' option could do this if we had a more normal
            # package layout.
            #
            # configure-time compilation looks like:
            # ac_compile='$CC -c $CFLAGS $CPPFLAGS conftest.$ac_ext >&5'
            # ac_link='$CC -o conftest$ac_exeext $CFLAGS $CPPFLAGS $LDFLAGS conftest.$ac_ext $LIBS >&5'
            saved_path="${LD_LIBRARY_PATH:-}"
            
            # Debug configure and build
            export PKG_CONFIG_PATH="${stage}/packages/lib/debug/pkgconfig:${OLD_PKG_CONFIG_PATH}"
            export LD_LIBRARY_PATH="${stage}"/packages/lib/debug:"$saved_path"
            
            # -g/-O options controled by --enable-debug/-optimize.  Unfortunately,
            # --enable-debug also defines DEBUGBUILD which changes behaviors.
            CFLAGS="$DEBUG_CFLAGS" \
            CXXFLAGS="$DEBUG_CXXFLAGS" \
            CPPFLAGS="$DEBUG_CPPFLAGS -I$stage/packages/include -I$stage/packages/include/zlib" \
            LDFLAGS="-L$stage/packages/lib/debug/" \
            LIBS="-ldl -lpthread" \
            ./configure --disable-debug --disable-curldebug --disable-optimize --enable-shared=no --enable-threaded-resolver \
            --enable-cookies --disable-ldap --disable-ldaps  --without-libssh2 \
            --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/debug" \
            --with-ssl="$stage"/packages --with-zlib="$stage"/packages --with-nghttp2="$stage"/packages/

            make -j$JOBS
            make install DESTDIR="$stage"
            
            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                pushd tests
                # We hijack the 'quiet-test' target and redefine it as
                # a no-valgrind test.  Also exclude test 320.  It fails in the
                # 7.41 distribution with our configuration options.
                #
                # Expect problems with the unit tests, they're very sensitive
                # to environment.
                make quiet-test TEST_Q='-n !46 !320'
                popd
            fi
            
            # Run 'curl' as a sanity check. Capture just the first line, which
            # should have versions of stuff.
            curlout="$("${stage}"/bin/curl --version | tr -d '\r' | head -n 1)"
            # With -e in effect, any nonzero rc blows up the script --
            # so plain 'expr str : pattern' asserts that str contains pattern.
            # curl version - should be start of line
            expr "$curlout" : "curl $(escape_dots "$version")" #> /dev/null
            # libcurl/version
            expr "$curlout" : ".* libcurl/$(escape_dots "$version")" > /dev/null
            # OpenSSL/version
            expr "$curlout" : ".* OpenSSL/$(escape_dots "$(get_installable_version openssl 3)")" > /dev/null
            # zlib/version
            expr "$curlout" : ".* zlib/1.2.11.zlib-ng" > /dev/null
            # nghttp2/versionx
            expr "$curlout" : ".* nghttp2/$(escape_dots "$(get_installable_version nghttp2 3)")" > /dev/null
            
            make clean || true
            
            # Release configure and build
            export PKG_CONFIG_PATH="$stage/packages/lib/release/pkgconfig:${OLD_PKG_CONFIG_PATH}"
            export LD_LIBRARY_PATH="${stage}"/packages/lib/release:"$saved_path"
            
            CFLAGS="$RELEASE_CFLAGS" \
            CXXFLAGS="$RELEASE_CXXFLAGS" \
            CPPFLAGS="$RELEASE_CPPFLAGS -I$stage/packages/include -I$stage/packages/include/zlib" \
            LDFLAGS="-L$stage/packages/lib/release/" \
            LIBS="-ldl -lpthread" \
            ./configure --disable-curldebug --disable-debug  --enable-optimize --enable-shared=no --enable-threaded-resolver \
            --enable-cookies --disable-ldap --disable-ldaps --without-libssh2 \
            --prefix="\${AUTOBUILD_PACKAGES_DIR}" --libdir="\${prefix}/lib/release" \
            --with-ssl="$stage"/packages --with-zlib="$stage"/packages --with-nghttp2="$stage"/packages/

            make -j$JOBS
            make install DESTDIR="$stage"
            
            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                pushd tests
                make quiet-test TEST_Q='-n !46 !320'
                popd
            fi
            
            # Run 'curl' as a sanity check. Capture just the first line, which
            # should have versions of stuff.
            curlout="$("${stage}"/bin/curl --version | tr -d '\r' | head -n 1)"
            # With -e in effect, any nonzero rc blows up the script --
            # so plain 'expr str : pattern' asserts that str contains pattern.
            # curl version - should be start of line
            expr "$curlout" : "curl $(escape_dots "$version")" #> /dev/null
            # libcurl/version
            expr "$curlout" : ".* libcurl/$(escape_dots "$version")" > /dev/null
            # OpenSSL/version
            expr "$curlout" : ".* OpenSSL/$(escape_dots "$(get_installable_version openssl 3)")" > /dev/null
            # zlib/version
            expr "$curlout" : ".* zlib/1.2.11.zlib-ng" > /dev/null
            # nghttp2/version
            expr "$curlout" : ".* nghttp2/$(escape_dots "$(get_installable_version nghttp2 3)")" > /dev/null
            
            make clean || true
            
            export LD_LIBRARY_PATH="$saved_path"
        ;;
    esac

    mkdir -p "$stage/LICENSES"
    cp LICENSE.md "$stage/LICENSES/c-ares.txt"
popd