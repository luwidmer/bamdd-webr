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
#' rbmi's two Stan helper functions are rewritten with `for` loops, which stanli
#' accepts; the posterior is unchanged. Starting values follow rstan: the MMRM
#' estimates rbmi supplies are used for every name that is a Stan parameter, and
#' the remaining parameters start uniform on (-2, 2) on the unconstrained scale.
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
  ))
}

# rbmi's two Stan helper functions walk their input with a while loop and a mutable
# integer index. stanli rejects that ("integer ... is not known at compile time"),
# so swap in for-loop equivalents before the template is rendered.
stanli_helper_functions <- c(
  "    int integer_division(int a, int b) {",
  "        return a %/% b;",
  "    }",
  "",
  "    array[] vector to_vector_of_arrays(vector vec, int length_array) {",
  "        int n = num_elements(vec) %/% length_array;",
  "        array[n] vector[length_array] res;",
  "        for (i in 1:n) {",
  "            res[i] = vec[((i - 1) * length_array + 1):(i * length_array)];",
  "        }",
  "        return res;",
  "    }",
  ""
)

# As rbmi's own get_stan_model(), minus ensure_rstan() and the compile: it returns
# the Stan program, which stanli parses when it samples.
stanli_get_stan_model <- function(covariance, prior_cov) {
  cov_prior_template <- jinjar::parse_template(fs::path(
    find_stan_file(paste0(covariance, "_", prior_cov, ".stan"), subdir = "covariance_priors")
  ))
  cov_prior_string <- jinjar::render(
    .x = cov_prior_template,
    machine_double_eps = .Machine$double.eps
  )
  cov_prior_blocks <- lapply(as_stan_fragments(cov_prior_string), paste, collapse = "\n")

  source_lines <- readLines(find_stan_file("MMRM.stan"))
  marker <- grep("{{ functions }}", source_lines, fixed = TRUE)
  if (!identical(trimws(source_lines[1]), "functions {") || length(marker) != 1L) {
    stop("MMRM.stan no longer opens with a single functions block; the stanli patch is stale")
  }
  model_template <- jinjar::parse_template(
    paste(
      c("functions {", stanli_helper_functions, source_lines[marker:length(source_lines)]),
      collapse = "\n"
    ),
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
    c("warmup", "thin", "chains", "init", "seed", "iter", "refresh")
  )
  if (length(unsupported) > 0) {
    stop(
      "control_bayes() argument(s) not supported by stanli: ",
      paste(unsupported, collapse = ", ")
    )
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
    init = rstan_init(per_group_init(control$init, stan_data$G), chains = control$chains),
    # rstan's defaults; control_bayes() offers no way to change them.
    delta = 0.8,
    max_depth = 10,
    refresh = if (quiet) 0 else control$refresh,
    # rbmi asks rstan for these two only.
    pars = c("beta", "Sigma")
  )
  # rbmi checks for the class by name, which stanli's subclass does not pass; rbmi
  # needs nothing that the subclass adds.
  class(fit) <- structure("stanfit", package = "rstan")

  check_mcmc(fit, method$n_samples)
  list(samples = extract_draws(fit, method$n_samples), fit = fit)
}

# rbmi fits the initial MMRM with one covariance per group even under
# same_cov = TRUE, and passes one starting value per group, while the Stan program
# then has a single group (G = 1). rstan reads only the values it needs; stanli
# insists on the declared size, so keep the first G -- after checking that the
# values dropped are copies of those kept.
per_group_init <- function(init, G) {
  if (!is.list(init)) {
    return(init)
  }
  trim <- function(values) {
    lapply(values, function(v) {
      if (!is.list(v) || length(v) <= G) {
        return(v)
      }
      if (G != 1L || !all(vapply(v, identical, logical(1), v[[1]]))) {
        stop("rbmi supplied ", length(v), " per-group starting values for ", G,
             " covariance group(s), and they differ", call. = FALSE)
      }
      v[seq_len(G)]
    })
  }
  if (is.null(names(init))) lapply(init, trim) else trim(init)
}
