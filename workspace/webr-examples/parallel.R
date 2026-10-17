# Parallel R in the browser: background webR workers with miraiWebR
#
# miraiWebR starts extra R sessions in Web Workers and offers a subset of the
# mirai package's interface on top of them. Each worker is a complete R with the
# same package library, so work sent to them runs in parallel with this console
# and with each other. Workers share no objects or files with the console: pass
# data in, and load packages in the task or with everywhere().
#
# Each worker holds a full R heap, so the number is capped (at most 4, and one core
# is left free). In the phone layout there are no workers: daemons() says so and
# tasks then run here, one at a time.

library(miraiWebR)

daemons(2)
status()

# ---- one task --------------------------------------------------------------------
# mirai() returns at once; m[] waits for the value. Anything the task prints shows
# up in this console, prefixed with the worker's number.
m <- mirai({
  cat("simulating on a worker\n")
  mean(replicate(200, sd(rnorm(n))))
}, n = 1000)
unresolved(m)
m[]

# Errors come back as values rather than stopping the script.
e <- mirai(stop("no luck"))[]
is_mirai_error(e)
e

# ---- many tasks --------------------------------------------------------------------
# One task per element, spread over the workers. x[.flat] collects a vector.
busy <- function(i) {
  t0 <- proc.time()[["elapsed"]]
  while (proc.time()[["elapsed"]] - t0 < 1) NULL
  Sys.getenv("MIRAI_WEBR_WORKER")
}
system.time(workers <- mirai_map(1:4, busy)[.flat])
workers  # which worker ran each element

# Random numbers: every task draws from its own L'Ecuyer-CMRG stream, so with a
# seed the results do not depend on which worker ran what.
daemons(0)
daemons(2, seed = 2025)
mirai_map(1:3, function(i) runif(1))[.flat]

# ---- set the workers up once ----------------------------------------------------
everywhere({
  library(stats)
  inv_logit <- function(x) 1 / (1 + exp(-x))
})
mirai_map(c(-2, 0, 2), function(x) inv_logit(x))[.flat]

# ---- parallel MCMC chains -------------------------------------------------------
# With workers running, cores > 1 samples each chain on a worker of its own. Chain 1
# is the same as in a sequential fit; the others use different seeds, so the fit is
# reproducible but not identical to cores = 1.
library(stanliWebR)
library(brms)
fit <- brm(count ~ zAge + zBase * Trt + (1 | patient), data = epilepsy,
           family = poisson(), chains = 4, cores = 2, seed = 1, refresh = 0)
fixef(fit)
rstan::get_elapsed_time(fit$fit)

# ---- the future ecosystem -------------------------------------------------------
# plan(webr_workers) uses the same workers for future, future.apply, furrr, ...
library(future)
plan(miraiWebR::webr_workers)
future.apply::future_sapply(1:4, function(i) i^2)
plan(sequential)

daemons(0)
