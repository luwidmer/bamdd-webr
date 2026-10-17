#' A 'future' backend on webR workers
#'
#' `future::plan(miraiWebR::webr_workers)` sends futures to the webR workers of
#' [daemons()], so future.apply, furrr, doFuture and anything else built on
#' 'future' runs in parallel. If daemons are not set yet, the plan starts
#' `workers` of them (by default as many as the device allows) and stops them when
#' the plan is changed again; daemons that are already set are used as they are.
#' In the phone layout, where there are no workers, it falls back to
#' `future::sequential`.
#'
#' _This function must never be called. Use it only with [future::plan()]._
#'
#' @param ... Not used.
#' @param workers Number of workers to start when daemons are not set yet.
#' @param envir Not used.
#' @return Nothing.
#' @export
#' @examples
#' \dontrun{
#' future::plan(miraiWebR::webr_workers, workers = 2)
#' future.apply::future_sapply(1:4, function(i) Sys.getenv("MIRAI_WEBR_WORKER"))
#' future::plan(future::sequential)
#' }
webr_workers <- function(..., workers = NULL, envir = parent.frame()) {
  stop("miraiWebR::webr_workers() must never be called directly; ",
       "use future::plan(miraiWebR::webr_workers)", call. = FALSE)
}

WebrWorkersFutureBackend <- function(workers = NULL, ...) {
  if (!requireNamespace("future", quietly = TRUE)) {
    stop("the future package is not installed", call. = FALSE)
  }
  shutdown <- FALSE
  if (!daemons_set()) {
    if (is.null(workers)) workers <- max(1L, jsonlite::fromJSON(pool("limits"))$max)
    daemons(workers)
    shutdown <- TRUE
  } else if (!is.null(workers) && .state$mode == "workers" && workers != .state$n) {
    stop("daemons are already set with ", .state$n, " worker(s), not ", workers,
         "; call daemons(0) first or leave out `workers`", call. = FALSE)
  }
  if (.state$mode != "workers") {
    if (shutdown) daemons(0)
    return(future::SequentialFutureBackend(...))
  }
  core <- future::FutureBackend(..., reg = "workers-miraiWebR", workers = .state$n,
                                shutdown = shutdown)
  core[["futureClasses"]] <- c("WebrWorkersFuture", "MultiprocessFuture", core[["futureClasses"]])
  structure(core, class = c("WebrWorkersFutureBackend", "MultiprocessFutureBackend",
                            "FutureBackend", class(core)))
}

class(webr_workers) <- c("webr_workers", "multiprocess", "future", "function")
attr(webr_workers, "init") <- TRUE
attr(webr_workers, "factory") <- WebrWorkersFutureBackend

future_internal <- function(name) {
  get(name, envir = asNamespace("future"), mode = "function", inherits = FALSE)
}

registry <- function(backend, action, ...) {
  future_internal("FutureRegistry")(backend[["reg"]], action = action, ..., earlySignal = FALSE)
}

#' @exportS3Method future::launchFuture
launchFuture.WebrWorkersFutureBackend <- function(backend, future, ...) {
  # Wait for a free worker, by blocking on whichever running future finishes first.
  repeat {
    running <- registry(backend, "list")
    if (length(running) < backend[["workers"]]) break
    pending <- Filter(function(f) !f[["mirai"]]$.done, running)
    # A future whose value R already holds needs only collecting.
    if (length(pending) == length(running)) {
      ids <- vapply(pending, function(f) f[["mirai"]]$.id, integer(1))
      js(sprintf("globalThis.__webrPool.waitAny([%s])", paste(ids, collapse = ",")))
    }
    registry(backend, "collect-first")
  }
  future[["backend"]] <- backend
  future[["workers"]] <- backend[["workers"]]
  data <- future_internal("getFutureData")(future)
  future[["state"]] <- "submitted"
  expr <- quote(future:::evalFuture(data))
  future[["mirai"]] <- mirai(expr, data = data)
  future[["state"]] <- "running"
  registry(backend, "add", future = future)
  invisible(future)
}

#' @exportS3Method future::resolved
resolved.WebrWorkersFuture <- function(x, ...) {
  if (NextMethod()) return(TRUE)
  state <- x[["state"]]
  if (state %in% c("finished", "interrupted")) return(TRUE)
  if (state == "created") {
    future::run(x)
    return(FALSE)
  }
  !unresolved(x[["mirai"]])
}

#' @exportS3Method future::result
result.WebrWorkersFuture <- function(future, ...) {
  state <- future[["state"]]
  if (state == "finished") return(future[["result"]])
  if (state == "interrupted") stop(future[["result"]])
  value <- collect_mirai(future[["mirai"]])
  registry(future[["backend"]], "remove", future = future)
  if (is_error_value(value)) {
    if (inherits(value, "miraiError")) {
      stop(future::FutureError(paste0("a webR worker failed to evaluate the future: ",
                                      format_error(value)), future = future))
    }
    future[["state"]] <- "interrupted"
    err <- future::FutureInterruptError(
      paste0("the future was stopped on its webR worker: ", format_error(value)),
      future = future
    )
    future[["result"]] <- err
    stop(err)
  }
  future[["result"]] <- value
  future[["state"]] <- "finished"
  value
}

#' @exportS3Method future::nbrOfWorkers
nbrOfWorkers.WebrWorkersFutureBackend <- function(evaluator) {
  as.integer(evaluator[["workers"]])
}

#' @exportS3Method future::nbrOfFreeWorkers
nbrOfFreeWorkers.WebrWorkersFutureBackend <- function(evaluator, background = FALSE, ...) {
  as.integer(evaluator[["workers"]]) - length(registry(evaluator, "list"))
}

#' @exportS3Method future::interruptFuture
interruptFuture.WebrWorkersFutureBackend <- function(backend, future, ...) {
  stop_mirai(future[["mirai"]])
  future[["state"]] <- "interrupted"
  future
}

#' @exportS3Method future::stopWorkers
stopWorkers.WebrWorkersFutureBackend <- function(backend, ...) {
  for (f in registry(backend, "list")) stop_mirai(f[["mirai"]])
  registry(backend, "reset")
  if (isTRUE(backend[["shutdown"]]) && daemons_set()) daemons(0)
  backend
}
