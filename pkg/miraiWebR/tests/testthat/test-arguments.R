test_that("daemons() refuses what it cannot honour", {
  expect_error(daemons(), "daemons\\(n\\) starts n webR workers")
  expect_error(daemons(-1), "non-negative whole number")
  expect_error(daemons(1.5), "non-negative whole number")
  expect_error(daemons(2, url = "tcp://host:1"), "not supported by miraiWebR: url")
  expect_error(daemons(2, .compute = "gpu"), "compute profiles")
})

test_that("mirai() refuses a timeout", {
  expect_error(mirai(1, .timeout = 10), ".timeout is not supported")
})

test_that("nothing runs before daemons() are set", {
  skip_if(is.na(pool_max()), "needs a worker pool")
  daemons(0)
  expect_error(mirai(1), "no daemons set")
})

test_that("workers cannot start workers", {
  withr::local_envvar(MIRAI_WEBR_WORKER = "1")
  expect_error(daemons(2), "cannot be used inside a webR worker")
})
