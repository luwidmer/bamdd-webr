#!/usr/bin/env bash
#
# Download the bundle of the twelve wasm packages built for this project,
# as pinned in lib/WASM_REPO, and unpack it into vendor/wasm-repo/. This is what lets
# a build skip Docker; see "The wasm package bundle" in DEPLOY.md. The same Release
# carries every other pinned package as resolved, unpacked into vendor/pkgcache/, so
# the frozen build-library.R downloads nothing from the upstream repositories.
#
#   tools/fetch-wasm-repo.sh
#   WASM_REPO_BASE=file:///some/dir tools/fetch-wasm-repo.sh   # expects <dir>/<TAG>/<TAG>.tar.gz
#                                                              # and <dir>/<TAG>/<TAG>-packages.tar
#
# It deliberately does not run tools/vendor-wasm-repo.R: that would fold any local
# builds in build/wasm-extra over the verified bundle. The bundle carries its own index.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pin="$root/lib/WASM_REPO"
dest="$root/vendor/wasm-repo"
base="${WASM_REPO_BASE:-https://github.com/luwidmer/bamdd-webr/releases/download}"
# MUST match R_CONTRIB in tools/build-library.R.
r_contrib="4.6"

die() { echo "ERROR: $*" >&2; exit 1; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

tag="$(sed -n 's/^TAG=//p' "$pin")"
want="$(sed -n 's/^SHA256=//p' "$pin")"
packages_want="$(sed -n 's/^PACKAGES_SHA256=//p' "$pin")"
if [ -z "$tag" ] || [ -z "$want" ] || [ "$tag" = PENDING ] || [ "$want" = PENDING ]; then
  die "lib/WASM_REPO names no published bundle (TAG=${tag:-unset}).
  Run .github/workflows/wasm-repo.yml and merge its pull request, or build the twelve
  packages locally (README, \"Build\")."
fi
if [ -z "$packages_want" ] || [ "$packages_want" = PENDING ]; then
  die "lib/WASM_REPO pins no package archive (PACKAGES_SHA256) for $tag.
  Re-run .github/workflows/wasm-repo.yml and merge its pull request."
fi
if [ -e "$dest" ] && [ "${FORCE:-0}" != 1 ]; then
  die "vendor/wasm-repo already exists; set FORCE=1 to replace it with bundle $tag."
fi

mkdir -p "$root/vendor"
archive="$root/vendor/$tag.tar.gz"
url="$base/$tag/$tag.tar.gz"
echo "[fetch-wasm-repo] $url"
curl --fail --location --silent --show-error --output "$archive" "$url"

got="$(sha256 "$archive")"
if [ "$got" != "$want" ]; then
  rm -f "$archive"
  die "sha256 mismatch for $tag
  expected $want (lib/WASM_REPO)
  got      $got"
fi

rm -rf "$dest"
tar -xzf "$archive" -C "$root" vendor/wasm-repo
rm -f "$archive"

index="$dest/bin/emscripten/contrib/$r_contrib/PACKAGES"
[ -s "$index" ] || die "bundle $tag carries no package index at ${index#"$root"/}"

echo "[fetch-wasm-repo] $tag verified and unpacked:"
(cd "$dest/bin/emscripten/contrib/$r_contrib" && ls -1 ./*.tgz | sed 's|^\./|  |')

packages="$root/vendor/$tag-packages.tar"
url="$base/$tag/$tag-packages.tar"
echo "[fetch-wasm-repo] $url"
curl --fail --location --silent --show-error --output "$packages" "$url"
got="$(sha256 "$packages")"
if [ "$got" != "$packages_want" ]; then
  rm -f "$packages"
  die "sha256 mismatch for $tag-packages.tar
  expected $packages_want (lib/WASM_REPO)
  got      $got"
fi
mkdir -p "$root/vendor/pkgcache"
tar -xf "$packages" -C "$root/vendor/pkgcache"
echo "[fetch-wasm-repo] $(tar -tf "$packages" | wc -l | tr -d ' ') pinned packages verified and unpacked into vendor/pkgcache"
rm -f "$packages"
