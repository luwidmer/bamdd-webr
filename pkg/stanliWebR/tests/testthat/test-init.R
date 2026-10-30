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

test_that("rbmi's per-group starting values are trimmed to one shared group", {
  per_group_init <- stanliWebR:::per_group_init
  same <- list(beta = 1, sigma = list(diag(2), diag(2)))
  expect_identical(per_group_init(same, 1L)$sigma, list(diag(2)))
  expect_identical(per_group_init(same, 2L), same)
  expect_identical(per_group_init("random", 1L), "random")
  differ <- list(beta = 1, sigma = list(diag(2), 2 * diag(2)))
  expect_error(per_group_init(differ, 1L), "they differ")
})
