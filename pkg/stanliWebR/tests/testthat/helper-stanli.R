# The chains-on-workers tests need the application's webR worker pool, which only
# tools/test-browser.mjs provides; tools/test-packages.mjs runs without workers.
skip_if_no_workers <- function() {
  skip_if_not_installed("miraiWebR")
  skip_if_not(
    isTRUE(miraiWebR::status()$connections >= 2L),
    "needs two webR workers (tools/test-browser.mjs)"
  )
}

normal_code <- "
  data { int N; vector[N] y; }
  parameters { real mu; real<lower=0> sigma; }
  model { y ~ normal(mu, sigma); }
"
normal_data <- list(N = 3L, y = c(1, 2, 3))

quiet_sampling <- function(model, ...) {
  rstan::sampling(model, data = normal_data, refresh = 0, ...)
}
