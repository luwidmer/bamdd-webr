# The worker pool lives in the page, as globalThis.__webrPool (js/workers.js), and R
# reaches it with webr::eval_js(). Only with `await = TRUE` does eval_js() run code
# on the page's main thread -- without it, code runs in R's own Web Worker, where
# the pool does not exist -- so every call awaits, even a synchronous one. While R
# waits the page stays responsive, so the workers keep running and the console's
# Stop still works: it cancels the pool's tasks, which ends the wait.

.state <- new.env(parent = emptyenv())
.state$mode <- "none"
.state$n <- 0L
.state$stream <- NULL
.state$generation <- NA_integer_
.state$closed_from_toolbar <- FALSE
# Stands in for a worker's global environment when tasks run in the console.
.state$global <- NULL

js <- function(code) {
  if (!requireNamespace("webr", quietly = TRUE)) {
    stop("miraiWebR runs only in webR, inside the BAMDD with webR/brms/stanli application",
         call. = FALSE)
  }
  webr::eval_js(code, await = TRUE)
}

pool <- function(method, ...) {
  args <- vapply(list(...), function(a) {
    if (is.character(a)) as.character(jsonlite::toJSON(a, auto_unbox = TRUE)) else format(a)
  }, character(1))
  js(sprintf("globalThis.__webrPool.%s(%s)", method, paste(args, collapse = ", ")))
}

check_not_worker <- function(what) {
  worker <- Sys.getenv("MIRAI_WEBR_WORKER")
  if (nzchar(worker)) {
    stop(what, " cannot be used inside a webR worker (this is worker ", worker,
         "); workers do not start workers of their own", call. = FALSE)
  }
}

check_pool <- function() {
  check_not_worker("daemons()")
  if (!identical(js("typeof globalThis.__webrPool"), "object")) {
    stop("no webR worker pool on this page: miraiWebR needs the BAMDD with webR/brms/stanli ",
         "application, not a plain webR console", call. = FALSE)
  }
}

# Run `expr` and put R's random number generator back as it was, kind included, so
# that seeding task streams leaves the caller's own stream alone.
with_preserved_rng <- function(expr) {
  env <- globalenv()
  kind <- RNGkind()
  had_seed <- exists(".Random.seed", envir = env, inherits = FALSE)
  if (had_seed) old <- get(".Random.seed", envir = env, inherits = FALSE)
  on.exit({
    if (had_seed) {
      assign(".Random.seed", old, envir = env)
    } else {
      if (exists(".Random.seed", envir = env, inherits = FALSE)) rm(".Random.seed", envir = env)
      RNGkind(kind[1], kind[2], kind[3])
    }
  })
  expr
}

# Every task gets its own L'Ecuyer-CMRG stream, the next one along from the last, so
# results depend on the seed and the order tasks are created in, and not on which
# worker happens to run them.
init_stream <- function(seed) {
  .state$stream <- with_preserved_rng({
    set.seed(seed, kind = "L'Ecuyer-CMRG")
    get(".Random.seed", envir = globalenv())
  })
}

next_stream <- function() {
  .state$stream <- parallel::nextRNGStream(.state$stream)
  .state$stream
}
