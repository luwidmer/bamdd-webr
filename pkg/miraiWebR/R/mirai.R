#' Evaluate an expression on a webR worker
#'
#' Sends `.expr` to the next free worker started by [daemons()] and returns at
#' once. The result is a 'mirai': `m$data` is the value once it is ready, and an
#' 'unresolved' placeholder until then; `m[]` waits for it. An error in the task
#' is returned as a 'miraiError' value rather than raised, as in 'mirai'.
#'
#' The expression is evaluated in a fresh environment whose parent is the worker's
#' global environment. Objects passed through `...` are put in that global
#' environment for the duration of the task, so functions passed together can find
#' one another; objects in `.args` stay local to the evaluation.
#'
#' Whatever the task prints appears in the console, prefixed with the worker's
#' number.
#'
#' @param .expr The expression to evaluate, or a language object.
#' @param ... Named objects the expression needs, or a single environment holding
#'   them.
#' @param .args A named list, or an environment, of objects kept local to the
#'   evaluation.
#' @param .timeout,.compute Not supported; must be `NULL`.
#' @return A 'mirai'.
#' @seealso [mirai_map()], [everywhere()], [collect_mirai()]
#' @export
#' @examples
#' \dontrun{
#' daemons(2)
#' m <- mirai(sum(rnorm(n)), n = 1e6)
#' unresolved(m)
#' m[]
#' }
mirai <- function(.expr, ..., .args = list(), .timeout = NULL, .compute = NULL) {
  if (!is.null(.timeout)) stop(".timeout is not supported by miraiWebR", call. = FALSE)
  if (!is.null(.compute)) stop("compute profiles are not supported by miraiWebR", call. = FALSE)
  expr <- substitute(.expr)
  if (is.symbol(expr) && is.language(.expr)) expr <- .expr
  submit(task(expr, globals = named_objects(list(...), "..."),
              args = named_objects(.args, ".args")))
}

#' Evaluate an expression on every webR worker
#'
#' For setting workers up: loading packages, defining helper functions, reading
#' data. Unlike [mirai()], the expression is evaluated in each worker's global
#' environment and objects passed through `...` stay there, so later tasks can
#' use them. Waits until every worker is done, and raises the first error.
#'
#' When tasks run in the console (see [daemons()]), the expression is evaluated
#' once there, in the environment that stands in for a worker's global
#' environment, so later tasks find what it defines, as they would on a worker.
#'
#' @inheritParams mirai
#' @param .compute Compute profiles are not supported; must be `NULL`.
#' @return The values, one per worker, invisibly.
#' @export
#' @examples
#' \dontrun{
#' daemons(2)
#' everywhere(library(brms))
#' }
everywhere <- function(.expr, ..., .args = list(), .compute = NULL) {
  if (!is.null(.compute)) stop("compute profiles are not supported by miraiWebR", call. = FALSE)
  expr <- substitute(.expr)
  if (is.symbol(expr) && is.language(.expr)) expr <- .expr
  t <- task(expr, globals = named_objects(list(...), "..."),
            args = named_objects(.args, ".args"), persist = TRUE)
  pins <- if (.state$mode == "workers") seq_len(.state$n) - 1L else -1L
  ms <- lapply(pins, function(pin) submit(t, pin = pin))
  values <- lapply(ms, collect_mirai)
  for (v in values) {
    if (is_error_value(v)) stop("everywhere() failed: ", format_error(v), call. = FALSE)
  }
  invisible(values)
}

named_objects <- function(x, what) {
  if (length(x) == 1L && is.null(names(x)) && is.environment(x[[1]])) x <- x[[1]]
  if (is.environment(x)) x <- as.list(x, all.names = TRUE)
  if (!is.list(x)) stop(what, " must be named objects or an environment", call. = FALSE)
  if (length(x) && (is.null(names(x)) || any(!nzchar(names(x))))) {
    stop("every object in ", what, " must be named", call. = FALSE)
  }
  x
}

task <- function(expr, globals = list(), args = list(), persist = FALSE) {
  sync_state()
  if (.state$mode == "none") {
    if (.state$closed_from_toolbar) {
      stop("the webR workers were shut down from the toolbar; call daemons(n) again", call. = FALSE)
    }
    stop("no daemons set: call daemons(n) to start webR workers first", call. = FALSE)
  }
  list(expr = expr, globals = globals, args = args, persist = persist,
       stream = next_stream())
}

new_mirai <- function() {
  m <- new.env(parent = emptyenv())
  m$.id <- NA_integer_
  m$.done <- FALSE
  m$.value <- NULL
  makeActiveBinding("data", function() {
    if (!m$.done) poll(m, wait = FALSE)
    if (m$.done) m$.value else unresolved_value()
  }, m)
  class(m) <- "mirai"
  m
}

submit <- function(task, pin = -1L) {
  m <- new_mirai()
  if (.state$mode == "sequential") {
    # Run now, in place of a worker: the caller's workspace must not be touched.
    m$.value <- run_task(task, global = .state$global)
    m$.done <- TRUE
    return(m)
  }
  payload <- gsub("\n", "", jsonlite::base64_enc(serialize(task, NULL)), fixed = TRUE)
  m$.id <- as.integer(pool("submit", payload, as.integer(pin)))
  m
}

