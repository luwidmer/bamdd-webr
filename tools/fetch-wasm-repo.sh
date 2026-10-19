#!/usr/bin/env bash
#
# Download the bundle of the seven wasm packages that have no usable upstream build,
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

# Release assets of a private repository are not reachable anonymously: GitHub answers
# 404 rather than 401. Fall back to the `gh` CLI (or a token) whenever the default
# github.com base is in use and the plain download fails.
gh_repo() {
  case "$base" in
    https://github.com/*/releases/download)
      local rest="${base#https://github.com/}"
      echo "${rest%/releases/download}"
      ;;
    *) echo "" ;;
  esac
}

download() {
  local url="$1" dest="$2" asset
  if curl --fail --location --silent --show-error --output "$dest" "$url"; then
    return 0
  fi
  rm -f "$dest"
  local repo; repo="$(gh_repo)"
  [ -n "$repo" ] || die "download failed: $url"
  asset="$(basename "$url")"
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [ -n "$token" ]; then
    echo "[fetch-wasm-repo] retrying $asset with token auth"
    local api
    api="$(curl --fail --location --silent --show-error \
      -H "Authorization: Bearer $token" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$repo/releases/tags/$tag")" || die "download failed: $url"
    local id
    id="$(printf '%s' "$api" | python3 -c "import json,sys;r=json.load(sys.stdin);print(next((a['id'] for a in r['assets'] if a['name']==sys.argv[1]),''))" "$asset")"
    [ -n "$id" ] || die "release $tag has no asset $asset"
    curl --fail --location --silent --show-error \
      -H "Authorization: Bearer $token" \
      -H "Accept: application/octet-stream" \
      --output "$dest" "https://api.github.com/repos/$repo/releases/assets/$id" ||
      die "download failed: $url"
    return 0
  fi
  if command -v gh >/dev/null 2>&1; then
    echo "[fetch-wasm-repo] retrying $asset via gh (private repository)"
    gh release download "$tag" --repo "$repo" --pattern "$asset" --output "$dest" --clobber ||
      die "download failed: $url"
    return 0
  fi
  die "download failed: $url
  The repository may be private. Install the GitHub CLI and run 'gh auth login',
  or export GH_TOKEN with a token that can read $repo."
}

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
  Run .github/workflows/wasm-repo.yml and merge its pull request, or build the seven
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
download "$url" "$archive"

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
download "$url" "$packages"
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
