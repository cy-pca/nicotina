#!/usr/bin/env bash
# ci/build-hosts.sh: build the Ariadne hosts the tests run, ari and arigl, natively for Linux,
# from a libcvc checkout that already has the pull requests nicotina needs (ci/libcvc-prs.sh).
#
#   ci/build-hosts.sh LIBCVC_DIR ROOT
#
# Everything goes under ROOT, which is what CI caches:
#   ROOT/deps      a cvcpkg prefix: the libraries ari and arigl link
#   ROOT/tools     a cvcpkg prefix with cmake and ninja. It is kept apart from deps because cmake
#                  searches its own prefix, and the static curl and openssl it brings would win
#                  over deps' shared ones (libcvc's .github/actions/cvcpkg-build-tools says why).
#   ROOT/build     the build tree; ROOT/build/bin/ari and ROOT/build/bin/arigl, which find their
#                  libraries in ROOT/build/lib and ROOT/deps/lib (their RUNPATH)
#
# A lean configuration: the Ariadne hosts with both terminal backends (FTXUI and tvision) and
# cvcGL's ImGui window, and none of the imaging, meshing, CUDA, gRPC or Python parts nicotina
# doesn't use. Nothing comes from apt; the compiler is the system's.
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 LIBCVC_DIR ROOT" >&2; exit 2; }
src=$(cd "$1" && pwd)
root=$2
mkdir -p "$root"
root=$(cd "$root" && pwd)
deps=$root/deps tools=$root/tools build=$root/build

install_deps() {
  local p
  cvcpkg install cmake ninja --prefix "$tools" --config release --link shared
  # curl and openssl: cvc::net's HTTP backend and the device keys. libcvc finds them QUIETly
  # and builds a stub without them, so the configure check below insists on the backend.
  for p in zlib bzip2 xz zstd openssl curl boost pegtl yaml-cpp nlohmann-json \
           json-schema-validator ftxui tvision ncurses eigen libpng libjpeg-turbo freetype vtk \
           imgui sdl3; do
    cvcpkg install "$p" --prefix "$deps" --config release --link shared
  done
}
install_deps

export PATH=$tools/bin:$PATH
cmake -G Ninja -S "$src" -B "$build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$deps" \
  -DCVC_BUILD_ARI=ON -DCVC_BUILD_ARIGL=ON -DCVC_BUILD_CVCGL=ON -DCVC_ARIADNE_TVISION=ON \
  -DCVC_BUILD_TESTS=OFF -DCVC_BUILD_CLI=OFF -DCVC_BUILD_EXAMPLES=OFF -DCVC_BUILD_PYCVC=OFF \
  -DCVC_ENABLE_CUDA=OFF -DCVC_ENABLE_GRPC=OFF \
  -DDISABLE_CGAL=ON -DCVC_USING_HDF5=OFF -DCVC_USING_IMOD_MRC=OFF \
  -DCVC_ENABLE_IMAGEMAGICK=OFF -DCVC_ENABLE_FFTW=OFF -DCVC_FFT_PROVIDER=none \
  -DCVC_ENABLE_ASSIMP=OFF -DCVC_ENABLE_MESHER=OFF -DCVC_ENABLE_SDF=OFF -DCVC_ENABLE_LIBIGL=OFF \
  | tee "$root/configure.log"

# A configure that misses one of these turns it off and carries on, and the hosts would fail the
# tests for a reason that has nothing to do with nicotina.
for want in "Ariadne: .ari YAML loader ENABLED" \
            "Ariadne: FTXUI terminal backend ENABLED" \
            "Ariadne: tvision terminal backend ENABLED" \
            "cvcGL: Dear ImGui overlay ENABLED" \
            "cvc::net: libcurl HTTP backend ENABLED"; do
  grep -qF "$want" "$root/configure.log" \
    || { echo "::error::the configure did not report '$want' (deps in $deps)" >&2; exit 1; }
done

cmake --build "$build" --target ari arigl -j "${CVC_JOBS:-$(nproc)}"

# The cache keeps the binaries and libraries, not the objects.
find "$build" -name '*.o' -delete
if ldd "$build/bin/ari" "$build/bin/arigl" | grep 'not found'; then
  echo "::error::ari or arigl cannot find a shared library" >&2
  exit 1
fi
