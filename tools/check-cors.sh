#!/usr/bin/env bash
#
# Check that the filesystem image answers every site origin with a usable
# Access-Control-Allow-Origin; without one, COEP blocks the image for that origin.
#
#   tools/check-cors.sh <image-url> <origin>...
#
# Origins are probed in the order given. Listing one again after another catches an
# edge cache that replays the first origin's echoed header to the second.
set -euo pipefail

[ $# -ge 2 ] || { echo "usage: $0 <image-url> <origin>..." >&2; exit 2; }
url="$1"
shift

failed=0
for origin in "$@"; do
  origin="${origin%/}"
  acao="$(curl -sS -I -H "Origin: $origin" "$url" \
          | tr -d '\r' | awk -F': ' 'tolower($1)=="access-control-allow-origin"{print $2}')"
  if [ "$acao" = "*" ] || [ "$acao" = "$origin" ]; then
    echo "[cors] ok    $origin -> $acao"
  else
    echo "[cors] FAIL  $origin -> ${acao:-no Access-Control-Allow-Origin}" >&2
    failed=1
  fi
done
exit "$failed"
