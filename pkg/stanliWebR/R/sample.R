# Sample a Stan program with stanli and hand back an rstan stanfit, so that the
# calling package's own code -- summaries, extraction, diagnostics -- runs on it
# unchanged.
#
# `init` is either a non-negative radius for uniform starting values on the
# unconstrained scale, which is what rstan's "random" (2) and "0" (0) mean, or a
# function of the stanli model returning a chains x n_unconstrained matrix.
#
# With `cores` > 1, more than one chain and webR workers running (miraiWebR's
# daemons()), each chain is sampled on a worker of its own. Chain k uses stanli's
# stream for (seed, chain k), so a parallel fit is identical to a sequential one.
#
# `pars` and `include` select the parameters kept, as rstan's do; lp__ is always
# kept. `metric`, `step_size` and `adapt_engaged` go to stanli only when given.
# `show_messages = FALSE` drops the sampler's notices, which stanli prints whatever
# `refresh` is.
# `plain = TRUE` returns an object of class exactly "stanfit", without the model.
#
# Neither stanli nor this function draws from R's random stream.
sample_stanfit <- function(code, data, chains, warmup, samples, thin, seed, init,
                           delta, max_depth, refresh, threads = 1L,
                           save_warmup = FALSE, cores = 1L, pars = NULL,
                           include = TRUE, metric = NULL, step_size = NULL,
                           adapt_engaged = NULL, plain = FALSE, show_messages = TRUE) {
  model <- webr_stanli_model(code = code, data = stan_data(data), seed = seed,
                             threads_per_chain = threads)
  init <- if (is.function(init)) init(model, seed) else init
  args <- c(list(
    model,
    chains = chains, seed = seed, warmup = warmup, samples = samples, thin = thin,
    delta = delta, max_depth = max_depth, refresh = refresh, save_warmup = save_warmup,
    parallel_chains = min(cores %||% 1L, chains), show_messages = show_messages
  ), Filter(Negate(is.null), list(
    metric = metric, step_size = step_size, adapt_engaged = adapt_engaged
  )))
  if (is.matrix(init)) {
    args$init <- init
  } else {
    args$init_radius <- init
  }
  stanli::as_stanfit(do.call(webr_sample_model, args),
                     exclude = excluded_pars(model, pars, include), plain = plain)
}

# rstan reads any list in the data as an array of its elements, while stanli
# writes a list with names as a JSON object; rbmi names its per-group covariance
# priors by group. Drop those names, at every depth.
stan_data <- function(data) {
  unname_lists <- function(x) {
    if (!is.list(x) || is.data.frame(x)) return(x)
    lapply(unname(x), unname_lists)
  }
  if (!is.list(data)) return(data)
  data[] <- lapply(data, unname_lists)
  data
}

# stanli::stanli_model(), in fast mode under options(stanliWebR.fast_math = TRUE).
webr_stanli_model <- function(...) {
  stanli::stanli_model(..., fast_math = fast_math_option())
}

# The stanli::sample_model() arguments a run on workers honours.
worker_sample_args <- c(
  "chains", "seed", "warmup", "samples", "thin", "delta", "max_depth", "save_warmup",
  "init", "init_radius", "parallel_chains", "refresh", "threads_per_chain",
  "fixed_param", "metric", "step_size", "adapt_engaged", "show_messages"
)

# stanli::sample_model(), with the chains on webR workers when more than one is to run
# at once and workers are running. Defaults are stanli's.
webr_sample_model <- function(model, ...) {
  args <- list(...)
  chains <- args$chains %||% 4
  if (isTRUE(args$fixed_param) || !use_workers(chains, args$parallel_chains %||% chains)) {
    return(stanli::sample_model(model, ...))
  }
  unsupported <- setdiff(names(args), worker_sample_args)
  if (length(unsupported)) {
    stop("Not supported when chains run on webR workers: ",
         paste(unsupported, collapse = ", "), call. = FALSE)
  }
  sample_on_workers(
    model, chains = chains, seed = args$seed %||% 1,
    init = args$init %||% args$init_radius %||% 2,
    warmup = args$warmup %||% 1000, samples = args$samples %||% 1000,
    thin = args$thin %||% 1, delta = args$delta %||% 0.8,
    max_depth = args$max_depth %||% 10, save_warmup = isTRUE(args$save_warmup),
    controls = Filter(Negate(is.null),
                      args[c("metric", "step_size", "adapt_engaged", "show_messages")])
  )
}

# options(stanliWebR.fast_math = TRUE): see ?stanliWebR.
fast_math_option <- function() {
  value <- getOption("stanliWebR.fast_math", FALSE)
  if (!is.logical(value) || length(value) != 1L || is.na(value)) {
    stop("options(stanliWebR.fast_math =) must be TRUE or FALSE", call. = FALSE)
  }
  value
}

# The entries of rstan's `control` that stanli honours; callers refuse the rest.
rstan_controls <- c("adapt_delta", "max_treedepth", "stepsize", "metric", "adapt_engaged")

