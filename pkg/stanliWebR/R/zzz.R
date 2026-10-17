#' @section Options:
#' \describe{
#'   \item{`stanliWebR.fast_math`}{`TRUE` builds every model in stanli's fast
#'     mode (see `stanli::stanli_model()`): fused multiply-add and faster, less
#'     exactly rounded arithmetic. Differences in the last bits grow along a
#'     chain, so the draws differ from a default run with the same seed. Defaults
#'     to `FALSE`.}
#' }
#' @keywords internal
"_PACKAGE"

# `f` and `a` are bound on the worker by mirai(.args =) in sample_on_workers().
utils::globalVariables(c("f", "a"))

.onLoad <- function(libname, pkgname) {
  patch_when_loaded("rstan", use_stanli_for_rstan)
  patch_when_loaded("brms", use_stanli_for_brms)
  patch_when_loaded("rbmi", use_stanli_for_rbmi)
  patch_when_loaded("RBesT", use_stanli_for_rbest)
  patch_when_loaded("OncoBayes2", use_stanli_for_oncobayes2)
  invisible(NULL)
}

# Patch now if the package is already loaded, otherwise as soon as it is. Waiting
# keeps library(stanliWebR) cheap, and loading brms just to patch it would cost
# the rbmi user several seconds.
patch_when_loaded <- function(pkg, patch) {
  if (isNamespaceLoaded(pkg)) {
    patch()
  } else {
    setHook(packageEvent(pkg, "onLoad"), function(...) patch())
  }
}
