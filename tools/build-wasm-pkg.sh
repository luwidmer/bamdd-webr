#!/usr/bin/env bash
#
# Cross-compile a CRAN package to WebAssembly, for packages that repo.r-wasm.org does
# not carry. Reuses the build image from RBesT's webR harness (github.com/Novartis/RBesT,
# tools/webr/docker, cloned to vendor/BesT), which already has rwasm, the Emscripten SDK
# and a webR tree.
#
#   tools/build-wasm-pkg.sh jinjar 0.3.2
#   WASM_PKG_STAN=1 tools/build-wasm-pkg.sh RBesT 1.12-0
#
# WASM_PKG_STAN=1 prepares an rstantools package before building: it drops the native
# RcppParallel/TBB link flags that wasm-ld cannot use and compiles in the TBB no-op
# stubs Stan math needs. See tools/build-wasm-pkg.R.
#
# Output goes to build/wasm-extra/<pkg>_<version>.tgz; run tools/vendor-wasm-repo.R
# afterwards to fold it into vendor/wasm-repo.
#
# If tools/wasm-patches/<pkg>_<version>.patch exists it is applied to the unpacked
# source first. jinjar needs one: the nlohmann/json copy vendored inside inja writes
# `auto* const` where libstdc++ yields a raw pointer but Emscripten's libc++ yields
# std::__wrap_iter, so it does not compile. That is why no wasm build of it exists.
# Matrix needs one too: its vendored CHOLMOD passes a negative band limit through a
# size_t, which on wasm32 turns positive, so crossprod() of an RsparseMatrix and
# solve(<CHMfactor>, system = "L") come back empty. sass and vroom carry the webR
# fixes rwasm builds for repo.r-wasm.org: libsass compiled with wasm exceptions, and
# vroom's std::async() work launched deferred, as webR's side modules cannot start threads.
set -euo pipefail

pkg="${1:-}"
version="${2:-}"
if [ -z "$pkg" ] || [ -z "$version" ]; then
  echo "usage: $0 <package> <version>" >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
best="$root/vendor/BesT"
docker_dir="$best/tools/webr/docker"
image="rbest-wasm-native:${WEBR_TAG:-v0.6.0}"
stage="$root/build/wasm-build/$pkg"
out="$root/build/wasm-extra"
patch="$root/tools/wasm-patches/${pkg}_${version}.patch"

[ -d "$docker_dir" ] || {
  echo "vendor/BesT is missing. Clone the build harness first:" >&2
  echo "  git clone --depth 1 --branch v1.12-0 https://github.com/Novartis/RBesT.git $best" >&2
  exit 1
}
docker image inspect "$image" >/dev/null 2>&1 || {
  echo "Image $image not found. Build it first:" >&2
  echo "  cd $docker_dir && RBEST_SRC=$best docker compose build" >&2
  exit 1
}

rm -rf "$stage"
mkdir -p "$stage/src" "$out"

echo "[build-wasm-pkg] fetching ${pkg}_${version}.tar.gz"
# CRAN moves superseded versions to Archive/<pkg>/, so a pin outlives the next release.
cran="https://cloud.r-project.org/src/contrib"
curl -sSfL -o "$stage/${pkg}_${version}.tar.gz" "$cran/${pkg}_${version}.tar.gz" 2>/dev/null ||
  curl -sSfL -o "$stage/${pkg}_${version}.tar.gz" "$cran/Archive/${pkg}/${pkg}_${version}.tar.gz" || {
    echo "ERROR: ${pkg}_${version}.tar.gz is neither current on CRAN nor in its archive" >&2
    exit 1
  }

if [ -f "$patch" ]; then
  echo "[build-wasm-pkg] applying $(basename "$patch")"
  tar xzf "$stage/${pkg}_${version}.tar.gz" -C "$stage/src"
  ( cd "$stage/src/$pkg" && patch -p1 --forward < "$patch" )
  ( cd "$stage/src" && tar czf "../${pkg}_${version}.tar.gz" "$pkg" )
fi

# rwasm reuses a previously staged source tarball if one is already in the repo, which
# silently rebuilds the unpatched sources.
rm -rf "$stage/repo"

# LinkingTo headers are installed in the image at the versions the library will carry:
# a package already built into build/wasm-extra first (it displaces the upstream build,
# as TMB does for mmrm), else the version lib/MANIFEST.tsv pins. The first match wins.
built_pins="$(cd "$out" && for f in *.tgz; do
  if [ -e "$f" ]; then printf '%s,' "$(basename "$f" .tgz | sed 's/_/=/')"; fi
done)"
pins="${built_pins}$(awk -F'\t' 'NR > 1 { printf "%s%s=%s", sep, $1, $2; sep = "," }' "$root/lib/MANIFEST.tsv")"

echo "[build-wasm-pkg] cross-compiling in $image"
cd "$docker_dir"
RBEST_SRC="$best" \
RBEST_OUT="$stage" \
CORP_CERTS_DIR="${CORP_CERTS_DIR:-$docker_dir/certs.d}" \
WEBR_TAG="${WEBR_TAG:-v0.6.0}" \
  docker compose run --rm \
    -v "$root/tools:/tools:ro" \
    -e WASM_PKG_TARBALL="/out/${pkg}_${version}.tar.gz" \
    -e WASM_REPO_DIR="/out/repo" \
    -e WASM_PKG_DEPS="${WASM_PKG_DEPS:-FALSE}" \
    -e WASM_PKG_STAN="${WASM_PKG_STAN:-}" \
    -e WASM_PKG_PINS="$pins" \
    -e WASM_TBB_STUB="/tools/wasm-patches/webr-tbb-stubs.cpp" \
    build R -q -f /tools/build-wasm-pkg.R

built="$stage/repo/bin/emscripten/contrib/4.6/${pkg}_${version}.tgz"
[ -f "$built" ] || { echo "expected $built" >&2; exit 1; }
cp -v "$built" "$out/"

echo "[build-wasm-pkg] next:  Rscript tools/vendor-wasm-repo.R"
