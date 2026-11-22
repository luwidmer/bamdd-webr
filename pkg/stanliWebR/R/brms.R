#' Make brms sample through stanli
#'
#' brms has a stanli backend of its own, `backend = "stanli"` (paul-buerkner/brms#1966).
#' Loading stanliWebR makes it brms's default, unless `options(brms.backend =)` is
#' already set, and adds what webR needs on top. Calling this by hand is only needed
#' when brms was loaded before stanliWebR was installed.
#'
#' @details
#' Two calls in brms's `.fit_model_stanli()` are replaced, and nothing else in brms is
#' touched, so `init`, `control` and everything downstream of the fit are brms's own.
#' `stanli::stanli_model()` builds the model in fast mode when
#' `options(stanliWebR.fast_math = TRUE)` (see [stanliWebR-package]), and refuses a
#' model whose transformed parameters and generated quantities stanli cannot compute.
#' `stanli::sample_model()` samples the chains on webR workers when there are any.
#'
#' With `cores` > 1 and webR workers started by `miraiWebR::daemons()`, each chain is
#' sampled on a worker of its own, with the same random stream it has in a sequential
#' run, so the fit is identical to the sequential one. Without workers the chains run
#' one after another, and a message says so.
#'
#' @return `TRUE`, invisibly.
#' @export
#' @examples
#' \dontrun{
#' library(stanliWebR)
#' fit <- brms::brm(time ~ age * sex, data = brms::kidney, seed = 1)
#' }
use_stanli_for_brms <- function() {
  require_namespaces("brms", c("brms", "stanli"))
  ns <- asNamespace("brms")
  if (!exists(".fit_model_stanli", envir = ns, mode = "function", inherits = FALSE)) {
    stop("brms ", utils::packageVersion("brms"), " has no stanli backend; stanliWebR ",
         "needs a brms with backend = \"stanli\" (paul-buerkner/brms#1966)", call. = FALSE)
  }
  fit <- get(".fit_model_stanli", envir = ns)
  fit <- swap_call(fit, quote(stanli::stanli_model), quote(brms_stanli_model))
  fit <- swap_call(fit, quote(stanli::sample_model), quote(brms_sample_model))
  patch_namespace("brms", list(.fit_model_stanli = fit))
  if (is.null(getOption("brms.backend"))) {
    options(brms.backend = "stanli")
  }
  invisible(TRUE)
}

brms_stanli_model <- function(...) {
  stanli_model_complete(..., fast_math = fast_math_option())
}

# The stanli::sample_model() arguments a run on workers honours.
worker_sample_args <- c(
  "chains", "seed", "warmup", "samples", "thin", "delta", "max_depth", "save_warmup",
  "init", "init_radius", "parallel_chains", "refresh", "threads_per_chain",
  "fixed_param", "metric", "step_size", "adapt_engaged"
)

# stanli::sample_model(), with the chains on webR workers when brms asks for cores and
# workers are running. Defaults are stanli's.
brms_sample_model <- function(model, ...) {
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
    model, code = model$model_code, data = model$source$data_json, chains = chains,
    seed = args$seed %||% 1, init = args$init %||% args$init_radius %||% 2,
    warmup = args$warmup %||% 1000, samples = args$samples %||% 1000,
    thin = args$thin %||% 1, delta = args$delta %||% 0.8,
    max_depth = args$max_depth %||% 10, threads = model$threads_per_chain,
    save_warmup = isTRUE(args$save_warmup), fast_math = model$fast_math,
    controls = Filter(Negate(is.null), args[c("metric", "step_size", "adapt_engaged")])
  )
}
