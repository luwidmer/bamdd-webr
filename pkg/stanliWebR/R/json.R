# Stan's JSON data format. stanli ships a writer of its own, but as of stanli
# 0.21.0 it still stops at two-dimensional arrays and writes an unnamed list as an
# object with empty keys, and rbmi passes its covariance priors as lists of
# matrices.
#
# Numbers are written with 17 significant digits, which round-trips every double
# exactly, so a model sees bit-for-bit the data R holds. Arrays are nested with the
# first index outermost, as Stan reads them; R stores them the other way round.
stan_json <- function(data) {
  if (is.list(data) && length(data) == 0L) {
    return("{}")
  }
  if (!is.list(data) || is.null(names(data)) || !all(nzchar(names(data)))) {
    stop("Stan data must be a fully named list", call. = FALSE)
  }
  fields <- vapply(names(data), function(name) {
    paste0("\"", name, "\":", json_value(data[[name]], name))
  }, character(1), USE.NAMES = FALSE)
  paste0("{", paste(fields, collapse = ","), "}")
}

json_value <- function(x, name) {
  # A list is an array of its elements, as rstan reads it; rbmi passes its
  # per-group covariance priors that way.
  if (is.list(x) && !is.data.frame(x)) {
    parts <- vapply(x, json_value, character(1), name = name, USE.NAMES = FALSE)
    return(paste0("[", paste(parts, collapse = ","), "]"))
  }
  if (!(is.numeric(x) || is.logical(x)) || is.factor(x)) {
    stop("Stan data `", name, "` must be numeric or logical, not ", class(x)[1],
         call. = FALSE)
  }
  values <- json_numbers(x, name)
  d <- dim(x)
  if (is.null(d)) {
    # Stan reads a bare number for a one-element vector as well as for a scalar.
    if (length(values) == 1L) return(values)
    return(paste0("[", paste(values, collapse = ","), "]"))
  }
  values <- values[as.vector(aperm(array(seq_along(values), d), rev(seq_along(d))))]
  for (k in rev(seq_along(d))) {
    outer <- prod(d[seq_len(k - 1L)])
    values <- if (d[k] == 0L) {
      rep("[]", outer)
    } else {
      vapply(
        split(values, rep(seq_len(outer), each = d[k])),
        function(v) paste0("[", paste(v, collapse = ","), "]"),
        character(1), USE.NAMES = FALSE
      )
    }
  }
  values
}

json_numbers <- function(x, name) {
  if (is.logical(x)) x <- as.integer(x)
  if (is.integer(x)) {
    if (anyNA(x)) stop("Stan integer data `", name, "` contains NA", call. = FALSE)
    return(as.character(x))
  }
  out <- sprintf("%.17g", x)
  out[is.na(x)] <- "\"NaN\""
  out[x %in% Inf] <- "\"Infinity\""
  out[x %in% -Inf] <- "\"-Infinity\""
  out
}
