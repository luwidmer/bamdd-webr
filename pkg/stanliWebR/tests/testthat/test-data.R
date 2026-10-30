test_that("data of any rank and lists of matrices reach the model as rstan passes them", {
  code <- "
    data { array[2] matrix[2, 2] A; array[2, 2, 2] real B; }
    transformed data { real total = sum(A[2]) + sum(to_array_1d(B)); }
    parameters { real x; }
    model { x ~ normal(total, 1e-3); }
  "
  data <- list(A = list(matrix(1:4, 2) + 0, matrix(5:8, 2) + 0), B = array(as.numeric(1:8), c(2, 2, 2)))
  fit <- rstan::sampling(rstan::stan_model(model_code = code), data = data, chains = 1,
                         iter = 300, seed = 1, refresh = 0)
  expect_equal(mean(as.matrix(fit)[, "x"]), 26 + 36, tolerance = 1e-3)
})

test_that("a named list in the data is an array, as rstan reads it", {
  data <- stanliWebR:::stan_data(list(n = 2L, S = list(a = diag(2), b = 2 * diag(2))))
  expect_null(names(data$S))
  expect_identical(names(data), c("n", "S"))
  code <- "
    data { int n; array[2] matrix[n, n] S; }
    parameters { real x; }
    model { x ~ normal(S[2][1, 1], 1e-3); }
  "
  fit <- rstan::sampling(rstan::stan_model(model_code = code),
                         data = list(n = 2L, S = list(a = diag(2), b = 2 * diag(2))),
                         chains = 1, iter = 300, seed = 1, refresh = 0)
  expect_equal(mean(as.matrix(fit)[, "x"]), 2, tolerance = 1e-3)
})
