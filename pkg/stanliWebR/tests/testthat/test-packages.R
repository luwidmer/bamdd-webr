# Whole models through each patched package: slow, so only with tools/test-packages.mjs
# --full (NOT_CRAN=true).

test_that("brms samples with stanli, keeps the model and refreshes it", {
  skip_on_cran()
  skip_if_not_installed("brms")
  fit <- brms::brm(time ~ age + (1 | patient), data = brms::kidney, chains = 2, iter = 400,
                   seed = 1, refresh = 0, silent = 2, save_pars = brms::save_pars(all = TRUE))
  expect_s3_class(fit, "brmsfit")
  expect_identical(fit$backend, "stanli")
  expect_true(any(grepl("^z_", brms::variables(fit))))
  expect_identical(fit$fit@stan_args[[1]]$sampler_t, "NUTS(diag_e)")
  expect_true(is.finite(suppressMessages(brms::bridge_sampler(fit, silent = TRUE))$logml))
  again <- update(fit, iter = 300, refresh = 0, silent = 2, seed = 2)
  expect_s3_class(again, "brmsfit")
})

test_that("brms builds its stanli model in fast mode when asked", {
  skip_on_cran()
  skip_if_not_installed("brms")
  withr::local_options(stanliWebR.fast_math = TRUE)
  fit <- brms::brm(y ~ 1, data = data.frame(y = c(-1, 0.5, 2)), chains = 1, iter = 200,
                   seed = 1, refresh = 0, silent = 2)
  expect_true(fit$fit@.MISC$stanli_model$fast_math)
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
  # stanli 0.24.0 lost their transformed parameters and generated quantities;
  # 0.25.0 computes them. Record whether stanliWebR refused the model.
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

test_that("a precompiled model stanli cannot fully compute stops, without rstan", {
  err <- structure(class = c("stanliWebR_incomplete_model", "error", "condition"),
                   list(message = "incomplete", call = NULL))
  local_mocked_bindings(stanli_model_complete = function(...) stop(err), .package = "stanliWebR")
  compiled <- methods::new("stanmodel", model_name = "normal", model_code = normal_code)
  expect_error(stanliWebR:::stanli_sampling(compiled, data = normal_data, chains = 1, iter = 100,
                                            seed = 1, refresh = 0),
               class = "stanliWebR_incomplete_model")
})

test_that("rbmi's Bayesian imputation samples with stanli", {
  skip_on_cran()
  skip_if_not_installed("rbmi")
  for (same_cov in c(TRUE, FALSE)) {
    method <- rbmi::method_bayes(n_samples = 10, same_cov = same_cov,
                                 control = rbmi::control_bayes(warmup = 100, thin = 2, seed = 5))
    d <- rbmi::draws(data = rbmi_data(), vars = rbmi_vars(), method = method, quiet = TRUE)
    expect_s3_class(d, "draws")
  }
})

test_that("rbmi's AR(1) and CS models sample with init = \"mmrm\"", {
  skip_on_cran()
  skip_if_not_installed("rbmi")
  for (covariance in c("ar1", "cs")) {
    for (same_cov in c(TRUE, FALSE)) {
      method <- rbmi::method_bayes(
        n_samples = 10, covariance = covariance, same_cov = same_cov,
        control = rbmi::control_bayes(warmup = 100, thin = 2, seed = 5, init = "mmrm")
      )
      d <- rbmi::draws(data = rbmi_data(), vars = rbmi_vars(), method = method, quiet = TRUE)
      expect_s3_class(d, "draws")
    }
  }
})

test_that("every MMRM estimate reaches stanli once rbmi passes them in Stan's shapes", {
  skip_on_cran()
  # openpharma/rbmi#609; earlier versions pass lists, which are ignored as rstan ignores them.
  skip_if_not_installed("rbmi", "1.7.1.9000")
  given <- list()
  unconstrain <- stanli::unconstrain
  local_mocked_bindings(
    unconstrain = function(model, values, ...) {
      given[[length(given) + 1L]] <<- names(values)
      unconstrain(model, values, ...)
    },
    .package = "stanli"
  )
  expected <- list(c("ar1", "default", "theta var_const rho"), c("us", "default", "theta Sigma"),
                   c("us", "lkj", "theta vars corr_chol"))
  for (e in expected) {
    given <- list()
    method <- rbmi::method_bayes(
      n_samples = 10, covariance = e[1], prior_cov = e[2], same_cov = FALSE,
      control = rbmi::control_bayes(warmup = 50, thin = 1, seed = 5, init = "mmrm")
    )
    suppressWarnings(rbmi::draws(data = rbmi_data(), vars = rbmi_vars(), method = method, quiet = TRUE))
    expect_identical(paste(given[[1]], collapse = " "), e[3], label = paste(e[1:2], collapse = "/"))
  }
})

test_that("rbmi's sampler settings reach stanli", {
  skip_on_cran()
  skip_if_not_installed("rbmi")
  method <- rbmi::method_bayes(n_samples = 10, control = rbmi::control_bayes(
    warmup = 100, thin = 2, seed = 5, control = list(adapt_delta = 0.95, max_treedepth = 12)
  ))
  d <- rbmi::draws(data = rbmi_data(), vars = rbmi_vars(), method = method, quiet = TRUE)
  args <- d$fit@stan_args[[1]]
  expect_identical(args$control$adapt_delta, 0.95)
  expect_identical(args$control$max_treedepth, 12)
})

test_that("rbmi settings stanli cannot honour are refused", {
  skip_if_not_installed("rbmi")
  refused <- function(control) {
    method <- rbmi::method_bayes(n_samples = 10, control = control)
    rbmi::draws(data = rbmi_data(), vars = rbmi_vars(), method = method, quiet = TRUE)
  }
  expect_error(refused(rbmi::control_bayes(control = list(adapt_gamma = 0.1))), "adapt_gamma")
  expect_error(refused(rbmi::control_bayes(cores = 2)), "not supported by stanli: cores")
})
