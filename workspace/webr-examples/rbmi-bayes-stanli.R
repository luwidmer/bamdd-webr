# The rbmi quickstart vignette, run in the browser.
#
# This is the code from `vignette("quickstart", package = "rbmi")` verbatim. The only
# addition is library(stanliWebR).
#
# rbmi::method_bayes() renders a Stan program at runtime and hands it to
# rstan::stan_model(), which shells out to a C++ compiler. There is none in
# WebAssembly, so the call fails with
#
#     Error in webr_hook_system(command) :
#       The `system()` function is unsupported under Emscripten.
#
# stanli interprets Stan rather than compiling it, so the program rbmi generates runs
# unchanged -- only the calls around it have to move off rstan. That is what stanliWebR
# does: loading it swaps out the two rbmi internals that compile and sample, and
# method_bayes() then works as it does anywhere else. See ?use_stanli_for_rbmi.
#
# The vignette's settings are kept as written: 200 warmup plus 150 samples thinned by 5
# is 950 interpreted iterations, so expect this to take considerably longer here than
# the other examples.

library(rbmi)
library(stanliWebR)
library(dplyr)

data("antidepressant_data")
dat <- antidepressant_data

# Use expand_locf to add rows corresponding to visits with missing outcomes to the dataset
dat <- expand_locf(
    dat,
    PATIENT = levels(dat$PATIENT), # expand by PATIENT and VISIT
    VISIT = levels(dat$VISIT),
    vars = c("BASVAL", "THERAPY"), # fill with LOCF BASVAL and THERAPY
    group = c("PATIENT"),
    order = c("PATIENT", "VISIT")
)

# create data_ice and set the imputation strategy to JR for
# each patient with at least one missing observation
dat_ice <- dat %>%
    arrange(PATIENT, VISIT) %>%
    filter(is.na(CHANGE)) %>%
    group_by(PATIENT) %>%
    slice(1) %>%
    ungroup() %>%
    select(PATIENT, VISIT) %>%
    mutate(strategy = "JR")

# In this dataset, subject 3618 has an intermittent missing values which does not correspond
# to a study drug discontinuation. We therefore remove this subject from `dat_ice`.
# (In the later imputation step, it will automatically be imputed under the default MAR assumption.)
dat_ice <- dat_ice[-which(dat_ice$PATIENT == 3618),]

dat_ice

# Define the names of key variables in our dataset and
# the covariates included in the imputation model using `set_vars()`
# Note that the covariates argument can also include interaction terms
vars <- set_vars(
    outcome = "CHANGE",
    visit = "VISIT",
    subjid = "PATIENT",
    group = "THERAPY",
    covariates = c("BASVAL*VISIT", "THERAPY*VISIT")
)

# Define which imputation method to use (here: Bayesian multiple imputation with 150 imputed datsets)
method <- method_bayes(
    n_samples = 150,
    control = control_bayes(
        warmup = 200,
        thin = 5,
        seed = 1821 # Seed to be used by Stan
    )
)

# Create samples for the imputation parameters by running the draws() function
set.seed(987)
drawObj <- draws(
    data = dat,
    data_ice = dat_ice,
    vars = vars,
    method = method,
    quiet = TRUE
)
drawObj

imputeObj <- impute(
    drawObj,
    references = c("DRUG" = "PLACEBO", "PLACEBO" = "PLACEBO")
)
imputeObj

imputed_dfs <- extract_imputed_dfs(imputeObj)
head(imputed_dfs[[10]], 12) # first 12 rows of 10th imputed dataset

anaObj <- analyse(
    imputeObj,
    ancova,
    vars = set_vars(
        subjid = "PATIENT",
        outcome = "CHANGE",
        visit = "VISIT",
        group = "THERAPY",
        covariates = c("BASVAL")
    )
)
anaObj

# For reference show the additional meta variables provided
delta_template(imputeObj) %>% as_tibble()

delta_df <- delta_template(imputeObj) %>%
    as_tibble() %>%
    mutate(delta = if_else(THERAPY == "DRUG" & is_missing , 5, 0)) %>%
    select(PATIENT, VISIT, delta)

delta_df

anaObj_delta <- analyse(
    imputeObj,
    ancova,
    delta = delta_df,
    vars = set_vars(
        subjid = "PATIENT",
        outcome = "CHANGE",
        visit = "VISIT",
        group = "THERAPY",
        covariates = c("BASVAL")
    )
)

poolObj <- pool(
    anaObj,
    conf.level = 0.95,
    alternative = "two.sided"
)
poolObj

as.data.frame(poolObj)
