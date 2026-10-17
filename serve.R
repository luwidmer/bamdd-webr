# Serve this directory cross-origin isolated, which webR needs for SharedArrayBuffer.
#
# Without COOP/COEP the SharedArrayBuffer channel is unavailable and webR silently falls
# back to PostMessage, which cannot do readline()/menu()/browser() or interrupt a running
# computation -- i.e. the terminal stops working. See README "Why the server matters".
#
#   Rscript serve.R [port]
#
# httpuv >= 1.6 already maps .mjs -> text/javascript and .wasm -> application/wasm,
# so no content-type overrides are needed here (verified against httpuv 1.6.17).

if (!requireNamespace("httpuv", quietly = TRUE)) {
  stop(
    "The 'httpuv' package is required.\n",
    "  install.packages('httpuv')\n",
    "Or use the no-dependency alternative: python3 serve.py",
    call. = FALSE
  )
}

args <- commandArgs(trailingOnly = TRUE)
port <- if (length(args) >= 1L) suppressWarnings(as.integer(args[[1L]])) else 8080L
if (is.na(port)) {
  stop("Port must be an integer, got: ", args[[1L]], call. = FALSE)
}

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
root <- if (length(script_arg) == 1L) {
  dirname(normalizePath(sub("^--file=", "", script_arg)))
} else {
  normalizePath(getwd())
}

if (!file.exists(file.path(root, "index.html"))) {
  stop("No index.html found in ", root, " -- is serve.R in the project root?", call. = FALSE)
}

headers <- list(
  "Cross-Origin-Opener-Policy" = "same-origin",
  "Cross-Origin-Embedder-Policy" = "require-corp",
  "Cache-Control" = "no-cache"
)

cat(sprintf("Serving %s\n", root))
cat(sprintf("  http://127.0.0.1:%d\n", port))
cat("  COOP/COEP set; check `crossOriginIsolated === true` in the browser console.\n")

httpuv::runServer(
  host = "127.0.0.1",
  port = port,
  app = list(
    staticPaths = list(
      "/" = httpuv::staticPath(root, indexhtml = TRUE, headers = headers)
    )
  )
)
