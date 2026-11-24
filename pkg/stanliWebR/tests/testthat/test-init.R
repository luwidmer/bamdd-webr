rstan_init <- stanliWebR:::rstan_init

test_that("rstan's init shorthands become a radius", {
  expect_identical(rstan_init(NULL, 2), 2)
  expect_identical(rstan_init("random", 2), 2)
  expect_identical(rstan_init("0", 2), 0)
  expect_identical(rstan_init(0.5, 2), 0.5)
  expect_error(rstan_init("nonsense", 2), "supports init")
  expect_error(rstan_init(-1, 2), "supports init")
})

test_that("a list of starting values is one per chain or shared by all", {
  expect_type(rstan_init(list(mu = 1), 3), "closure")
  expect_type(rstan_init(list(list(mu = 1), list(mu = 2)), 2), "closure")
  expect_error(rstan_init(list(list(mu = 1), list(mu = 2)), 3), "2 sets of starting values for 3 chains")
})

test_that("starting values come from the run's seed, not R's stream", {
  model <- stanli::stanli_model(code = normal_code, data = normal_data, seed = 1)
  start <- rstan_init(list(mu = 1), 2)
  set.seed(1)
  before <- .Random.seed
  a <- start(model, 9)
  expect_identical(.Random.seed, before)
  expect_identical(a, start(model, 9))
  expect_identical(dim(a), c(2L, 2L))
  expect_false(identical(a[1, ], a[2, ]))
})

test_that("list-valued starting values are ignored, as rstan ignores them", {
  code <- "
    parameters { real mu; array[2] real<lower=-1, upper=1> rho; array[2] cov_matrix[2] S; }
    model { mu ~ normal(0, 1); for (g in 1:2) S[g] ~ wishart(4, diag_matrix(rep_vector(1, 2))); }
  "
  model <- stanli::stanli_model(code = code, data = list(), seed = 1)
  only_mu <- rstan_init(list(mu = 1), 2)(model, 9)
  # As rbmi supplies them: one per group, named by group.
  named <- rstan_init(list(mu = 1, rho = list(DRUG = 0.6, PLACEBO = 0.2),
                           S = list(DRUG = diag(2), PLACEBO = 2 * diag(2))), 2)(model, 9)
  unnamed <- rstan_init(list(mu = 1, rho = list(0.6, 0.2), S = list(diag(2), 2 * diag(2))), 2)(model, 9)
  expect_identical(named, only_mu)
  expect_identical(unnamed, only_mu)
  expect_equal(unname(rstan_init(list(mu = 1, rho = c(0.6, 0.2)), 1)(model, 9)[1, 2:3]),
               qlogis((c(0.6, 0.2) + 1) / 2))
})
