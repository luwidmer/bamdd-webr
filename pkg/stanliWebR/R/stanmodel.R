#' Run Stan programs from rstan::stan_model() on stanli
#'
#' Makes the plain rstan workflow, [rstan::stan_model()] followed by
#' [rstan::sampling()], work without a C++ toolchain. `stan_model()` keeps the
#' Stan code instead of compiling it and returns a `stanliWebR_stanmodel`, a subclass
#' of rstan's `stanmodel`; `sampling()` on it runs the program on stanli and
#' returns an ordinary rstan `stanfit`. Loading stanliWebR arranges for this to
#' happen whenever rstan is loaded.
#'
#' @details
#' `stan_model()` takes the program from `file`, `model_code` or `stanc_ret`.
#' Options that only steer the C++ compiler are ignored; ones that need it
#' (`allow_undefined`, `standalone_functions`, `use_opencl`) stop with an error.
#' `sampling()` accepts rstan's arguments as described for RBesT and OncoBayes2
#' in [use_stanli_for_rbest()]. Models precompiled into other packages keep their
#' own `stanmodel` class and are not affected.
#'
#' @return `TRUE`, invisibly.
#' @export
#' @examples
#' \dontrun{
#' library(rstan)
#' library(stanliWebR)
#' m <- stan_model(model_code = "parameters { real mu; } model { mu ~ normal(0, 1); }")
#' fit <- sampling(m, chains = 1, seed = 1)
#' }
use_stanli_for_rstan <- function() {
  require_namespaces("rstan", c("rstan", "stanli"))
  # The namespace is sealed once loaded, and rstan need not be attached: define the
  # class and method where rstan's own definitions are visible. The name differs from
  # stanli's own stanli_stanmodel, which stanli registers whenever rstan loads.
  where <- new.env(parent = asNamespace("rstan"))
  methods::setClass("stanliWebR_stanmodel", contains = "stanmodel", where = where)
  methods::setMethod(
    "sampling", "stanliWebR_stanmodel",
    function(object, ...) stanli_sampling(object, ...),
    where = where
  )
  patch_namespace("rstan", list(stan_model = stanli_stan_model))
}

stanli_stan_model <- function(file, model_name = "anon_model", model_code = "",
                              stanc_ret = NULL, allow_undefined = FALSE,
                              standalone_functions = FALSE, use_opencl = FALSE, ...) {
  if (isTRUE(allow_undefined) || isTRUE(standalone_functions) || isTRUE(use_opencl)) {
    stop("allow_undefined, standalone_functions and use_opencl need a C++ toolchain; ",
         "stanli cannot honour them", call. = FALSE)
  }
  if (!missing(file)) {
    model_code <- paste(readLines(file, warn = FALSE), collapse = "\n")
    if (missing(model_name) || is.null(model_name)) {
      model_name <- tools::file_path_sans_ext(basename(file))
    }
  } else if (!is.null(stanc_ret)) {
    model_code <- stanc_ret$model_code
    if (missing(model_name)) model_name <- stanc_ret$model_name
  }
  # rstan::stan() passes model_name = NULL, and the variable holding the code, if
  # any, as model_name2.
  if (is.null(model_name)) {
    name2 <- attr(model_code, "model_name2")
    model_name <- if (isTRUE(make.names(name2) == name2)) name2 else "anon_model"
  }
  if (!nzchar(paste(model_code, collapse = ""))) {
    stop("stan_model() needs a Stan program in file, model_code or stanc_ret", call. = FALSE)
  }
  model_code <- paste(model_code, collapse = "\n")
  # stanli builds the model only when the data are known; report errors in the
  # program now, as rstan's compile would.
  stanli::stanli_check_syntax(model_code)
  methods::new("stanliWebR_stanmodel", model_name = model_name, model_code = model_code)
}
