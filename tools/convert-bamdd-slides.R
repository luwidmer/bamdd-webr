#!/usr/bin/env Rscript
#
# Convert the R code of the Novartis bamdd Leiden 2026 slides to run in this browser
# session. The scripts go to workspace/slides/, and the data and Stan files they read
# to workspace/data/ and workspace/stan/, as at the root of the upstream workshop.
#
#   Rscript tools/convert-bamdd-slides.R
#
# Every substitution is asserted to match exactly once. If upstream changes, this
# script stops rather than emitting silently mangled code.

options(warn = 1)
options(timeout = max(600L, getOption("timeout")))

die <- function(...) stop("\n[convert-bamdd-slides] ", ..., call. = FALSE)
say <- function(...) cat("[convert-bamdd-slides]", ..., "\n", sep = " ")

UPSTREAM <- paste0(
  "https://raw.githubusercontent.com/Novartis/bamdd/refs/heads/main/",
  "workshops/leiden2026/"
)
SCRIPTS <- c(
  "01_overview", "02_hist_control", "03_priors", "03b_prior_example_blrm",
  "04_dose_finding", "05_mmrm", "06_longitudinal_data", "07_time_to_event"
)
FILES <- c(
  file.path("slides", "R", paste0(SCRIPTS, ".R")),
  "data/longitudinal.csv",
  "stan/conflict_normal_student-t.stan"
)
# The session's home directory, where installExamples() in js/session.js puts
# workspace/; it plays the part of the upstream project root.
SESSION_DIR <- "~"

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
root <- if (length(script_arg) == 1L) {
  dirname(dirname(normalizePath(sub("^--file=", "", script_arg))))
} else {
  normalizePath(getwd())
}
cache <- file.path(root, "vendor", "bamdd-leiden2026")
out <- file.path(root, "workspace")

for (f in FILES) {
  local <- file.path(cache, sub("^slides/", "", f))
  if (file.exists(local)) next
  dir.create(dirname(local), recursive = TRUE, showWarnings = FALSE)
  say("Downloading", f)
  if (!identical(as.integer(utils::download.file(paste0(UPSTREAM, f), local, quiet = TRUE)), 0L)) {
    die("Could not download ", f)
  }
}

sub_once <- function(text, pattern, replacement, label) {
  hits <- gregexpr(pattern, text, fixed = TRUE)[[1]]
  n <- if (hits[1L] == -1L) 0L else length(hits)
  if (n != 1L) {
    die("Substitution '", label, "' matched ", n, " times, expected exactly 1.\n",
        "Upstream has changed; review tools/convert-bamdd-slides.R.")
  }
  sub(pattern, replacement, text, fixed = TRUE)
}

# Every script opens with the same anchor and package block.
upstream_block <- function(script) paste0(
  'here::i_am("slides/R/', script, '.R")\n\n',
  "library(here)\nlibrary(knitr)\nlibrary(tidyverse)\nlibrary(ggrepel)\nlibrary(latex2exp)\n",
  "library(patchwork)\nlibrary(glue)\nlibrary(RBesT)\nlibrary(rstan)\nlibrary(brms)\n",
  "library(posterior)\nlibrary(tidybayes)\nlibrary(bayesplot)\nlibrary(gt)\nlibrary(ggdist)\n",
  "library(distributional)\nlibrary(mvtnorm)\nlibrary(dqrng)\nlibrary(emmeans)\nlibrary(simsurv)\n"
)

browser_block <- paste0(
  "# The project root, where data/ and stan/ live: the session's home directory.\n",
  'project_dir <- "', SESSION_DIR, '"\n\n',
  "library(knitr)\n",
  "# The tidyverse packages these slides use, attached as library(tidyverse) would.\n",
  "library(ggplot2)\nlibrary(dplyr)\nlibrary(tidyr)\nlibrary(readr)\nlibrary(purrr)\n",
  "library(tibble)\nlibrary(stringr)\nlibrary(forcats)\n",
  "library(ggrepel)\nlibrary(patchwork)\nlibrary(glue)\nlibrary(RBesT)\nlibrary(rstan)\n",
  "library(brms)\nlibrary(posterior)\nlibrary(tidybayes)\nlibrary(bayesplot)\nlibrary(gt)\n",
  "library(ggdist)\nlibrary(distributional)\nlibrary(mvtnorm)\n",
  "library(emmeans)\nlibrary(simsurv)\n\n",
  "# brms, RBesT and rstan's stan_model()/sampling() run on stanli, which interprets\n",
  "# the Stan programs -- there is no C++ toolchain in the browser.\n",
  "library(stanliWebR)\n\n",
  "# Each chain samples on a webR worker of its own. Needs 5 CPU cores; on fewer, lower\n",
  "# the number. On a phone there are no workers and the chains run one after another.\n",
  "library(miraiWebR)\n",
  "daemons(0)  # so the file can be run again\n",
  "daemons(4)\n",
  "options(mc.cores = 4)\n"
)

