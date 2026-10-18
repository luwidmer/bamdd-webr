# Bit-wise exact reproducibility, demonstrated.
#
# Each computation below runs twice with the same seed, and the two results must be
# identical() -- not just close. Then the raw IEEE-754 bytes of every number are
# hashed, and the hashes must equal the ones recorded at the bottom of this file.
#
# Those recorded hashes are the stronger claim. Everything here runs on one
# WebAssembly build of R and of the Stan interpreter, single-threaded, and wasm
# floating point is deterministic, so any browser on any system should produce the
# same bytes. Verified so far in Chrome and Edge on macOS; if your browser or system
# disagrees, the script stops and says which part differs.
#
# The hashes belong to the package versions printed below. Upgrading R, stanli,
# stanliWebR, brms or rbmi is expected to change them; re-run this script and copy the
# new values into `expected` (README, "Updating dependencies").
#
# Expect about half a minute: brms and rbmi each fit their model twice.

library(stanli)
library(brms)
library(rbmi)
library(stanliWebR)   # makes brms and rbmi sample with stanli
library(dplyr)

# SHA-256 of the numbers themselves, as little-endian doubles, so nothing about R's
# serialisation format can change the hash. The first 16 hex digits are plenty.
fingerprint <- function(x) {
  bytes <- writeBin(as.double(unlist(x, use.names = FALSE)), raw(), endian = "little")
  substr(digest::digest(bytes, algo = "sha256", serialize = FALSE), 1L, 16L)
}

# Run a computation twice and insist on identical results.
twice <- function(label, f) {
  first <- f()
  second <- f()
  if (!identical(first, second)) stop(label, ": two runs with the same seed differ.")
  cat(sprintf("%-8s identical across two runs (%d numbers)\n", label, length(first)))
  first
}

results <- list()

# ---- base R ---------------------------------------------------------------------
# Uniforms are pure integer arithmetic in Mersenne-Twister, so this hash also matches
# native R on any laptop. Normals go through log() and sqrt() from the platform's maths
# library, and native builds differ from each other in the last bit (native R 4.6.1 on
# Apple silicon gives 7dd81b709df58c3f). Every copy of this WebAssembly build agrees.
results$runif <- twice("runif", function() {
  set.seed(2026)
  runif(1e5)
})
results$rnorm <- twice("rnorm", function() {
  set.seed(2026)
  rnorm(1e5)
})

# ---- stanli: eight schools ---------------------------------------------------------
schools_code <- "
data { int<lower=0> J; vector[J] y; vector<lower=0>[J] sigma; }
parameters { real mu; real<lower=0> tau; vector[J] theta_raw; }
transformed parameters { vector[J] theta = mu + tau * theta_raw; }
model {
  mu ~ normal(0, 5);
  tau ~ cauchy(0, 5);
  theta_raw ~ std_normal();
  y ~ normal(theta, sigma);
}
"
schools <- list(J = 8L, y = c(28, 8, -3, 7, -1, 1, 18, 12), sigma = c(15, 10, 16, 11, 9, 11, 10, 18))

# stanli also draws from R's own generator, so its `seed` argument alone is not
# enough: two runs with seed = 123 but different R RNG states differ completely.
results$stanli <- twice("stanli", function() {
  set.seed(123)
  mod <- stanli_model(code = schools_code, data = schools)
  invisible(capture.output(fit <- sample_model(mod, chains = 2, warmup = 500, samples = 1000, seed = 123)))
  unlist(extract(fit))
})

# ---- brms, sampled by stanli --------------------------------------------------------
# stanliWebR seeds R's generator from brm(seed = ) itself, as stanli needs.
results$brms <- twice("brms", function() {
  fit <- brm(time ~ age * sex, data = kidney,
             chains = 2, iter = 1000, seed = 1234, refresh = 0, silent = 2)
  as.vector(as.matrix(fit))
})

# ---- rbmi: Bayesian multiple imputation, sampled by stanli ------------------------
# The quickstart's data and strategy with small settings: the point is reproducibility,
# not the analysis.
dat <- expand_locf(
  antidepressant_data,
  PATIENT = levels(antidepressant_data$PATIENT),
  VISIT = levels(antidepressant_data$VISIT),
  vars = c("BASVAL", "THERAPY"),
  group = c("PATIENT"),
  order = c("PATIENT", "VISIT")
)
dat_ice <- dat %>%
  arrange(PATIENT, VISIT) %>%
  filter(is.na(CHANGE)) %>%
  group_by(PATIENT) %>%
  slice(1) %>%
  ungroup() %>%
  select(PATIENT, VISIT) %>%
  mutate(strategy = "JR") %>%
  filter(PATIENT != 3618)
vars <- set_vars(outcome = "CHANGE", visit = "VISIT", subjid = "PATIENT", group = "THERAPY",
                 covariates = c("BASVAL*VISIT", "THERAPY*VISIT"))
ana_vars <- set_vars(outcome = "CHANGE", visit = "VISIT", subjid = "PATIENT", group = "THERAPY",
                     covariates = "BASVAL")

results$rbmi <- twice("rbmi", function() {
  set.seed(987)
  method <- method_bayes(n_samples = 20, control = control_bayes(warmup = 100, thin = 1, seed = 1821))
  draws_obj <- draws(data = dat, data_ice = dat_ice, vars = vars, method = method, quiet = TRUE)
  impute_obj <- impute(draws_obj, references = c("DRUG" = "PLACEBO", "PLACEBO" = "PLACEBO"))
  pooled <- as.data.frame(pool(analyse(impute_obj, ancova, vars = ana_vars)))
  c(
    unlist(lapply(draws_obj$samples, function(s) c(s$beta, unlist(s$sigma)))),
    unlist(lapply(extract_imputed_dfs(impute_obj), `[[`, "CHANGE")),
    unlist(pooled[vapply(pooled, is.numeric, logical(1))])
  )
})

# ---- the reference -----------------------------------------------------------------
cat("\nR", paste(R.version$major, R.version$minor, sep = "."),
    "| webr", format(packageVersion("webr")),
    "| stanli", format(packageVersion("stanli")),
    "| stanliWebR", format(packageVersion("stanliWebR")),
    "| brms", format(packageVersion("brms")),
    "| rbmi", format(packageVersion("rbmi")), "\n\n")

expected <- c(
  runif  = "70586c57b011b6ca",
  rnorm  = "f7ab8b90c877d416",
  stanli = "a4dfe4de2ebc7af2",
  brms   = "e87fd58366178dd9",
  rbmi   = "aaf3cd0e2b738136"
)

got <- vapply(results, fingerprint, character(1))
report <- data.frame(fingerprint = got, expected = expected[names(got)],
                     match = got == expected[names(got)])
print(report)

if (!all(report$match)) {
  differ <- rownames(report)[!report$match]
  stop("Not bit-identical to the reference build: ",
       paste0(differ, " = \"", report$fingerprint[!report$match], "\"", collapse = ", "),
       call. = FALSE)
}
cat("\nBit-identical to the reference build.\n")
