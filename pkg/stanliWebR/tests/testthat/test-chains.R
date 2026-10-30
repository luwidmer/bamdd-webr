sample_args <- list(
  code = normal_code, data = normal_data, warmup = 100, samples = 100, thin = 1, seed = 11,
  init = 2, delta = 0.8, max_depth = 10
)

test_that("chains sampled one by one, as on workers, equal a multi-chain run", {
  sample_chain <- stanliWebR:::sample_chain
  model <- stanli::stanli_model(code = normal_code, data = normal_data, seed = 11)
  fits <- lapply(1:3, function(k) {
    do.call(sample_chain, c(sample_args, list(
      chain_id = k, threads = 1L, save_warmup = FALSE, fast_math = FALSE, controls = list()
    )))
  })
  bound <- stanli::as_stanfit(stanliWebR:::bind_chains(fits, model))
  together <- do.call(stanliWebR:::sample_stanfit, c(sample_args, list(chains = 3, refresh = 0)))
  expect_identical(as.array(bound), as.array(together))
  expect_identical(vapply(bound@stan_args, `[[`, 0L, "chain_id"), 1:3)
})

test_that("plain = TRUE returns exactly a stanfit", {
  fit <- do.call(stanliWebR:::sample_stanfit, c(sample_args, list(chains = 1, refresh = 0, plain = TRUE)))
  expect_identical(class(fit)[1], "stanfit")
})

test_that("cores > 1 without workers says so and samples in sequence", {
  m <- rstan::stan_model(model_code = normal_code)
  skip_if(isTRUE(tryCatch(miraiWebR::status()$connections > 0, error = function(e) FALSE)))
  expect_message(
    fit <- quiet_sampling(m, chains = 2, iter = 200, seed = 6, cores = 2),
    "no webR workers are running"
  )
  expect_identical(as.array(fit), as.array(quiet_sampling(m, chains = 2, iter = 200, seed = 6)))
})

test_that("chains on webR workers are identical to a sequential fit", {
  skip_if_no_workers()
  m <- rstan::stan_model(model_code = normal_code)
  sequential <- quiet_sampling(m, chains = 2, iter = 300, seed = 3, cores = 1)
  parallel <- suppressMessages(quiet_sampling(m, chains = 2, iter = 300, seed = 3, cores = 2))
  expect_identical(as.array(parallel), as.array(sequential))
})

test_that("options(stanliWebR.fast_math =) must be TRUE or FALSE", {
  withr::local_options(stanliWebR.fast_math = "yes")
  expect_error(stanliWebR:::fast_math_option(), "TRUE or FALSE")
})