# The slides call gt_format() but define it only in their Quarto source; this
# is the definition from the bamdd Goettingen 2024 slides (02_hist_control.R).
gt_format_def <- paste0(
  "\n# Table formatting helper, as defined in the bamdd Goettingen 2024 slides.\n",
  "gt_format <- function(x, decimals = 2) {\n",
  "  x |> fmt_number(decimals = decimals)\n",
  "}\n"
)

edits <- list(
  "02_hist_control" = list(gt_format = TRUE),
  "03_priors" = list(list(
    'stan_model(here::here("stan", "conflict_normal_student-t.stan"))',
    'stan_model(file.path(project_dir, "stan", "conflict_normal_student-t.stan"))'
  )),
  "05_mmrm" = list(dqrng = TRUE, list(
    "TRT01P = dqsample(x = c(0L, 10L, 20L, 40L), size = Nf, replace = T)",
    "TRT01P = sample(x = c(0L, 10L, 20L, 40L), size = Nf, replace = T)"
  ), list(
    # The slide's row numbers fit upstream's dqrng draw; mark each patient's last row.
    "locations = cells_body(rows = c(4, 8, 10)),",
    "locations = cells_body(rows = !duplicated(USUBJID, fromLast = TRUE)),"
  )),
  "06_longitudinal_data" = list(list(
    'readr::read_csv(here::here("data", "longitudinal.csv")',
    'readr::read_csv(file.path(project_dir, "data", "longitudinal.csv")'
  )),
  "07_time_to_event" = list(gt_format = TRUE)
)

header <- function(script) c(
  paste0("# BAMDD Leiden 2026 slides: ", script, ".R, adapted to run in the browser."),
  "#",
  "# Source: https://github.com/Novartis/bamdd",
  paste0("#   workshops/leiden2026/slides/R/", script, ".R"),
  "#",
  "# Copyright (C) Novartis Pharma AG. Licensed under the GNU General Public License",
  "# version 2, as upstream: https://github.com/Novartis/bamdd/blob/main/LICENSE",
  "# (copy in LICENSE-GPL-2). Modified in 2026, as listed below.",
  "#",
  "# Regenerate with: Rscript tools/convert-bamdd-slides.R",
  "#",
  "# What was changed, and why:",
  "#   * here::i_am() and here::here() are replaced by `project_dir`, the session's",
  "#     home directory, which holds data/ and stan/ as the upstream project root does.",
  "#   * library(tidyverse) becomes its core packages bar lubridate, which is unused;",
  "#     the meta-package itself and its other dependencies are not in the library.",
  "#   * library(latex2exp) and library(here) are dropped: neither is used.",
  "#   * library(dqrng) is dropped: dqrng is AGPL-3, which this site does not ship.",
  if ("dqrng" %in% names(edits[[script]])) c(
    "#     dqsample() becomes base sample(), so the simulated trial differs from the",
    "#     one on the slides; the analysis is the same. The example-patient table now",
    "#     finds each patient's last row instead of hard-coding upstream's row numbers."
  ),
  "#   * library(stanliWebR) is added, so every model is sampled by stanli.",
  "#   * library(miraiWebR), daemons(4) and options(mc.cores = 4) are added: four webR",
  "#     workers, one per chain.",
  if ("gt_format" %in% names(edits[[script]]))
    "#   * gt_format() is defined; the slides use it without defining it.",
  "#",
  "# Everything else, including every model and its sampler settings, is upstream's",
  "# code unchanged. The knitr chunk markers (## ----) are kept as comments.",
  "",
  ""
)

dir.create(file.path(out, "slides"), recursive = TRUE, showWarnings = FALSE)
for (script in SCRIPTS) {
  src <- paste(readLines(file.path(cache, "R", paste0(script, ".R")), warn = FALSE), collapse = "\n")
  block <- browser_block
  if (isTRUE(edits[[script]]$gt_format)) block <- paste0(block, gt_format_def)
  src <- sub_once(src, upstream_block(script), block, paste(script, "header"))
  for (e in Filter(is.list, edits[[script]])) {
    src <- sub_once(src, e[[1]], e[[2]], paste(script, e[[1]]))
  }
  # here:: and cmdstanr may remain in comments only (01 shows a desktop setup block).
  code <- sub("#.*$", "", strsplit(src, "\n")[[1]])
  leftover <- grep("here::|tidyverse|latex2exp|cmdstanr|dqrng|dqsample", code, value = TRUE)
  if (length(leftover)) die(script, ": unconverted code remains:\n  ", paste(leftover, collapse = "\n  "))
  writeLines(c(header(script), src), file.path(out, "slides", paste0(script, ".R")))
  say("Wrote", file.path("workspace", "slides", paste0(script, ".R")))
}

for (f in c("data/longitudinal.csv", "stan/conflict_normal_student-t.stan")) {
  dir.create(file.path(out, dirname(f)), recursive = TRUE, showWarnings = FALSE)
  if (!file.copy(file.path(cache, f), file.path(out, f), overwrite = TRUE)) die("Could not copy ", f)
  say("Copied", f)
}
