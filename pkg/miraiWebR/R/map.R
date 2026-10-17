#' Map a function over a list on webR workers
#'
#' One [mirai()] per element of `.x`, spread over the workers. For a data frame or
#' matrix `.x`, one per row, with the columns as the arguments of `.f`. Collect the
#' results with `x[]`, or `x[.flat]` for a vector, `x[.progress]` to show a
#' progress bar while waiting, and `x[.stop]` to stop at the first error,
#' cancelling the rest. Options combine: `x[.stop, .progress]`.
#'
#' @param .x A list or vector, or a data frame or matrix.
#' @param .f A function.
#' @param ... Named objects `.f` needs, as for [mirai()].
#' @param .args A named list of further arguments to `.f`, the same for every
#'   element.
#' @param .promise,.compute Not supported; must be `NULL`.
#' @return A 'mirai_map'.
#' @export
#' @examples
#' \dontrun{
#' daemons(2)
#' mirai_map(1:4, function(n) mean(rnorm(n * 1e5)))[.flat]
#' }
mirai_map <- function(.x, .f, ..., .args = list(), .promise = NULL, .compute = NULL) {
  if (!is.null(.promise)) stop(".promise is not supported by miraiWebR", call. = FALSE)
  if (!is.null(.compute)) stop("compute profiles are not supported by miraiWebR", call. = FALSE)
  .f <- match.fun(.f)
  globals <- named_objects(list(...), "...")
  .args <- named_objects(.args, ".args")
  calls <- if (is.data.frame(.x) || is.matrix(.x)) {
    rows <- seq_len(nrow(.x))
    names(rows) <- rownames(.x)
    lapply(rows, function(i) {
      row <- if (is.data.frame(.x)) as.list(.x[i, , drop = FALSE]) else as.list(.x[i, ])
      if (is.matrix(.x) && is.null(colnames(.x))) names(row) <- NULL
      c(row, .args)
    })
  } else {
    lapply(.x, function(el) c(list(el), .args))
  }
  ms <- lapply(calls, function(a) {
    submit(task(quote(do.call(.f, .a)), globals = globals,
                args = list(.f = .f, .a = a)))
  })
  if (!is.data.frame(.x) && !is.matrix(.x)) names(ms) <- names(.x)
  structure(ms, class = "mirai_map")
}

#' @rdname mirai_map
#' @format NULL
#' @export
.flat <- structure("flat", class = "miraiMapOption")

#' @rdname mirai_map
#' @format NULL
#' @export
.progress <- structure("progress", class = "miraiMapOption")

#' @rdname mirai_map
#' @format NULL
#' @export
.stop <- structure("stop", class = "miraiMapOption")

#' @export
`[.mirai_map` <- function(x, ...) {
  options <- if (...length() == 0L || missing(..1)) character() else {
    opts <- list(...)
    for (o in opts) {
      if (!inherits(o, "miraiMapOption")) {
        stop("a mirai_map is collected with x[], or x[.flat], x[.progress], x[.stop]",
             call. = FALSE)
      }
    }
    vapply(opts, unclass, character(1))
  }
  collect_list(x, options)
}

collect_list <- function(x, options = NULL) {
  options <- sub("^\\.", "", as.character(options))
  unknown <- setdiff(options, c("flat", "progress", "stop"))
  if (length(unknown)) {
    stop("unsupported collect option(s): ", paste(unknown, collapse = ", "), call. = FALSE)
  }
  x <- unclass(x)
  bar <- if ("progress" %in% options && length(x)) {
    utils::txtProgressBar(max = length(x), style = 3)
  }
  values <- vector("list", length(x))
  for (i in seq_along(x)) {
    m <- x[[i]]
    v <- if (inherits(m, "mirai")) poll(m, wait = TRUE)$.value else m
    if (!is.null(v)) values[[i]] <- v
    if (!is.null(bar)) utils::setTxtProgressBar(bar, i)
    if ("stop" %in% options && is_error_value(v)) {
      if (!is.null(bar)) close(bar)
      stop_mirai(Filter(function(m) inherits(m, "mirai"), x[-seq_len(i)]))
      stop("task ", i, " of ", length(x), " failed: ", format_error(v), call. = FALSE)
    }
  }
  if (!is.null(bar)) close(bar)
  names(values) <- names(x)
  if ("flat" %in% options) {
    errors <- Filter(is_error_value, values)
    if (length(errors)) stop("cannot flatten: ", format_error(errors[[1]]), call. = FALSE)
    lengths <- lengths(values)
    if (any(lengths != 1L) || !all(vapply(values, is.atomic, logical(1)))) {
      stop("cannot flatten: every value must be a single atomic value", call. = FALSE)
    }
    values <- unlist(values, recursive = FALSE)
  }
  values
}

#' @export
print.mirai_map <- function(x, ...) {
  done <- sum(!vapply(unclass(x), function(m) inherits(m, "mirai") && !m$.done, logical(1)))
  cat("< mirai map [", done, "/", length(x), "] >\n", sep = "")
  invisible(x)
}
