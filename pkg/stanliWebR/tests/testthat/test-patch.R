swap_call <- stanliWebR:::swap_call

test_that("swap_call() replaces the one call, and patching twice is harmless", {
  f <- function(x) {
    y <- rstan::sampling(x, chains = 1)
    y
  }
  g <- swap_call(f, quote(rstan::sampling), quote(stanli_sampling))
  expect_match(paste(deparse(body(g)), collapse = "\n"), "stanli_sampling(x, chains = 1)", fixed = TRUE)
  expect_identical(swap_call(g, quote(rstan::sampling), quote(stanli_sampling)), g)
})

test_that("swap_call() also replaces a function taken as a value", {
  f <- function(x) {
    fit_fun <- stanli::sample_model
    fit_fun(x)
  }
  g <- swap_call(f, quote(stanli::sample_model), quote(brms_sample_model))
  expect_match(paste(deparse(body(g)), collapse = "\n"), "fit_fun <- brms_sample_model", fixed = TRUE)
  expect_identical(swap_call(g, quote(stanli::sample_model), quote(brms_sample_model)), g)
})

test_that("brms's own stanli backend is the default, sampling through stanliWebR", {
  skip_if_not_installed("brms")
  loadNamespace("brms")
  expect_identical(getOption("brms.backend"), "stanli")
  fit <- asNamespace("brms")$.fit_model_stanli
  expect_identical(environment(fit)$brms_sample_model, stanliWebR:::brms_sample_model)
  code <- paste(deparse(body(fit)), collapse = "\n")
  expect_no_match(code, "stanli::(sample_model|stanli_model)")
})

test_that("swap_call() refuses a function that no longer has the call", {
  expect_error(swap_call(function(x) x, quote(rstan::sampling), quote(stanli_sampling)),
               "needs updating")
  expect_error(swap_call(NULL, quote(rstan::sampling), quote(stanli_sampling)), "not found")
  twice <- function(x) c(rstan::sampling(x), rstan::sampling(x))
  expect_error(swap_call(twice, quote(rstan::sampling), quote(stanli_sampling)), "found 2")
})

test_that("a missing package is reported by name", {
  expect_error(
    stanliWebR:::require_namespaces("something", "notapackage.stanliwebr"),
    "notapackage.stanliwebr package is not installed"
  )
})

test_that("rstan is patched whenever it is loaded", {
  expect_identical(
    environment(asNamespace("rstan")$stan_model)$stanli_sampling,
    stanliWebR:::stanli_sampling
  )
})

test_that("a fingerprint follows a function's code, not its environment", {
  fingerprint <- stanliWebR:::fingerprint
  f <- function(x) x + 1
  expect_identical(fingerprint(f), fingerprint(local(function(x) x + 1)))
  expect_false(identical(fingerprint(f), fingerprint(function(x) x + 2)))
})

test_that("rbmi is patched only where its code is the one replaced", {
  skip_if_not_installed("rbmi")
  ns <- asNamespace("rbmi")
  expect_identical(environment(ns$fit_mcmc)$rstan_init, stanliWebR:::rstan_init)
  patched <- ns$fit_mcmc
  expect_true(stanliWebR::use_stanli_for_rbmi())
  expect_identical(body(ns$fit_mcmc), body(patched))
  expect_error(
    stanliWebR:::patch_namespace("rbmi", list(fit_mcmc = function() NULL),
                                 fingerprints = list(fit_mcmc = c("0", "1"))),
    "internal fit_mcmc\\(\\) is not the one stanliWebR replaces"
  )
  expect_identical(body(ns$fit_mcmc), body(patched))
})
