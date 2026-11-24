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

rbmi_data <- function() {
  dat <- rbmi::antidepressant_data
  rbmi::expand_locf(
    dat, PATIENT = levels(dat$PATIENT), VISIT = levels(dat$VISIT),
    vars = c("BASVAL", "THERAPY"), group = "PATIENT", order = c("PATIENT", "VISIT")
  )
}

rbmi_vars <- function() {
  rbmi::set_vars(outcome = "CHANGE", visit = "VISIT", subjid = "PATIENT",
                 group = "THERAPY", covariates = c("BASVAL*VISIT", "THERAPY*VISIT"))
}
