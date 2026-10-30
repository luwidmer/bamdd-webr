test_that("stan_model() keeps the program as a stanliWebR_stanmodel", {
  m <- rstan::stan_model(model_code = normal_code, model_name = "normal")
  expect_s4_class(m, "stanliWebR_stanmodel")
  expect_s4_class(m, "stanmodel")
  expect_identical(m@model_name, "normal")
})

test_that("stan_model() reports errors in the program, as a compile would", {
  expect_error(rstan::stan_model(model_code = "parameters { real mu } model { }"))
})

test_that("stan_model() refuses what needs a C++ toolchain", {
  expect_error(
    rstan::stan_model(model_code = normal_code, allow_undefined = TRUE),
    "C\\+\\+ toolchain"
  )
})

test_that("sampling() returns a stanfit, reproducibly, leaving R's stream alone", {
  m <- rstan::stan_model(model_code = normal_code)
  set.seed(1)
  before <- .Random.seed
  a <- quiet_sampling(m, chains = 2, iter = 300, seed = 7)
  expect_identical(.Random.seed, before)
  b <- quiet_sampling(m, chains = 2, iter = 300, seed = 7)
  expect_s4_class(a, "stanfit")
  expect_identical(as.array(a), as.array(b))
  expect_identical(dim(as.array(a)), c(150L, 2L, 3L))
})

test_that("sampling() records the sampler settings as rstan does", {
  m <- rstan::stan_model(model_code = normal_code)
  fit <- quiet_sampling(m, chains = 1, iter = 300, seed = 2,
                        control = list(metric = "dense_e", stepsize = 0.5, adapt_delta = 0.9))
  args <- fit@stan_args[[1]]
  expect_identical(args$sampler_t, "NUTS(dense_e)")
  expect_identical(args$control$stepsize, 0.5)
  expect_identical(args$control$adapt_delta, 0.9)
})

test_that("sampling() takes rstan's forms of init", {
  m <- rstan::stan_model(model_code = normal_code)
  expect_s4_class(quiet_sampling(m, chains = 1, iter = 200, seed = 3, init = "0"), "stanfit")
  expect_s4_class(quiet_sampling(m, chains = 1, iter = 200, seed = 3, init = 0.5), "stanfit")
  # Names that are not parameters are ignored, as rstan ignores them.
  expect_s4_class(
    quiet_sampling(m, chains = 2, iter = 200, seed = 3, init = list(mu = 2, not_a_parameter = 1)),
    "stanfit"
  )
  expect_s4_class(
    quiet_sampling(m, chains = 2, iter = 200, seed = 3,
                   init = list(list(mu = 1, sigma = 1), list(mu = 3, sigma = 2))),
    "stanfit"
  )
  expect_error(
    quiet_sampling(m, chains = 3, iter = 200, seed = 3, init = list(list(mu = 1), list(mu = 2))),
    "2 sets of starting values for 3 chains"
  )
})

test_that("sampling() keeps the parameters pars and include select", {
  m <- rstan::stan_model(model_code = normal_code)
  kept <- quiet_sampling(m, chains = 1, iter = 200, seed = 4, pars = "mu")
  expect_identical(kept@model_pars, c("mu", "lp__"))
  dropped <- quiet_sampling(m, chains = 1, iter = 200, seed = 4, pars = "mu", include = FALSE)
  expect_identical(dropped@model_pars, c("sigma", "lp__"))
})

test_that("sampling() refuses what stanli cannot honour rather than ignoring it", {
  m <- rstan::stan_model(model_code = normal_code)
  expect_error(quiet_sampling(m, algorithm = "HMC"), "only samples with NUTS")
  expect_error(quiet_sampling(m, control = list(adapt_gamma = 0.1)), "adapt_gamma")
  expect_error(quiet_sampling(m, sample_file = "draws.csv"), "sample_file")
  expect_error(quiet_sampling(m, bogus = 1), "bogus")
})

test_that("stan() compiles and samples in one call", {
  fit <- rstan::stan(model_code = normal_code, data = normal_data, chains = 1, iter = 200,
                     seed = 5, refresh = 0)
  expect_s4_class(fit, "stanfit")
})
