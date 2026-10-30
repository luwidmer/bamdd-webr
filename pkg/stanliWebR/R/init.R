# rstan's `init` argument, translated for sample_stanfit().
#
# "random" and "0" become a radius for uniform starting values on the unconstrained
# scale, as does a non-negative number. A named list of starting values -- or one
# per chain -- is applied as rstan applies it: names that are parameters of the
# model take the values given, names that are not are ignored, and parameters
# without a value start uniform on (-2, 2) on the unconstrained scale.
rstan_init <- function(init, chains) {
  if (is.null(init)) {
    return(2)
  }
  if (is.character(init) && length(init) == 1L && init %in% c("random", "0")) {
    return(if (init == "random") 2 else 0)
  }
  if (is.numeric(init) && length(init) == 1L && !is.na(init) && init >= 0) {
    return(init)
  }
  if (!is.list(init)) {
    stop("stanli supports init = \"random\", \"0\", a non-negative radius, or a ",
         "list of starting values", call. = FALSE)
  }
  per_chain <- if (is.null(names(init))) init else list(init)
  if (length(per_chain) == 1L) {
    per_chain <- rep(per_chain, chains)
  }
  if (length(per_chain) != chains) {
    stop("init has ", length(per_chain), " sets of starting values for ", chains,
         " chains", call. = FALSE)
  }
  function(model, seed) {
    n <- model$n_unconstrained
    t(vapply(seq_along(per_chain), function(k) {
      unconstrained_init(model, per_chain[[k]], seed = seed, chain = k)
    }, numeric(n)))
  }
}

# As Stan's own initialisation: up to 100 attempts, each drawing the unspecified
# parameters afresh, until the log density and its gradient are finite. The last
# failure is reported if none succeeds. The draws come from the run's seed, not
# from R's random stream, as stanli's own rstan sampling() makes them.
unconstrained_init <- function(model, values, seed, chain, tries = 100L) {
  # With every parameter given there is nothing to draw afresh.
  if (all(stanli::parameter_names(model) %in% names(values))) {
    tries <- 1L
  }
  failure <- NULL
  for (attempt in seq_len(tries)) {
    draw_seed <- as.integer((seed + 1000003 * (chain - 1) + attempt - 1) %% .Machine$integer.max)
    u <- tryCatch(
      stanli::unconstrain(model, values, partial = TRUE, seed = draw_seed, ignore_unknown = TRUE),
      error = function(e) e
    )
    if (inherits(u, "error")) {
      failure <- conditionMessage(u)
      next
    }
    lp <- stanli::log_prob_grad(model, u)
    if (is.finite(lp$lp) && all(is.finite(lp$grad))) {
      return(u)
    }
    failure <- "the log density or its gradient is not finite"
  }
  stop("No usable starting values in ", tries, " attempt(s): ", failure, call. = FALSE)
}
