#' Make rbmi's Bayesian imputation sample through stanli
#'
#' Replaces the two rbmi internals that compile and sample the MMRM Stan program,
#' so that [rbmi::method_bayes()] works where no C++ toolchain exists. Loading
#' stanliWebR arranges for this to happen whenever rbmi is loaded, so calling it
#' by hand is only needed when rbmi was loaded before stanliWebR was installed.
#'
#' @details
#' `get_stan_model` now only renders the Stan program, and `fit_mcmc` samples it
#' with stanli and returns an rstan `stanfit`. rbmi's own draw extraction,
#' effective-sample-size check and HMC diagnostics then run on that object
#' unchanged.
#'
#' rbmi's Stan program runs on stanli as it is. Starting values follow rstan: the
#' MMRM estimates rbmi supplies are used for every name that is a Stan parameter,
#' and the remaining parameters start uniform on (-2, 2) on the unconstrained scale.
#' As in rstan, list-valued starting values are ignored. rbmi 1.7.1 and earlier pass
#' the covariance estimates as per-group lists, so only `theta` starts from the MMRM
#' fit; from openpharma/rbmi#609 on they come as arrays, and every parameter does.
#'
#' The sampler settings in `control_bayes(control = list(...))` reach stanli as
#' they would reach rstan: `adapt_delta`, `max_treedepth`, `stepsize`, `metric`
#' and `adapt_engaged`. Anything stanli cannot honour is refused.
#'
#' The two internals are checked against the rbmi code they were written from, so
#' an rbmi release that changes them stops here instead of being silently replaced.
#'
#' @return `TRUE`, invisibly.
#' @export
#' @examples
#' \dontrun{
#' library(rbmi)
#' library(stanliWebR)
#' drawObj <- draws(data = dat, data_ice = dat_ice, vars = vars, method = method_bayes())
#' }
use_stanli_for_rbmi <- function() {
  require_namespaces("rbmi", c("rbmi", "rstan", "stanli", "jinjar"))
  patch_namespace("rbmi", list(
    get_stan_model = stanli_get_stan_model,
    fit_mcmc = stanli_fit_mcmc
  ), fingerprints = list(
    get_stan_model = "70f31d5f1bc6b492653f12d69e877df7",
    fit_mcmc = c(
      "7095cb6e113f2f4aebbdcd6a35121325", # rbmi 1.7.0, 1.7.1
      "29a77c51955af609c95ca0aa4cf2ec43"  # openpharma/rbmi@2d7b92b: also stops on a failed sampler
    )
  ))
}

# As rbmi's own get_stan_model(), minus ensure_rstan(), the cache and the compile: it
# returns the Stan program, which stanli builds when it samples.
stanli_get_stan_model <- function(covariance, prior_cov) {
  cov_prior_template <- jinjar::parse_template(fs::path(
    find_stan_file(paste0(covariance, "_", prior_cov, ".stan"), subdir = "covariance_priors")
  ))
  cov_prior_string <- jinjar::render(
    .x = cov_prior_template,
    machine_double_eps = .Machine$double.eps
  )
  cov_prior_blocks <- lapply(as_stan_fragments(cov_prior_string), paste, collapse = "\n")
  model_template <- jinjar::parse_template(
    fs::path(find_stan_file("MMRM.stan")),
    .config = jinjar::jinjar_config(trim_blocks = TRUE, lstrip_blocks = TRUE)
  )
  do.call(jinjar::render, c(
    list(.x = model_template),
    c(cov_prior_blocks, machine_double_eps = .Machine$double.eps)
  ))
}

# As rbmi's own fit_mcmc(), with rstan::sampling() replaced by stanli.
stanli_fit_mcmc <- function(designmat, outcome, group, subjid, visit, method, quiet = FALSE) {
  mmrm_initial <- fit_mmrm(
    designmat = designmat, outcome = outcome, subjid = subjid, visit = visit,
    group = group, cov_struct = method$covariance, REML = TRUE,
    same_cov = method$same_cov
  )
  if (mmrm_initial$failed) {
    stop("Fitting MMRM to original dataset failed")
  }

  stan_data <- prepare_stan_data(
    ddat = designmat, subjid = subjid, visit = visit, outcome = outcome,
    group = ife(isTRUE(method$same_cov), rep(1, length(group)), group)
  )
  stan_data <- prepare_prior_params(
    stan_data = stan_data, covariance = method$covariance,
    prior_cov = method$prior_cov, mmrm_initial = mmrm_initial,
    same_cov = method$same_cov
  )

  control <- complete_control_bayes(
    control = method$control, n_samples = method$n_samples, quiet = quiet,
    stan_data = stan_data, mmrm_initial = mmrm_initial,
    covariance = method$covariance, prior_cov = method$prior_cov
  )

  # control_bayes(...) forwards anything it does not recognise to rstan::sampling().
  unsupported <- setdiff(
    names(control),
    c("warmup", "thin", "chains", "init", "seed", "iter", "refresh", "control")
  )
  if (length(unsupported) > 0) {
    stop(
      "control_bayes() argument(s) not supported by stanli: ",
      paste(unsupported, collapse = ", ")
    )
  }
  sampler <- control$control
  unsupported <- setdiff(names(sampler), rstan_controls)
  if (length(unsupported)) {
    stop("control entries not supported by stanli: ", paste(unsupported, collapse = ", "),
         call. = FALSE)
  }

  fit <- sample_stanfit(
    code = get_stan_model(covariance = method$covariance, prior_cov = method$prior_cov),
    data = stan_data,
    chains = control$chains,
    warmup = control$warmup,
    # rstan's `iter` counts warmup; stanli takes the two phases separately.
    samples = control$iter - control$warmup,
    thin = control$thin,
    seed = control$seed,
    init = rstan_init(control$init, chains = control$chains),
    delta = sampler$adapt_delta %||% 0.8,
    max_depth = sampler$max_treedepth %||% 10,
    metric = sampler$metric,
    step_size = sampler$stepsize,
    adapt_engaged = sampler$adapt_engaged,
    refresh = if (quiet) 0 else control$refresh,
    # rbmi's own fit_mcmc() hides the sampler's notices too, through record().
    show_messages = !quiet,
    # rbmi asks rstan for these two only.
    pars = c("beta", "Sigma"),
    # rbmi checks for the class by name, which stanli's subclass does not pass; rbmi
    # needs nothing that the subclass adds.
    plain = TRUE
  )

  check_mcmc(fit, method$n_samples)
  list(samples = extract_draws(fit, method$n_samples), fit = fit)
}
