#!/usr/bin/env bash
# Download the prebuilt browser UI libraries into vendor/.
#
# Both are plain <script> bundles on purpose: this project has no build step, so
# anything requiring a bundler (e.g. CodeMirror 6) is out of scope.
#   xterm.js       UMD build       -> terminal
#   CodeMirror 5   UMD build       -> editor (CM6 is ESM-with-bundler only)

set -euo pipefail

XTERM_VERSION="${XTERM_VERSION:-5.3.0}"
XTERM_FIT_VERSION="${XTERM_FIT_VERSION:-0.8.0}"
CM_VERSION="${CM_VERSION:-5.65.16}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fetch() {
  local url="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  echo "  $(basename "$dest")  <-  $url"
  curl --fail --location --silent --show-error --output "$dest" "$url"
  if [[ ! -s "$dest" ]]; then
    echo "ERROR: empty download: $url" >&2
    exit 1
  fi
}

# We do not vendor the .map files, so leaving the reference in makes devtools 404.
strip_sourcemap_ref() {
  local f="$1"
  sed '/^\/\/# sourceMappingURL=/d' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

echo "xterm.js ${XTERM_VERSION}"
fetch "https://unpkg.com/xterm@${XTERM_VERSION}/lib/xterm.js"     "$root/vendor/xterm/xterm.js"
fetch "https://unpkg.com/xterm@${XTERM_VERSION}/css/xterm.css"    "$root/vendor/xterm/xterm.css"
fetch "https://unpkg.com/xterm-addon-fit@${XTERM_FIT_VERSION}/lib/xterm-addon-fit.js" \
      "$root/vendor/xterm/xterm-addon-fit.js"
strip_sourcemap_ref "$root/vendor/xterm/xterm.js"
strip_sourcemap_ref "$root/vendor/xterm/xterm-addon-fit.js"
# The minified bundles carry no copyright notice, so the MIT texts ship beside them.
fetch "https://unpkg.com/xterm@${XTERM_VERSION}/LICENSE" "$root/vendor/xterm/LICENSE"
fetch "https://unpkg.com/xterm-addon-fit@${XTERM_FIT_VERSION}/LICENSE" \
      "$root/vendor/xterm/LICENSE.xterm-addon-fit"

echo "CodeMirror ${CM_VERSION}"
fetch "https://unpkg.com/codemirror@${CM_VERSION}/lib/codemirror.js"  "$root/vendor/codemirror/codemirror.js"
fetch "https://unpkg.com/codemirror@${CM_VERSION}/lib/codemirror.css" "$root/vendor/codemirror/codemirror.css"
fetch "https://unpkg.com/codemirror@${CM_VERSION}/mode/r/r.js"        "$root/vendor/codemirror/r.js"
fetch "https://unpkg.com/codemirror@${CM_VERSION}/theme/material-darker.css" \
      "$root/vendor/codemirror/material-darker.css"
fetch "https://unpkg.com/codemirror@${CM_VERSION}/theme/eclipse.css" \
      "$root/vendor/codemirror/eclipse.css"
fetch "https://unpkg.com/codemirror@${CM_VERSION}/LICENSE" "$root/vendor/codemirror/LICENSE"
# Find/replace. The browser's own Ctrl+F cannot see lines CodeMirror has not rendered.
for f in dialog/dialog.js dialog/dialog.css search/searchcursor.js search/search.js; do
  fetch "https://unpkg.com/codemirror@${CM_VERSION}/addon/${f}" "$root/vendor/codemirror/addon/${f}"
done

echo
echo "Vendored UI libraries:"
find "$root/vendor/xterm" "$root/vendor/codemirror" -type f -exec ls -lh {} \; | awk '{print "  " $5 "\t" $9}'
