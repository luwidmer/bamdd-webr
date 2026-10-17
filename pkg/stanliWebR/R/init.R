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
  function(model) {
    n <- model$n_unconstrained
    t(vapply(per_chain, function(values) unconstrained_init(model, values), numeric(n)))
  }
}

# As Stan's own initialisation: up to 100 attempts, each drawing the unspecified
# parameters afresh, until the log density and its gradient are finite. The last
# failure is reported if none succeeds.
unconstrained_init <- function(model, values, tries = 100L) {
  # rstan ignores names that are not parameters, where stanli refuses them; and
  # stanli lists a model's parameters only through its internals.
  declared <- unique(sub("\\..*$", "", .Call("stanli_r_parameter_columns", model$ptr,
                                             PACKAGE = "stanli")))
  values <- lapply(values[intersect(names(values), declared)], stan_array)
  # With every parameter given there is nothing to draw afresh.
  if (all(declared %in% names(values))) {
    tries <- 1L
  }
  failure <- NULL
  for (attempt in seq_len(tries)) {
    u <- if (length(values)) {
      # Draws the parameters not given uniform on (-2, 2), unconstrained.
      tryCatch(stanli::unconstrain(model, values, partial = TRUE), error = function(e) e)
    } else {
      stats::runif(model$n_unconstrained, -2, 2)
    }
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

# stanli takes an array of vectors or matrices as one R array, outermost index
# first, where rstan also accepts a list of them.
stan_array <- function(value) {
  if (!is.list(value)) {
    return(value)
  }
  a <- simplify2array(lapply(value, stan_array), higher = TRUE)
  if (is.list(a)) {
    stop("starting values given as a list must all have the same shape", call. = FALSE)
  }
  d <- dim(a)
  if (is.null(d)) a else aperm(a, c(length(d), seq_len(length(d) - 1L)))
}
