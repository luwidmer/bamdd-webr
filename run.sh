#! /bin/bash
# One-shot local setup and launch.
#
#   bash run.sh          # set up anything missing, then serve on http://127.0.0.1:8080
#   FORCE=1 bash run.sh  # re-fetch the pinned wasm package bundle as well
#
# Safe to re-run: every step is skipped when its output already exists.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A stale GITHUB_PAT in ~/.Renviron makes remotes::install_github() fail with
# "401 Bad credentials", so prefer a working `gh` token when one is available.
if ! Rscript -e 'quit(status = !requireNamespace("rwasm", quietly = TRUE))'; then
  echo "[run] installing r-wasm/rwasm"
  if command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
    GH_TOKEN_VAL="$(gh auth token)" Rscript -e \
      'Sys.setenv(GITHUB_PAT = Sys.getenv("GH_TOKEN_VAL")); remotes::install_github("r-wasm/rwasm", upgrade = "never")'
  else
    Rscript -e 'remotes::install_github("r-wasm/rwasm", upgrade = "never")'
  fi
fi

# Fetch the webR runtime, UI libraries and pinned WebAssembly packages.
[ -f vendor/webr/webr.mjs ] || bash tools/fetch-webr.sh
[ -f vendor/codemirror/codemirror.js ] || bash tools/fetch-ui-libs.sh
# The release assets live in a private repository; fetch-wasm-repo.sh falls back to
# `gh` (or GH_TOKEN) because an anonymous download answers 404.
if [ ! -d vendor/wasm-repo ] || [ "${FORCE:-0}" = 1 ]; then
  FORCE="${FORCE:-0}" bash tools/fetch-wasm-repo.sh
fi

# Build the R package library image.
[ -d build/library ] || Rscript tools/build-library.R
[ -f lib/library.tar.gz ] || Rscript tools/pack-library.R

# Start the local site.
python3 serve.py
