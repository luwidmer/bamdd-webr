#' Make brms sample through stanli
#'
#' Runs brms's default `"rstan"` backend on stanli: the Stan program brms generates
#' is interpreted rather than compiled, and the result is an ordinary rstan
#' `stanfit`. Loading stanliWebR arranges for this to happen whenever brms is
#' loaded, so calling it by hand is only needed when brms was loaded before
#' stanliWebR was installed.
#'
#' @details
#' Two brms internals are replaced: `.compile_model_rstan`, which only checks and
#' keeps the Stan code, since stanli builds a model when the data are known; and
#' `.fit_model_rstan`, which samples with stanli. Nothing else in brms is touched,
#' so the fitted object, and everything downstream of it, is brms's own. Parameters
#' brms excludes from the output (the standardised group-level effects `z_*`, for
#' instance) are dropped as rstan would drop them, and post-processing such as
#' [brms::posterior_predict()] needs no `save_pars()`. The fit keeps stanli's
#' model, so [brms::loo_moment_match()] and [brms::bridge_sampler()] evaluate the
#' log density without recompiling (both need `save_pars(all = TRUE)`, as with
#' rstan).
#'
#' The NUTS sampler is the only algorithm. Supported `control` entries are
#' `adapt_delta`, `max_treedepth`, `stepsize`, `metric` (`"diag_e"`, `"dense_e"`
#' or `"unit_e"`) and `adapt_engaged`; `init` may be `"random"`, `"0"`, a
#' non-negative radius, or a list of starting values, applied as rstan applies
#' them. Anything else stops with an error rather than being ignored.
#'
#' With `cores` > 1 and webR workers started by `miraiWebR::daemons()`, each
#' chain is sampled on a worker of its own, with the same random stream it has in
#' a sequential run, so the fit is identical to the sequential one. Without
#' workers the chains run one after another, and a message says so.
#'
#' @return `TRUE`, invisibly.
#' @export
#' @examples
#' \dontrun{
#' library(stanliWebR)
#' fit <- brms::brm(time ~ age * sex, data = brms::kidney, seed = 1)
#' }
use_stanli_for_brms <- function() {
  require_namespaces("brms", c("brms", "rstan", "stanli"))
  patch_namespace("brms", list(
    .compile_model_rstan = stanli_compile_model,
    .fit_model_rstan = stanli_fit_model
  ))
}

# stanli binds the data when it builds a model, so all that can be done ahead of
# sampling is to check the code and keep it.
stanli_compile_model <- function(model, threads, opencl, silent = 1, ...) {
  stanli::stanli_check_syntax(model)
  structure(list(model_code = model), class = "stanli_program")
}

# As brms's own .fit_model_rstan(), with rstan::sampling() replaced by stanli.
stanli_fit_model <- function(model, sdata, algorithm, iter, warmup, thin, chains,
                             cores, threads, opencl, init, exclude, seed, control,
                             silent, future, ...) {
  if (!identical(algorithm, "sampling")) {
    stop2("stanli only samples with NUTS; algorithm = '", algorithm, "' is not supported.")
  }
  if (isTRUE(future)) {
    stop2("future = TRUE is not supported by stanli.")
  }
  if (use_opencl(opencl)) {
    stop2("OpenCL is not supported by stanli.")
  }
  dots <- list(...)
  unsupported <- setdiff(names(dots), "refresh")
  if (length(unsupported)) {
    stop2("Sampler argument(s) not supported by stanli: ", collapse_comma(unsupported))
  }
  unsupported <- setdiff(names(control), rstan_controls)
  if (length(unsupported)) {
    stop2("control entries not supported by stanli: ", collapse_comma(unsupported))
  }
  threads <- if (use_threading(threads, force = TRUE)) threads$threads else 1L
  if (threads > 1L && !stanli::stanli_thread_safe()) {
    stop2("threading() needs threads, which this stanli runtime does not have. ",
          "Start webR workers with miraiWebR::daemons() and use 'cores' to run ",
          "chains in parallel instead.")
  }
  # update() passes the fitted model back in instead of a fresh compile.
  code <- if (inherits(model, "stanli_program")) model$model_code else model@model_code
  if (is.na(seed)) {
    seed <- sample.int(.Machine$integer.max, 1L)
  }
  if (chains == 0) {
    # rstan returns a fit without draws that still carries the model, and brms
    # asks for one that way to refresh a fit's model before loo_moment_match()
    # or bridge_sampler(). stanli's public API builds that fit from a single
    # draw, which is then dropped.
    out <- sample_stanfit(
      code = code, data = unclass(sdata), chains = 1L, warmup = 0L, samples = 1L,
      thin = 1L, seed = seed, init = 2, delta = 0.8, max_depth = 10, refresh = 0
    )
    out@sim <- list()
    out@mode <- 2L
    return(out)
  }
  init <- rstan_init(init, chains)
  if (silent < 2) {
    message("Start sampling")
  }
  out <- sample_stanfit(
    code = code, data = unclass(sdata), chains = chains, warmup = warmup,
    samples = iter - warmup, thin = thin, seed = seed, init = init,
    delta = control$adapt_delta %||% 0.8, max_depth = control$max_treedepth %||% 10,
    # rstan's default: progress every tenth of the run, unless brms is silenced.
    refresh = dots$refresh %||% if (silent >= 2) 0 else max(iter %/% 10, 1),
    threads = threads,
    cores = cores, pars = exclude, include = FALSE,
    metric = control$metric, step_size = control$stepsize,
    adapt_engaged = control$adapt_engaged
  )
  repair_stanfit(out)
}
