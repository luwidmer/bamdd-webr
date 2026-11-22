# A stand-in for rstan::sampling() on a precompiled rstantools model: the model's
# Stan code is run on stanli instead of its compiled C++.
#
# rstan's arguments are honoured where stanli has an equivalent. `cores` spreads
# the chains over webR workers when miraiWebR has started some; `open_progress`
# has nothing to act on.
stanli_sampling <- function(object, data = list(), pars = NA, chains = 4L, iter = 2000L,
                            warmup = floor(iter / 2), thin = 1L,
                            seed = sample.int(.Machine$integer.max, 1L), init = "random",
                            check_data = TRUE, sample_file = NULL, diagnostic_file = NULL,
                            verbose = FALSE, algorithm = "NUTS", control = NULL,
                            include = TRUE, cores = getOption("mc.cores", 1L),
                            open_progress = FALSE, check_unknown_args = TRUE,
                            show_messages = TRUE, save_warmup = TRUE,
                            refresh = max(iter %/% 10, 1), ...) {
  if (!identical(algorithm, "NUTS")) {
    stop("stanli only samples with NUTS; algorithm = \"", algorithm, "\" is not supported",
         call. = FALSE)
  }
  # rstan::stan() passes NA for "no file".
  no_file <- function(x) is.null(x) || identical(x, NA)
  if (!no_file(sample_file) || !no_file(diagnostic_file)) {
    stop("sample_file and diagnostic_file are not supported by stanli", call. = FALSE)
  }
  # Unknown arguments are refused whatever check_unknown_args says.
  if (length(list(...))) {
    stop("rstan::sampling() argument(s) not supported by stanli: ",
         paste(names(list(...)), collapse = ", "), call. = FALSE)
  }
  unsupported <- setdiff(names(control), rstan_controls)
  if (length(unsupported)) {
    stop("control entries not supported by stanli: ", paste(unsupported, collapse = ", "),
         call. = FALSE)
  }
  fit <- sample_stanfit(
    code = object@model_code, data = data, chains = chains, warmup = warmup,
    samples = iter - warmup, thin = thin, seed = seed, init = rstan_init(init, chains),
    delta = control$adapt_delta %||% 0.8, max_depth = control$max_treedepth %||% 10,
    refresh = if (isTRUE(show_messages)) refresh else 0, save_warmup = save_warmup,
    cores = cores, pars = if (identical(pars, NA)) NULL else pars, include = include,
    metric = control$metric, step_size = control$stepsize,
    adapt_engaged = control$adapt_engaged
  )
  fit@model_name <- object@model_name
  fit
}

# Return `fun` with its one use of `from` -- called, or taken as a value, as brms's
# `fit_fun <- stanli::sample_model` does -- replaced by `to`. A function that already
# uses `to` is returned as it is, so patching twice is harmless.
swap_call <- function(fun, from, to) {
  if (!is.function(fun)) {
    stop("function to patch not found; stanliWebR needs updating", call. = FALSE)
  }
  found <- 0L
  done <- 0L
  walk <- function(e) {
    if (identical(e, from)) {
      found <<- found + 1L
      return(to)
    }
    if (identical(e, to)) {
      done <<- done + 1L
    }
    if (!is.call(e)) {
      return(e)
    }
    if (identical(e[[1]], from)) {
      found <<- found + 1L
      e[[1]] <- to
    } else if (identical(e[[1]], to)) {
      done <<- done + 1L
    }
    for (i in seq_along(e)[-1]) {
      if (!is.null(e[[i]]) && !identical(e[[i]], quote(expr = ))) e[[i]] <- walk(e[[i]])
    }
    e
  }
  new_body <- walk(body(fun))
  if (found == 0L && done == 1L) {
    return(fun)
  }
  if (found != 1L) {
    stop("expected one call to ", deparse(from), ", found ", found,
         "; stanliWebR needs updating", call. = FALSE)
  }
  body(fun) <- new_body
  fun
}
