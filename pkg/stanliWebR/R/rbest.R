#' Make RBesT and OncoBayes2 sample through stanli
#'
#' [RBesT::gMAP()] and [OncoBayes2::blrm_exnex()] sample precompiled Stan models
#' with [rstan::sampling()]. These functions make them run the same Stan programs
#' on stanli instead, returning an ordinary rstan `stanfit`, so everything
#' downstream is the packages' own code. Loading stanliWebR arranges for this to
#' happen whenever either package is loaded.
#'
#' @details
#' Only the one `rstan::sampling()` call in `gMAP()` and in `blrm_exnex()` is
#' replaced. rstan's sampling arguments are honoured where stanli has an
#' equivalent, including the starting step size `control$stepsize`. Both
#' programs run on stanli as they are.
#'
#' Should stanli be unable to compute a model's transformed parameters and
#' generated quantities (as stanli 0.24.0 was for OncoBayes2's combination
#' models), the package's compiled rstan model samples it instead, rather than
#' returning draws without them. In webR that model cannot run once stanli is
#' loaded, so there it is an error that says to restart R and sample without
#' stanliWebR.
#'
#' @return `TRUE`, invisibly.
#' @export
#' @examples
#' \dontrun{
#' library(stanliWebR)
#' library(RBesT)
#' map <- gMAP(cbind(r, n - r) ~ 1 | study, family = binomial, data = AS,
#'             tau.dist = "HalfNormal", tau.prior = 1, beta.prior = 2)
#' }
use_stanli_for_rbest <- function() {
  require_namespaces("RBesT", c("RBesT", "rstan", "stanli"))
  patch_namespace("RBesT", list(
    gMAP = swap_call(asNamespace("RBesT")$gMAP, quote(rstan::sampling), quote(stanli_sampling))
  ))
}

#' @rdname use_stanli_for_rbest
#' @export
use_stanli_for_oncobayes2 <- function() {
  require_namespaces("OncoBayes2", c("OncoBayes2", "rstan", "stanli"))
  patch_namespace("OncoBayes2", list(
    blrm_exnex = swap_call(
      asNamespace("OncoBayes2")$blrm_exnex, quote(rstan::sampling), quote(stanli_sampling)
    )
  ))
}
