# Stan in the browser via stanli itself, with no wrapper package in between.
#
# brms and rbmi reach the same interpreter through stanliWebR. This example drives
# the stanli package directly. Everything is local: the Stan compiler is
# JavaScript and the sampler is a WebAssembly runtime shipped inside the package.
#
# Eight schools in its usual non-centred form.

# Pre-installed in the mounted library; attach it explicitly as in any R session.
library(stanli)

code <- "
data {
  int<lower=0> J;
  vector[J] y;
  vector<lower=0>[J] sigma;
}
parameters {
  real mu;
  real<lower=0> tau;
  vector[J] theta_raw;
}
transformed parameters {
  vector[J] theta = mu + tau * theta_raw;
}
model {
  mu ~ normal(0, 5);
  tau ~ cauchy(0, 5);
  theta_raw ~ std_normal();
  y ~ normal(theta, sigma);
}
"

schools <- list(
  J = 8L,
  y = c(28, 8, -3, 7, -1, 1, 18, 12),
  sigma = c(15, 10, 16, 11, 9, 11, 10, 18)
)

# Transpiles the Stan code; nothing is compiled, so this returns immediately.
mod <- stanli_model(code = code, data = schools)

fit <- sample_model(mod, chains = 2, warmup = 500, samples = 1000, seed = 123)

summary(fit)

# Chains run one after another here: this R session is single-threaded.
get_elapsed_time(fit)

# Draws come back as a named list, one array per parameter.
draws <- extract(fit)
hist(draws$tau, breaks = 40, main = "Posterior of tau", xlab = "tau")

# as_rfit() presents the same fit through RStan's interface, so anything that
# expects a stanfit -- bayesplot, posterior, your own code -- works unchanged.
rfit <- as_rfit(fit)
round(rstan::summary(rfit)$summary[c("mu", "tau"), c("mean", "sd", "n_eff", "Rhat")], 2)
