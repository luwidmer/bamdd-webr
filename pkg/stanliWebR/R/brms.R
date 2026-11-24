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
#' `options(stanliWebR.fast_math = TRUE)` (see [stanliWebR-package]).
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
  fit <- get0(".fit_model_stanli", envir = asNamespace("brms"), mode = "function",
              inherits = FALSE)
  fit <- swap_call(fit, quote(stanli::stanli_model), quote(webr_stanli_model))
  fit <- swap_call(fit, quote(stanli::sample_model), quote(webr_sample_model))
  patch_namespace("brms", list(.fit_model_stanli = fit))
  if (is.null(getOption("brms.backend"))) {
    options(brms.backend = "stanli")
  }
  invisible(TRUE)
}
