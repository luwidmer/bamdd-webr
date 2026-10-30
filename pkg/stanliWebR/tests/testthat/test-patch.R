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
