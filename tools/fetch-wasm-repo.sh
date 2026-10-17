#!/usr/bin/env bash
#
# Download the bundle of the seven wasm packages that have no usable upstream build,
# as pinned in lib/WASM_REPO, and unpack it into vendor/wasm-repo/. This is what lets
# a build skip Docker; see "The wasm package bundle" in DEPLOY.md.
#
#   tools/fetch-wasm-repo.sh
#   WASM_REPO_BASE=file:///some/dir tools/fetch-wasm-repo.sh   # expects <dir>/<TAG>/<TAG>.tar.gz
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
if [ -z "$tag" ] || [ -z "$want" ] || [ "$tag" = PENDING ] || [ "$want" = PENDING ]; then
  die "lib/WASM_REPO names no published bundle (TAG=${tag:-unset}).
  Run .github/workflows/wasm-repo.yml and merge its pull request, or build the seven
  packages locally (README, \"Build\")."
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
