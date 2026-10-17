#' Start or stop background webR workers
#'
#' `daemons(n)` starts `n` webR workers, each a complete R in its own Web Worker
#' with the application's package library mounted, so tasks sent to them with
#' [mirai()], [mirai_map()] or the [webr_workers] future backend run in parallel
#' with the console and with each other. `daemons(0)` stops them. Restarting R,
#' `q()`, or "Shut down workers" in the toolbar's workers pill stop them too.
#'
#' Workers start from a clean R: they share no objects, attached packages or files
#' with the console. Load packages with [everywhere()] or inside the task, and pass
#' data in through `...` or `.args`. Packages installed in the console during the
#' session are not visible to them; the library image is.
#'
#' Each worker costs a full R heap, so the number is capped at the browser's core
#' count less one, and at four. In the phone layout there are no workers at all:
#' `daemons(n)` then says so and switches to running every task in the console,
#' one at a time, so code written for workers still runs. What [everywhere()]
#' defines then lives in an environment on the search path,
#' `"miraiWebR:sequential"`, rather than in the console's workspace; `daemons(0)`
#' removes it.
#'
#' @param n Number of workers; `0` stops them.
#' @param ... Other arguments of `mirai::daemons()`. None is supported: remote,
#'   TLS and dispatcher settings have no meaning in a browser, and are refused
#'   rather than ignored.
#' @param seed `NULL`, or an integer that makes the random number streams of the
#'   tasks that follow reproducible. Each task draws from its own L'Ecuyer-CMRG
#'   stream, in the order the tasks are created, whichever worker runs them.
#' @param .compute Compute profiles are not supported; must be `NULL`.
#' @return The number of workers, invisibly.
#' @seealso [status()], [mirai()], [webr_workers]
#' @export
#' @examples
#' \dontrun{
#' daemons(2)
#' m <- mirai(Sys.getenv("MIRAI_WEBR_WORKER"))
#' m[]
#' daemons(0)
#' }
daemons <- function(n, ..., seed = NULL, .compute = NULL) {
  if (...length()) {
    stop("daemons() argument(s) not supported by miraiWebR: ",
         paste(names(list(...)), collapse = ", "), call. = FALSE)
  }
  if (!is.null(.compute)) stop("compute profiles are not supported by miraiWebR", call. = FALSE)
  if (missing(n)) {
    stop("daemons(n) starts n webR workers and daemons(0) stops them; ",
         "use status() to see what is running", call. = FALSE)
  }
  if (length(n) != 1L || !is.numeric(n) || is.na(n) || n < 0 || n != floor(n)) {
    stop("n must be a single non-negative whole number", call. = FALSE)
  }
  n <- as.integer(n)
  check_pool()
  if (n == 0L) {
    pool("close")
    drop_sequential_global()
    .state$mode <- "none"
    .state$n <- 0L
    .state$closed_from_toolbar <- FALSE
    return(invisible(0L))
  }
  sync_state()
  if (.state$mode != "none") {
    stop("daemons are already set (", .state$n, " ", .state$mode, "); ",
         "call daemons(0) first", call. = FALSE)
  }
  limits <- jsonlite::fromJSON(pool("limits"))
  init_stream(seed)
  if (limits$max == 0L) {
    message("webR workers are not available: ", limits$reason, ".\n",
            "Tasks will run in this R session, one at a time.")
    .state$global <- sequential_global()
    .state$mode <- "sequential"
    .state$n <- 0L
    return(invisible(0L))
  }
  pool("start", n)
  .state$mode <- "workers"
  .state$n <- n
  .state$generation <- jsonlite::fromJSON(pool("status"))$generation
  .state$closed_from_toolbar <- FALSE
  invisible(n)
}

# Tasks run in the console share one environment in place of the worker's global
# environment. It sits on the search path because a task's functions look up
# names through their own environments, usually ending at the console's global
# environment, not in the environment the task is evaluated in.
SEQUENTIAL_GLOBAL <- "miraiWebR:sequential"

sequential_global <- function() {
  drop_sequential_global()
  attach(NULL, name = SEQUENTIAL_GLOBAL, warn.conflicts = FALSE)
}

drop_sequential_global <- function() {
  if (SEQUENTIAL_GLOBAL %in% search()) detach(SEQUENTIAL_GLOBAL, character.only = TRUE)
  .state$global <- NULL
}

# The toolbar can shut the workers down behind R's back; notice, and forget them.
# Returns the pool's status while the workers are still ours, otherwise NULL.
sync_state <- function() {
  if (.state$mode != "workers") return(NULL)
  s <- jsonlite::fromJSON(pool("status"))
  if (identical(as.integer(s$generation), as.integer(.state$generation))) return(s)
  .state$mode <- "none"
  .state$n <- 0L
  .state$closed_from_toolbar <- TRUE
  NULL
}

#' Are daemons set?
#'
#' @return `TRUE` once [daemons()] has been called with `n > 0`, whether workers
#'   started or, in the phone layout, tasks run in the console instead.
#' @export
daemons_set <- function() {
  sync_state()
  .state$mode != "none"
}

#' Status of the webR workers
#'
#' `status()` mirrors the shape of `mirai::status()`; `info()` that of
#' `mirai::info()`.
#'
#' @return For `status()`, a list: `connections`, the number of running workers
#'   (0 when tasks run in the console); `daemons`, the same; `mode`, one of
#'   `"workers"`, `"sequential"` or `"none"`; and `mirai`, counts of tasks
#'   awaiting, executing and completed. For `info()`, those counts and
#'   `connections` as a named integer vector.
#' @export
status <- function() {
  counts <- task_counts()
  list(
    connections = counts[["connections"]],
    daemons = counts[["connections"]],
    mode = .state$mode,
    mirai = counts[c("awaiting", "executing", "completed")]
  )
}

#' @rdname status
#' @export
info <- function() {
  task_counts()
}

task_counts <- function() {
  s <- sync_state()
  if (is.null(s)) {
    return(c(connections = 0L, awaiting = 0L, executing = 0L, completed = 0L))
  }
  c(connections = as.integer(s$ready), awaiting = as.integer(s$queued),
    executing = as.integer(s$busy), completed = as.integer(s$completed))
}