# Fetch a finished task's value; with `wait`, block until it is finished.
poll <- function(m, wait) {
  if (m$.done) return(invisible(m))
  if (!wait && !identical(pool("state", m$.id), "done")) return(invisible(m))
  m$.value <- decode_reply(pool("collect", m$.id))
  m$.done <- TRUE
  pool("release", m$.id)
  invisible(m)
}

decode_reply <- function(reply) {
  if (startsWith(reply, "R:")) {
    return(unserialize(jsonlite::base64_dec(substring(reply, 3L))))
  }
  parts <- regmatches(reply, regexec("^E:([0-9]+):(.*)$", reply))[[1]]
  if (length(parts) != 3L) stop("unexpected reply from the worker pool: ", substr(reply, 1, 80), call. = FALSE)
  error_value(as.integer(parts[2]), parts[3])
}

error_value <- function(code, message) {
  structure(code, message = message, class = "errorValue")
}

unresolved_value <- function() {
  structure(NA, class = "unresolvedValue")
}

#' Wait for and retrieve results
#'
#' `unresolved()` asks without waiting; `call_mirai()` waits and returns its
#' argument; `collect_mirai()` and `m[]` wait and return the value(s).
#' `stop_mirai()` cancels a task: dropped if still queued, interrupted if running;
#' its value becomes an 'errorValue' 20.
#'
#' The console's Stop button cancels every task, which also ends any wait, and
#' interrupts R. "Cancel tasks" in the toolbar's workers pill cancels them the same
#' way but leaves R running, so waiting code carries on with the error values.
#'
#' @param x A 'mirai', a 'mirai_map', a list of them, or (for `unresolved()`) the
#'   value of `m$data`.
#' @param options For `collect_mirai()` on a list or 'mirai_map': any of
#'   `".flat"`, `".progress"` and `".stop"`, as for `x[.flat]` etc. on a
#'   'mirai_map'.
#' @return `unresolved()`: `TRUE` while anything is unresolved. `call_mirai()`:
#'   `x`, invisibly. `collect_mirai()`: the value(s). `stop_mirai()`: logical,
#'   whether each task was still pending.
#' @export
unresolved <- function(x) {
  if (inherits(x, "mirai")) return(!poll(x, wait = FALSE)$.done)
  if (inherits(x, "unresolvedValue")) return(TRUE)
  if (is.list(x) && !is.object(x) || inherits(x, "mirai_map")) {
    return(any(vapply(x, function(m) inherits(m, "mirai") && unresolved(m), logical(1))))
  }
  FALSE
}

#' @rdname unresolved
#' @export
call_mirai <- function(x) {
  if (inherits(x, "mirai")) poll(x, wait = TRUE)
  else for (m in x) if (inherits(m, "mirai")) poll(m, wait = TRUE)
  invisible(x)
}

#' @rdname unresolved
#' @export
collect_mirai <- function(x, options = NULL) {
  if (inherits(x, "mirai")) {
    if (length(options)) stop("options apply to lists and mirai_maps, not a single mirai", call. = FALSE)
    return(poll(x, wait = TRUE)$.value)
  }
  collect_list(x, options)
}

#' @rdname unresolved
#' @export
stop_mirai <- function(x) {
  if (!inherits(x, "mirai")) return(vapply(x, stop_mirai, logical(1)))
  if (x$.done || is.na(x$.id)) return(FALSE)
  isTRUE(pool("cancel", x$.id))
}

#' @export
`[.mirai` <- function(x, i) {
  collect_mirai(x)
}

#' @export
print.mirai <- function(x, ...) {
  cat(if (x$.done) "< mirai [$data] >\n" else "< mirai [] >\n")
  invisible(x)
}

#' Errors returned by tasks
#'
#' A task that raises an error returns a 'miraiError': the message, of class
#' `c("miraiError", "errorValue", "try-error")`, with the original condition's
#' class and the call stack as attributes `condition.class` and `stack.trace`. A
#' task stopped by [stop_mirai()], the console's Stop button or [daemons()]`(0)`
#' returns an 'errorValue' 20; a worker that fails outright, 19.
#' `is_mirai_interrupt()` is provided for compatibility and is always `FALSE` here.
#'
#' @param x Any object.
#' @return Logical.
#' @export
is_mirai_error <- function(x) inherits(x, "miraiError")

#' @rdname is_mirai_error
#' @export
is_mirai_interrupt <- function(x) inherits(x, "miraiInterrupt")

#' @rdname is_mirai_error
#' @export
is_error_value <- function(x) inherits(x, "errorValue")

#' @export
print.miraiError <- function(x, ...) {
  cat("'miraiError' chr ", sub("\n$", "", unclass(x)[1]), "\n", sep = "")
  invisible(x)
}

#' @export
print.errorValue <- function(x, ...) {
  cat("'errorValue' int ", unclass(x)[1], " | ", attr(x, "message"), "\n", sep = "")
  invisible(x)
}

#' @export
print.unresolvedValue <- function(x, ...) {
  cat("'unresolved' logi NA\n")
  invisible(x)
}

format_error <- function(v) {
  if (inherits(v, "miraiError")) return(sub("\n$", "", unclass(v)[1]))
  if (inherits(v, "miraiInterrupt")) return("interrupted")
  paste0("errorValue ", unclass(v)[1], " (", attr(v, "message"), ")")
}
