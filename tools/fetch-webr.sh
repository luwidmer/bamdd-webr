#!/usr/bin/env bash
# Download and unpack the webR distribution into vendor/webr/.
#
# The bundled R version MUST match the contrib/<ver> directory used by
# tools/build-library.R -- wasm packages built for a different R version will not
# load. webR 0.6.0 bundles R 4.6.0. If you bump WEBR_VERSION here, update
# R_CONTRIB in tools/build-library.R and rebuild the library image.

set -euo pipefail

WEBR_VERSION="${WEBR_VERSION:-0.6.0}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$root/vendor/webr"
tarball="$root/vendor/webr-${WEBR_VERSION}.tar.gz"
# Note: the git tag is v0.6.0 but the asset filename has no 'v'.
url="https://github.com/r-wasm/webr/releases/download/v${WEBR_VERSION}/webr-${WEBR_VERSION}.tar.gz"

if [[ -f "$dest/webr.mjs" && "${FORCE:-0}" != "1" ]]; then
  echo "vendor/webr already populated; set FORCE=1 to re-download."
else
  mkdir -p "$root/vendor"
  echo "Downloading webR v${WEBR_VERSION}"
  echo "  $url"
  curl --fail --location --progress-bar --output "$tarball" "$url"

  rm -rf "$dest"
  mkdir -p "$dest"
  # The release tarball wraps everything in a top-level directory.
  tar -xzf "$tarball" -C "$dest" --strip-components=1
  rm -f "$tarball"
fi

# The release tarball ships no licence, and the site redistributes webR.
if [[ ! -s "$dest/LICENSE.md" || "${FORCE:-0}" == "1" ]]; then
  curl --fail --location --silent --show-error --output "$dest/LICENSE.md" \
    "https://raw.githubusercontent.com/r-wasm/webr/v${WEBR_VERSION}/LICENSE.md"
fi

for required in webr.mjs webr-worker.js R.wasm R.js LICENSE.md; do
  if [[ ! -f "$dest/$required" ]]; then
    echo "ERROR: $required missing after unpacking. Tarball layout may have changed." >&2
    find "$dest" -maxdepth 2 | head -50 >&2
    exit 1
  fi
done

# The wasm package library must be built for exactly this R version.
r_version="$(grep -oE '4\.[0-9]+\.[0-9]+' "$dest/webr.mjs" | sort -u | head -1)"
echo
echo "webR v${WEBR_VERSION} unpacked into vendor/webr/ (bundles R ${r_version})"
echo "Ensure R_CONTRIB in tools/build-library.R matches R ${r_version%.*}"
du -sh "$dest"
