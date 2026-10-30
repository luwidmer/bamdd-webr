# Whole models through each patched package: slow, so only with tools/test-packages.mjs
# --full (NOT_CRAN=true).

test_that("brms samples with stanli, keeps the model and refreshes it", {
  skip_on_cran()
  skip_if_not_installed("brms")
  fit <- brms::brm(time ~ age + (1 | patient), data = brms::kidney, chains = 2, iter = 400,
                   seed = 1, refresh = 0, silent = 2, save_pars = brms::save_pars(all = TRUE))
  expect_s3_class(fit, "brmsfit")
  expect_true(any(grepl("^z_", brms::variables(fit))))
  expect_identical(fit$fit@stan_args[[1]]$sampler_t, "NUTS(diag_e)")
  expect_true(is.finite(suppressMessages(brms::bridge_sampler(fit, silent = TRUE))$logml))
  again <- update(fit, iter = 300, refresh = 0, silent = 2, seed = 2)
  expect_s3_class(again, "brmsfit")
})

test_that("RBesT's gMAP() samples with stanli", {
  skip_on_cran()
  skip_if_not_installed("RBesT")
  map <- RBesT::gMAP(cbind(r, n - r) ~ 1 | study, data = RBesT::AS, family = binomial,
                     tau.dist = "HalfNormal", tau.prior = 1, beta.prior = 2,
                     chains = 2, iter = 600, warmup = 300)
  expect_s3_class(map, "gMAP")
})

test_that("OncoBayes2's program runs on stanli unmodified", {
  skip_on_cran()
  skip_if_not_installed("OncoBayes2")
  # example_model() runs code that expects the package attached.
  withr::local_package("OncoBayes2")
  fit <- suppressWarnings(OncoBayes2::example_model("single_agent", silent = TRUE))
  expect_s3_class(fit$blrmfit, "blrmfit")
})

test_that("OncoBayes2's combination models sample on stanli with all their outputs", {
  skip_on_cran()
  skip_if_not_installed("OncoBayes2")
  withr::local_package("OncoBayes2")
  # stanli 0.24.0 lost their transformed parameters and generated quantities, which
  # sent them to rstan's compiled model, or in webR stopped them; 0.25.0 computes them.
  # The fallback would produce the same variables, so record whether it was taken.
  refused <- FALSE
  complete <- stanliWebR:::stanli_model_complete
  local_mocked_bindings(
    stanli_model_complete = function(...) {
      withCallingHandlers(complete(...), stanliWebR_incomplete_model = function(e) refused <<- TRUE)
    },
    .package = "stanliWebR"
  )
  combo3 <- suppressWarnings(OncoBayes2::example_model("combo3", silent = TRUE))
  expect_false(refused)
  vars <- posterior::variables(combo3$blrmfit$draws)
  expect_true(any(startsWith(vars, "tau_log_beta[")))
  expect_true(any(startsWith(vars, "beta_group[")))
})

test_that("a program stanli cannot fully compute stops rather than losing outputs", {
  err <- structure(class = c("stanliWebR_incomplete_model", "error", "condition"),
                   list(message = "incomplete", call = NULL))
  local_mocked_bindings(stanli_model_complete = function(...) stop(err), .package = "stanliWebR")
  m <- rstan::stan_model(model_code = normal_code)
  expect_error(quiet_sampling(m, chains = 1, iter = 100, seed = 1), class = "stanliWebR_incomplete_model")
})

test_that("rbmi's Bayesian imputation samples with stanli", {
  skip_on_cran()
  skip_if_not_installed("rbmi")
  dat <- rbmi::antidepressant_data
  dat <- rbmi::expand_locf(
    dat, PATIENT = levels(dat$PATIENT), VISIT = levels(dat$VISIT),
    vars = c("BASVAL", "THERAPY"), group = "PATIENT", order = c("PATIENT", "VISIT")
  )
  vars <- rbmi::set_vars(outcome = "CHANGE", visit = "VISIT", subjid = "PATIENT",
                         group = "THERAPY", covariates = c("BASVAL*VISIT", "THERAPY*VISIT"))
  for (same_cov in c(TRUE, FALSE)) {
    method <- rbmi::method_bayes(n_samples = 10, same_cov = same_cov,
                                 control = rbmi::control_bayes(warmup = 100, thin = 2, seed = 5))
    d <- rbmi::draws(data = dat, vars = vars, method = method, quiet = TRUE)
    expect_s3_class(d, "draws")
  }
})
