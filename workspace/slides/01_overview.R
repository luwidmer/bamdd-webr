# BAMDD Leiden 2026 slides: 01_overview.R, adapted to run in the browser.
#
# Source: https://github.com/Novartis/bamdd
#   workshops/leiden2026/slides/R/01_overview.R
#
# Copyright (C) Novartis Pharma AG. Licensed under the GNU General Public License
# version 2, as upstream: https://github.com/Novartis/bamdd/blob/main/LICENSE
# (copy in LICENSE-GPL-2). Modified in 2026, as listed below.
#
# Regenerate with: Rscript tools/convert-bamdd-slides.R
#
# What was changed, and why:
#   * here::i_am() and here::here() are replaced by `project_dir`, the session's
#     home directory, which holds data/ and stan/ as the upstream project root does.
#   * library(tidyverse) becomes its core packages bar lubridate, which is unused;
#     the meta-package itself and its other dependencies are not in the library.
#   * library(latex2exp) and library(here) are dropped: neither is used.
#   * library(dqrng) is dropped: dqrng is AGPL-3, which this site does not ship.
#   * library(stanliWebR) is added, so every model is sampled by stanli.
#   * library(miraiWebR), daemons(4) and options(mc.cores = 4) are added: four webR
#     workers, one per chain.
#
# Everything else, including every model and its sampler settings, is upstream's
# code unchanged. The knitr chunk markers (## ----) are kept as comments.


# The project root, where data/ and stan/ live: the session's home directory.
project_dir <- "~"

library(knitr)
# The tidyverse packages these slides use, attached as library(tidyverse) would.
library(ggplot2)
library(dplyr)
library(tidyr)
library(readr)
library(purrr)
library(tibble)
library(stringr)
library(forcats)
library(ggrepel)
library(patchwork)
library(glue)
library(RBesT)
library(rstan)
library(brms)
library(posterior)
library(tidybayes)
library(bayesplot)
library(gt)
library(ggdist)
library(distributional)
library(mvtnorm)
library(emmeans)
library(simsurv)

# brms, RBesT and rstan's stan_model()/sampling() run on stanli, which interprets
# the Stan programs -- there is no C++ toolchain in the browser.
library(stanliWebR)

# Each chain samples on a webR worker of its own. Needs 5 CPU cores; on fewer, lower
# the number. On a phone there are no workers and the chains run one after another.
library(miraiWebR)
daemons(0)  # so the file can be run again
daemons(4)
options(mc.cores = 4)

## data {
##   int<lower=0> N;
##   array[N] int<lower=0,upper=1> y;
## }
## parameters {
##   real<lower=0,upper=1> theta;
## }
## model {
##   theta ~ beta(1,1);
##   y ~ bernoulli(theta);
## }

## -----------------------------------------------------------------------------
#| eval: false
#| echo: true
# formula <- y ~ 1 + x + (1 | g)


## -----------------------------------------------------------------------------
#| eval: false
#| echo: true
# formula <- y ~ 1 + x + (1 + x | g)


## -----------------------------------------------------------------------------
#| eval: false
#| echo: true
# formula <- y ~ 1 + gp(x) + (1 + x | g)


## -----------------------------------------------------------------------------
#| eval: false
#| echo: true
# formula <- y ~ 1 + gp(x, k=9) + (1 + x | g)


## -----------------------------------------------------------------------------
#| eval: false
#| echo: true
#| mysize: true
#| size: '\small'
# formula <- bf(
#   y ~ 1 + x + (1 | g) + ...,
#   par2 ~ 1 + x + (1 | g) + ...,
#   par3 ~ 1 + x + (1 | g) + ...,
# )


## -----------------------------------------------------------------------------
#| eval: false
#| echo: true
#| mysize: true
#| size: '\small'
# formula <- bf(
#   y ~ fun(x, nlpar1, nlpar2),
#   nlpar1 ~ 1 + x + (1 | g) + ...,
#   nlpar2 ~ 1 + (1 | g) + ...,
#   nl = TRUE
# )


## -----------------------------------------------------------------------------
#| eval: false
#| echo: true
# family <- brmsfamily(
#     family = "<family>", link = "<link>",
#     more_link_arguments
# )


## -----------------------------------------------------------------------------
#| eval: false
#| echo: true
#| mysize: true
#| size: '\small'
# family <- brmsfamily(family = "gaussian", link = "identity",
#                      link_sigma = "log")


## -----------------------------------------------------------------------------
#| eval: false
#| echo: true
#| mysize: true
#| size: '\small'
# family <- brmsfamily(family = "poisson", link = "log")


## -----------------------------------------------------------------------------
#| eval: false
#| echo: true
# library(brms)
# here::i_am("relative_path_in_project_to/rscript.R")
# 
# options(
#   # how many processor cores would you like to use?
#   mc.cores = 4,
#   # how would you like to access Stan?
#   brms.backend = "cmdstanr",
#   # cache model binaries
#   cmdstanr_write_stan_file_dir = here::here("_brms-cache"),
#   # no need to normalize likelihoods
#   brms.normalize = FALSE
# )
# # create cache directory if not yet available
# dir.create(here::here("_brms-cache"), FALSE)

