test_that("tasks run on the workers, in parallel", {
  skip_unless_workers()
  local_daemons(2)
  ids <- mirai_map(1:2, function(i) Sys.getenv("MIRAI_WEBR_WORKER"))[.flat]
  expect_true(all(nzchar(ids)))
  busy <- function(i) {
    t0 <- proc.time()[[3]]
    while (proc.time()[[3]] - t0 < 1) NULL
    i
  }
  elapsed <- system.time(v <- mirai_map(1:4, busy)[.flat])[["elapsed"]]
  expect_identical(v, 1:4)
  expect_lt(elapsed, 3.5)
})

test_that("stop_mirai() cancels a running task", {
  skip_unless_workers()
  local_daemons(1)
  m <- mirai({ t0 <- proc.time()[[3]]; while (proc.time()[[3]] - t0 < 60) NULL; 1 })
  stop_mirai(m)
  expect_true(is_error_value(m[]))
})