# The model's variables that `pars` and `include` leave out. Like rstan, accept
# `pars` as a list: brms passes its exclusions as one.
excluded_pars <- function(model, pars, include) {
  if (is.null(pars)) {
    return(NULL)
  }
  pars <- unlist(pars)
  vars <- unique(sub("\\[.*", "", model$columns))
  if (include) setdiff(vars, pars) else intersect(vars, pars)
}

# Whether to spread the chains over webR workers. Asking for cores without any
# running is said out loud, since the run will take as long as `cores = 1`.
use_workers <- function(chains, cores) {
  cores <- as.integer(cores %||% 1L)
  if (chains < 2L || cores < 2L) {
    return(FALSE)
  }
  # A chain already on a worker: workers do not start workers.
  if (nzchar(Sys.getenv("MIRAI_WEBR_WORKER"))) {
    return(FALSE)
  }
  if (isNamespaceLoaded("miraiWebR") && miraiWebR::status()$connections > 0L) {
    return(TRUE)
  }
  message("cores = ", cores, " asked for, but no webR workers are running, so the ",
          chains, " chains run one after another. Start workers with ",
          "miraiWebR::daemons(n) to sample chains in parallel.")
  FALSE
}

# One single-chain run per worker, put back together as if sampled at once. Each
# worker builds the model from the same code, data and seed, so transformed data
# are identical across chains; chain k samples with chain_id = k.
sample_on_workers <- function(model, chains, seed, init, warmup, samples, thin, delta,
                              max_depth, save_warmup, controls) {
  workers <- miraiWebR::status()$connections
  message("Sampling ", chains, " chains on ", min(chains, workers), " webR workers")
  ms <- lapply(seq_len(chains), function(k) {
    miraiWebR::mirai(do.call(f, a), .args = list(f = sample_chain, a = list(
      code = model$model_code, data = model$source$data_json, seed = seed, chain_id = k,
      init = if (is.matrix(init)) init[k, , drop = FALSE] else init,
      warmup = warmup, samples = samples, thin = thin, delta = delta,
      max_depth = max_depth, threads = model$threads_per_chain, save_warmup = save_warmup,
      fast_math = model$fast_math, controls = controls
    )))
  })
  # On any failure, or Stop, the other chains must not keep running.
  on.exit(miraiWebR::stop_mirai(ms), add = TRUE)
  fits <- vector("list", chains)
  for (k in seq_len(chains)) {
    fit <- miraiWebR::collect_mirai(ms[[k]])
    if (miraiWebR::is_error_value(fit)) {
      reason <- if (miraiWebR::is_mirai_error(fit)) sub("\n$", "", unclass(fit)[1]) else attr(fit, "message")
      stop("chain ", k, " failed on its webR worker: ", reason, call. = FALSE)
    }
    fits[[k]] <- fit
  }
  bind_chains(fits, model)
}

# Runs on a worker.
sample_chain <- function(code, data, seed, chain_id, init, warmup, samples, thin,
                         delta, max_depth, threads, save_warmup, fast_math, controls) {
  model <- stanli::stanli_model(code = code, data = data, seed = seed, fast_math = fast_math)
  args <- c(list(
    model,
    chains = 1L, seed = seed, chain_id = chain_id, warmup = warmup, samples = samples,
    thin = thin, delta = delta, max_depth = max_depth, refresh = 0L,
    threads_per_chain = threads, save_warmup = save_warmup
  ), controls)
  if (is.matrix(init)) {
    args$init <- init
  } else {
    args$init_radius <- init
  }
  fit <- do.call(stanli::sample_model, args)
  # The compiled model lives in this worker; the console has its own.
  fit$model <- NULL
  fit
}

# Single-chain stanli fits as one multi-chain fit, chains in order.
bind_chains <- function(fits, model) {
  chains <- length(fits)
  bind <- function(name) {
    first <- fits[[1]][[name]]
    d <- dim(first)
    out <- array(NA_real_, dim = c(d[1], chains, d[3]), dimnames = dimnames(first))
    for (k in seq_len(chains)) {
      x <- fits[[k]][[name]]
      if (!identical(dim(x), d)) stop("chains returned draws of different shapes", call. = FALSE)
      out[, k, ] <- x[, 1, ]
    }
    out
  }
  per_chain <- function(field) unlist(lapply(fits, function(f) f$report[[field]]))
  fit <- fits[[1]]
  fit$draws <- bind("draws")
  fit$sampler <- bind("sampler")
  fit$unconstrained <- bind("unconstrained")
  fit$report <- list(
    warmup_seconds = per_chain("warmup_seconds"),
    sampling_seconds = per_chain("sampling_seconds"),
    n_divergent = per_chain("n_divergent"),
    n_max_treedepth = per_chain("n_max_treedepth")
  )
  # Adapted per chain: one step size and one inverse metric each.
  fit$step_size <- vapply(fits, function(f) f$step_size, numeric(1))
  fit$inv_metric <- lapply(fits, function(f) f$inv_metric[[1]])
  fit$chains <- as.integer(chains)
  fit$chain_id <- 1L
  fit$model <- model
  fit
}
