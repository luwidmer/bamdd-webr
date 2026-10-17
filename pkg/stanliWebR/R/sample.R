# Sample a Stan program with stanli and hand back an rstan stanfit, so that the
# calling package's own code -- summaries, extraction, diagnostics -- runs on it
# unchanged.
#
# `init` is either a non-negative radius for uniform starting values on the
# unconstrained scale, which is what rstan's "random" (2) and "0" (0) mean, or a
# function of the stanli model returning a chains x n_unconstrained matrix.
#
# With `cores` > 1, more than one chain and webR workers running (miraiWebR's
# daemons()), each chain is sampled on a worker of its own. Chain 1 then matches
# the sequential run exactly; the others draw from different, equally valid
# streams, so a parallel fit is reproducible but not identical to a sequential one.
#
# `pars` and `include` select the parameters kept, as rstan's do; lp__ is always
# kept. `metric`, `step_size` and `adapt_engaged` go to stanli only when given.
sample_stanfit <- function(code, data, chains, warmup, samples, thin, seed, init,
                           delta, max_depth, refresh, threads = 1L,
                           save_warmup = FALSE, cores = 1L, pars = NULL,
                           include = TRUE, metric = NULL, step_size = NULL,
                           adapt_engaged = NULL) {
  # stanli draws from R's generator as well as from its own seed, so a run is only
  # reproducible with both set. rstan leaves the caller's random stream alone, and
  # so does this: the generator's state is put back afterwards.
  env <- globalenv()
  old_seed <- env$.Random.seed
  on.exit(if (is.null(old_seed)) rm(".Random.seed", envir = env) else env$.Random.seed <- old_seed)
  set.seed(seed)
  json <- stan_json(data)
  fast_math <- fast_math_option()
  model <- stanli::stanli_model(code = code, data = json, seed = seed, fast_math = fast_math)
  init <- if (is.function(init)) init(model) else init
  exclude <- excluded_pars(model, pars, include)
  controls <- Filter(Negate(is.null), list(
    metric = metric, step_size = step_size, adapt_engaged = adapt_engaged
  ))
  if (use_workers(chains, cores)) {
    return(record_controls(sample_on_workers(
      model, code = code, json = json, chains = chains, seed = seed, init = init,
      warmup = warmup, samples = samples, thin = thin, delta = delta,
      max_depth = max_depth, threads = threads, save_warmup = save_warmup,
      exclude = exclude, fast_math = fast_math, controls = controls
    ), controls))
  }
  args <- c(list(
    model,
    chains = chains, seed = seed, warmup = warmup, samples = samples, thin = thin,
    delta = delta, max_depth = max_depth, refresh = refresh,
    threads_per_chain = threads, save_warmup = save_warmup
  ), controls)
  if (is.matrix(init)) {
    args$init <- init
  } else {
    args$init_radius <- init
  }
  fit <- stanli::as_stanfit(do.call(stanli::sample_model, args), exclude = exclude)
  record_controls(fit, controls)
}

# stanli 0.21.0's as_stanfit() records only adapt_delta and max_treedepth, and
# names the sampler NUTS(diag_e) whatever the metric; record them as rstan does.
record_controls <- function(fit, controls) {
  if (!length(controls)) {
    return(fit)
  }
  extra <- Filter(Negate(is.null), list(
    stepsize = controls$step_size, adapt_engaged = controls$adapt_engaged
  ))
  sampler_t <- paste0("NUTS(", controls$metric %||% "diag_e", ")")
  update <- function(a) {
    a$control <- utils::modifyList(a$control %||% list(), extra)
    a$sampler_t <- sampler_t
    a
  }
  fit@stan_args <- lapply(fit@stan_args, update)
  fit@sim$samples <- lapply(fit@sim$samples, function(chain) {
    attr(chain, "args") <- update(attr(chain, "args"))
    chain
  })
  fit
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
# are identical across chains; chain k samples with its own seed.
sample_on_workers <- function(model, code, json, chains, seed, init, warmup, samples,
                              thin, delta, max_depth, threads, save_warmup, exclude,
                              fast_math, controls) {
  # Chain 1 keeps the run's seed, so it is the sequential run's first chain.
  seeds <- c(seed, sample.int(.Machine$integer.max, chains - 1L))
  workers <- miraiWebR::status()$connections
  message("Sampling ", chains, " chains on ", min(chains, workers), " webR workers")
  ms <- lapply(seq_len(chains), function(k) {
    miraiWebR::mirai(do.call(f, a), .args = list(f = sample_chain, a = list(
      code = code, json = json, seed = seed, chain_seed = seeds[k],
      init = if (is.matrix(init)) init[k, , drop = FALSE] else init,
      warmup = warmup, samples = samples, thin = thin, delta = delta,
      max_depth = max_depth, threads = threads, save_warmup = save_warmup,
      fast_math = fast_math, controls = controls, rng_kind = RNGkind()
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
  stanli::as_stanfit(bind_chains(fits, model, seed), exclude = exclude)
}

# Runs on a worker. R's generator is seeded as sample_stanfit() seeds it, with the
# console's generator kind rather than the L'Ecuyer streams a worker task starts on.
sample_chain <- function(code, json, seed, chain_seed, init, warmup, samples, thin,
                         delta, max_depth, threads, save_warmup, fast_math, controls,
                         rng_kind) {
  set.seed(seed, kind = rng_kind[1], normal.kind = rng_kind[2], sample.kind = rng_kind[3])
  model <- stanli::stanli_model(code = code, data = json, seed = seed, fast_math = fast_math)
  args <- c(list(
    model,
    chains = 1L, seed = chain_seed, warmup = warmup, samples = samples, thin = thin,
    delta = delta, max_depth = max_depth, refresh = 0L,
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
bind_chains <- function(fits, model, seed) {
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
  fit <- fits[[1]]
  fit$draws <- bind("draws")
  fit$sampler <- bind("sampler")
  fit$unconstrained <- bind("unconstrained")
  fit$report <- list(
    available = all(vapply(fits, function(f) isTRUE(f$report$available), logical(1))),
    warmup_seconds = unlist(lapply(fits, function(f) f$report$warmup_seconds)),
    sampling_seconds = unlist(lapply(fits, function(f) f$report$sampling_seconds)),
    n_divergent = unlist(lapply(fits, function(f) f$report$n_divergent)),
    n_max_treedepth = unlist(lapply(fits, function(f) f$report$n_max_treedepth))
  )
  # Adapted per chain: one step size and one inverse metric each.
  fit$step_size <- vapply(fits, function(f) f$step_size, numeric(1))
  fit$inv_metric <- lapply(fits, function(f) f$inv_metric[[1]])
  fit$chains <- as.integer(chains)
  fit$seed <- seed
  fit$model <- model
  fit
}
