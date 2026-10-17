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
#' equivalent, including the starting step size `control$stepsize`. OncoBayes2's
#' program has one statement stanli cannot
#' compile -- a function that can `reject()`, used to size data -- so that guard
#' is dropped; an empty input still fails, with Stan's own index error.
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
      asNamespace("OncoBayes2")$blrm_exnex, quote(rstan::sampling), quote(oncobayes2_sampling)
    )
  ))
}

oncobayes2_sampling <- function(object, ...) {
  stanli_sampling(object, ..., code = oncobayes2_code(object@model_code))
}

# Two statements stanli cannot run, rewritten without changing the model: a
# data-block size computed by a function that can reject(), and sort_asc(), which
# stanli does not implement.
oncobayes2_code <- function(code) {
  replace_once <- function(code, old, new) {
    if (lengths(regmatches(code, gregexpr(old, code, fixed = TRUE))) != 1L) {
      stop("OncoBayes2's Stan program has changed (looked for `", trimws(old),
           "`); stanliWebR needs updating", call. = FALSE)
    }
    sub(old, new, code, fixed = TRUE)
  }
  code <- replace_once(
    code, "    if (size(test) == 0) reject(\"Test array must have length greater than 0.\");\n", ""
  )
  code <- replace_once(code, "rle_elem_count(sort_asc(elems))", "rle_elem_count(stanli_sort_asc_int(elems))")
  code <- replace_once(code, "= sort_asc(elems);", "= stanli_sort_asc_vector(elems);")
  replace_once(code, "functions {\n", paste0("functions {\n", stanli_sort_functions))
}

stanli_sort_functions <- "
  array[] int stanli_sort_asc_int(array[] int x) {
    array[size(x)] int y = x;
    for (i in 1:(size(y) - 1)) {
      int m = i;
      for (j in (i + 1):size(y)) {
        if (y[j] < y[m]) m = j;
      }
      int v = y[i];
      y[i] = y[m];
      y[m] = v;
    }
    return y;
  }
  vector stanli_sort_asc_vector(vector x) {
    vector[num_elements(x)] y = x;
    for (i in 1:(num_elements(y) - 1)) {
      int m = i;
      for (j in (i + 1):num_elements(y)) {
        if (y[j] < y[m]) m = j;
      }
      real v = y[i];
      y[i] = y[m];
      y[m] = v;
    }
    return y;
  }
"
