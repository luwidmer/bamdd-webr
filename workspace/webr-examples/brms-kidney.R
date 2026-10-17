# brms running entirely in your browser.
#
# There is no C++ toolchain here: the model is sampled by stanli, an interpreter for
# Stan, which stanliWebR plugs in under brms's default rstan backend. Nothing is sent
# to a server.
#
# Two caveats specific to WebAssembly:
#   * chains run one after another, because this R session is single-threaded
#   * memory is 32-bit, so keep models modest
#
# Press "Run all", or put the cursor on a line and press Cmd/Ctrl+Enter.

# Everything is already installed in the mounted library; nothing is downloaded.
# The session does not pre-load anything, so attach the packages yourself:
library(brms)
library(stanliWebR)   # makes brms sample with stanli

fit <- brm(
  time ~ age * sex,
  data = kidney,
  chains = 2,
  iter = 1000,
  seed = 1234
)

summary(fit)

plot(fit)
