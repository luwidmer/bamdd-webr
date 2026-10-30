test_that("without workers, daemons() falls back to the console and says so", {
  skip_unless_sequential()
  expect_message(daemons(2), "Tasks will run in this R session")
  withr::defer(daemons(0))
  expect_true(daemons_set())
  expect_identical(status()$mode, "sequential")
  expect_error(daemons(2), "already set")
})

test_that("tasks run in the console, with their arguments, values and errors", {
  skip_unless_sequential()
  local_daemons(2)
  expect_identical(mirai(6 * 7)[], 42)
  expect_identical(mirai(x + y, x = 1, .args = list(y = 2))[], 3)
  m <- mirai(stop("boom"))
  expect_true(is_mirai_error(m[]))
  expect_true(is_error_value(m$data))
  expect_match(format(m$data), "boom")
  expect_false(unresolved(m))
})

test_that("tasks do not touch the caller's workspace", {
  skip_unless_sequential()
  local_daemons(1)
  mirai(leaked_by_task <- 1)[]
  expect_false(exists("leaked_by_task", envir = globalenv(), inherits = FALSE))
})

test_that("everywhere() defines what later tasks see, outside the workspace", {
  skip_unless_sequential()
  local_daemons(2)
  everywhere(add_one <- function(x) x + 1)
  expect_identical(mirai_map(1:3, function(x) add_one(x))[.flat], c(2, 3, 4))
  expect_false(exists("add_one", envir = globalenv(), inherits = FALSE))
  daemons(0)
  expect_false("miraiWebR:sequential" %in% search())
  expect_identical(status()$mode, "none")
})

test_that("a seed makes the tasks' random streams reproducible", {
  skip_unless_sequential()
  draw <- function() {
    local_daemons(2, seed = 42)
    mirai_map(1:3, function(i) stats::runif(1))[.flat]
  }
  set.seed(1)
  before <- .Random.seed
  a <- draw()
  expect_identical(.Random.seed, before)
  expect_identical(a, draw())
  expect_length(unique(a), 3L)
})

test_that("the future backend runs on the same fallback", {
  skip_unless_sequential()
  skip_if_not_installed("future")
  skip_if_not_installed("future.apply")
  local_daemons(2)
  future::plan(webr_workers)
  withr::defer(future::plan(future::sequential))
  expect_identical(future.apply::future_sapply(1:4, function(i) i^2), c(1, 4, 9, 16))
})
