# miraiWebR drives the application's worker pool, globalThis.__webrPool, so it can only
# be tested inside webR. tools/test-packages.mjs provides a pool that reports no
# workers, which exercises the console fallback; tools/test-browser.mjs the real one.
pool_max <- function() {
  if (!requireNamespace("webr", quietly = TRUE)) return(NA_integer_)
  if (!identical(webr::eval_js("typeof globalThis.__webrPool", await = TRUE), "object")) {
    return(NA_integer_)
  }
  as.integer(jsonlite::fromJSON(miraiWebR:::pool("limits"))$max)
}

skip_unless_sequential <- function() {
  skip_if_not(identical(pool_max(), 0L), "needs a worker pool without workers (tools/test-packages.mjs)")
}

skip_unless_workers <- function() {
  skip_if_not(isTRUE(pool_max() >= 2L), "needs two webR workers (tools/test-browser.mjs)")
}

local_daemons <- function(n, ..., env = parent.frame()) {
  suppressMessages(daemons(n, ...))
  withr::defer(daemons(0), envir = env)
}
