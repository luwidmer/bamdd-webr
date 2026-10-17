#!/usr/bin/env bash
#
# Assemble the deployable static site into dist/.
#
#   tools/make-dist.sh                 # exactly what gets uploaded
#   tools/make-dist.sh --with-image    # ... plus lib/library.tar.gz, for local testing
#
# The filesystem image is deliberately NOT part of the upload: it is ~137 MB and
# Cloudflare Pages rejects any asset over 25 MiB, so it is served from R2 instead and
# js/config.js is rewritten to point at it. See DEPLOY.md.
set -euo pipefail

# Cloudflare Pages rejects any single asset above this.
MAX_ASSET_MIB=25

with_image=0
case "${1:-}" in
  --with-image) with_image=1 ;;
  "") ;;
  *) echo "usage: $0 [--with-image]" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
dist="$root/dist"

# Everything index.html references, plus what the session fetches at runtime.
FILES=(index.html favicon.svg LICENSE _headers)
DIRS=(css js r workspace vendor/webr vendor/xterm vendor/codemirror)

cd "$root"

for path in "${FILES[@]}" "${DIRS[@]}"; do
  [ -e "$path" ] || {
    echo "ERROR: $path is missing. Run tools/fetch-webr.sh and tools/fetch-ui-libs.sh first." >&2
    exit 1
  }
done

rm -rf "$dist"
mkdir -p "$dist"

for f in "${FILES[@]}"; do
  cp "$f" "$dist/"
done
for d in "${DIRS[@]}"; do
  mkdir -p "$dist/$(dirname "$d")"
  cp -R "$d" "$dist/$d"
done

# index.html links these by name; a rename upstream must fail here, not in the browser.
for asset in \
  vendor/codemirror/codemirror.css vendor/codemirror/material-darker.css \
  vendor/codemirror/eclipse.css vendor/codemirror/codemirror.js vendor/codemirror/r.js \
  vendor/codemirror/addon/dialog/dialog.css vendor/codemirror/addon/dialog/dialog.js \
  vendor/codemirror/addon/search/searchcursor.js vendor/codemirror/addon/search/search.js \
  vendor/xterm/xterm.css vendor/xterm/xterm.js vendor/xterm/xterm-addon-fit.js \
  vendor/xterm/LICENSE vendor/xterm/LICENSE.xterm-addon-fit vendor/codemirror/LICENSE \
  vendor/webr/webr.mjs vendor/webr/webr-worker.js vendor/webr/R.wasm vendor/webr/LICENSE.md \
  css/app.css js/app.js js/config.js js/session.js js/version.js r/webrapp.R
do
  [ -f "$dist/$asset" ] || { echo "ERROR: $asset missing from dist/" >&2; exit 1; }
done

# The release version lives in package.json only; a release tag must match it.
version="$(sed -nE 's/^  "version": "([^"]+)",?$/\1/p' package.json)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: no x.y.z \"version\" in package.json (got '$version')" >&2
  exit 1
}
echo "export const APP_VERSION = '$version';" > "$dist/js/version.js"

oversized="$(find "$dist" -type f -size "+${MAX_ASSET_MIB}M" -print)"
if [ -n "$oversized" ]; then
  echo "ERROR: asset(s) over ${MAX_ASSET_MIB} MiB, which Cloudflare Pages will reject:" >&2
  echo "$oversized" | while read -r f; do ls -lh "$f" >&2; done
  exit 1
fi

if [ "$with_image" = 1 ]; then
  [ -f "$root/lib/library.tar.gz" ] || {
    echo "ERROR: lib/library.tar.gz not built. Run tools/build-library.R && tools/pack-library.R" >&2
    exit 1
  }
  mkdir -p "$dist/lib"
  cp "$root/lib/library.tar.gz" "$dist/lib/"
  echo "[make-dist] included lib/library.tar.gz (local testing only; never uploaded to Pages)"
fi

echo "[make-dist] version $version; $(find "$dist" -type f | wc -l | tr -d ' ') files, $(du -sh "$dist" | cut -f1) in dist/"
