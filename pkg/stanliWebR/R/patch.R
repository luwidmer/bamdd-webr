# The replacements are evaluated in a child of the patched package's namespace (see
# patch_namespace()), so these names resolve at run time to that package's own
# internals even though they are not defined here.
utils::globalVariables(c(
  # brms
  "collapse_comma", "repair_stanfit", "stop2", "use_opencl", "use_threading",
  # rbmi
  "as_stan_fragments", "check_mcmc", "complete_control_bayes", "extract_draws",
  "find_stan_file", "fit_mmrm", "get_stan_model", "ife", "prepare_prior_params",
  "prepare_stan_data"
))

require_namespaces <- function(target, pkgs) {
  # Older stanli needs the workarounds this version dropped: it cannot take
  # three-dimensional data, while-loop sizes or reject() in a size (rbmi,
  # OncoBayes2), sort_asc() or chain_id, and lacks parameter_names(),
  # unconstrain(seed =, ignore_unknown =) and as_stanfit(plain =). Before 0.25.0
  # it also loses the generated quantities of OncoBayes2's combination models.
  minimum <- c(stanli = "0.25.0")
  for (pkg in pkgs) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
      stop("stanliWebR cannot patch ", target, ": the ", pkg,
           " package is not installed.", call. = FALSE)
    }
    if (pkg %in% names(minimum) && utils::packageVersion(pkg) < minimum[[pkg]]) {
      stop("stanliWebR cannot patch ", target, ": it needs ", pkg, " >= ",
           minimum[[pkg]], ", and ", utils::packageVersion(pkg), " is installed.",
           call. = FALSE)
    }
  }
}

# Replace functions inside a package namespace. Each replacement is evaluated in a
# child of that namespace, so it calls the package's internals exactly as the
# original does, plus the stanliWebR helpers it needs.
patch_namespace <- function(pkg, replacements) {
  ns <- asNamespace(pkg)
  helpers <- new.env(parent = ns)
  helpers$sample_stanfit <- sample_stanfit
  helpers$rstan_controls <- rstan_controls
  helpers$rstan_init <- rstan_init
  helpers$per_group_init <- per_group_init
  helpers$stanli_sampling <- stanli_sampling
  attached <- paste0("package:", pkg)
  for (name in names(replacements)) {
    if (!exists(name, envir = ns, mode = "function", inherits = FALSE)) {
      stop(pkg, " ", utils::packageVersion(pkg), " has no internal ", name,
           "(); stanliWebR needs updating for it", call. = FALSE)
    }
    fun <- replacements[[name]]
    environment(fun) <- helpers
    utils::assignInNamespace(name, fun, ns = pkg)
    # Attaching copies exports, so a package attached before the patch keeps the old one.
    if (attached %in% search() && exists(name, envir = as.environment(attached), inherits = FALSE)) {
      env <- as.environment(attached)
      unlockBinding(name, env)
      assign(name, fun, envir = env)
      lockBinding(name, env)
    }
  }
  invisible(TRUE)
}
