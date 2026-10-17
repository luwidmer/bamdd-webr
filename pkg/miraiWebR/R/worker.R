# What a worker runs for each task (see js/workers.js): read the serialized task,
# evaluate it, write the serialized value. Every R condition is caught here, so the
# only failures the pool sees are of the worker itself.
worker_run <- function(input, output) {
  task <- unserialize(readBin(input, "raw", file.size(input)))
  unlink(input)
  value <- run_task(task, global = globalenv(), on_worker = TRUE)
  bytes <- tryCatch(
    serialize(value, NULL),
    error = function(e) serialize(mirai_error(e, list()), NULL)
  )
  writeBin(bytes, output)
  invisible()
}

# Evaluate a task as mirai does: `globals` in the global environment for the
# duration (for good with `persist`, as everywhere() wants), `args` in a local one,
# drawing random numbers from the task's own stream.
run_task <- function(task, global, on_worker = FALSE) {
  if (length(task$globals)) {
    list2env(task$globals, envir = global)
    if (!task$persist) on.exit(rm(list = names(task$globals), envir = global), add = TRUE)
  }
  env <- if (task$persist && !length(task$args)) global else list2env(task$args, parent = global)
  with_preserved_rng({
    RNGkind("L'Ecuyer-CMRG")
    assign(".Random.seed", task$stream, envir = globalenv())
    calls <- NULL
    run <- function() {
      withCallingHandlers(
        eval(task$expr, env),
        error = function(e) calls <<- sys.calls()
      )
    }
    failed <- function(e) mirai_error(e, calls)
    # On a worker the pool interrupts only to cancel the task; in the console an
    # interrupt is the user stopping everything, and must not be swallowed.
    if (on_worker) {
      tryCatch(run(), error = failed, interrupt = function(e) error_value(20L, "canceled"))
    } else {
      tryCatch(run(), error = failed)
    }
  })
}

mirai_error <- function(e, calls) {
  call <- conditionCall(e)
  # stop() at the top level of the task reports the eval() that ran it.
  if (identical(call, quote(eval(task$expr, env)))) call <- NULL
  msg <- if (is.null(call)) {
    paste0("Error: ", conditionMessage(e), "\n")
  } else {
    paste0("Error in ", paste(deparse(call, nlines = 1L), collapse = ""), ": ",
           conditionMessage(e), "\n")
  }
  # Keep only the task's own frames: drop run_task()'s, down to its eval(), and
  # R's error handling from stop() onwards.
  start <- Position(function(cl) identical(cl, quote(eval(task$expr, env))), calls, right = TRUE)
  if (!is.na(start)) calls <- calls[-seq_len(start)]
  handling <- Position(function(cl) identical(cl[[1]], quote(.handleSimpleError)), calls)
  calls <- if (is.na(handling)) utils::head(calls, -1L) else utils::head(calls, handling - 1L)
  trace <- lapply(calls, function(cl) paste(deparse(cl, nlines = 1L), collapse = ""))
  structure(msg, class = c("miraiError", "errorValue", "try-error"),
            condition.class = class(e), stack.trace = trace)
}
