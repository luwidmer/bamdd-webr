#!/usr/bin/env Rscript
#
# Convert the Novartis bamdd Leiden 2026 workshop exercises to run in this browser
# session, and write the result to workspace/bamdd_leiden2026_exercises.R.
#
#   Rscript tools/convert-bamdd.R
#
# The upstream file targets a desktop R with cmdstanr and a C++ toolchain. Here there
# is no compiler and sampling goes through stanli, but RBesT is in the mounted library
# and its analyses are kept as upstream wrote them.
#
# Every substitution below is asserted to match exactly once. If upstream changes the
# file, this script stops rather than emitting a silently mangled exercise.

options(warn = 1)
options(timeout = max(600L, getOption("timeout")))

die <- function(...) stop("\n[convert-bamdd] ", ..., call. = FALSE)
say <- function(...) cat("[convert-bamdd]", ..., "\n", sep = " ")

UPSTREAM <- paste0(
  "https://raw.githubusercontent.com/Novartis/bamdd/refs/heads/main/",
  "workshops/leiden2026/exercises/bamdd_leiden2026_exercises.R"
)

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
root <- if (length(script_arg) == 1L) {
  dirname(dirname(normalizePath(sub("^--file=", "", script_arg))))
} else {
  normalizePath(getwd())
}

cache <- file.path(root, "vendor", "bamdd_leiden2026_exercises.R")
out <- file.path(root, "workspace", "bamdd_leiden2026_exercises.R")

if (!file.exists(cache)) {
  dir.create(dirname(cache), recursive = TRUE, showWarnings = FALSE)
  say("Downloading upstream exercises")
  if (!identical(as.integer(utils::download.file(UPSTREAM, cache, quiet = TRUE)), 0L)) {
    die("Could not download ", UPSTREAM)
  }
}
src <- paste(readLines(cache, warn = FALSE), collapse = "\n")
say("Read", length(strsplit(src, "\n")[[1]]), "lines")

## --------------------------------------------------------------- substitutions

sub_once <- function(text, pattern, replacement, label) {
  hits <- gregexpr(pattern, text, fixed = TRUE)[[1]]
  n <- if (hits[1L] == -1L) 0L else length(hits)
  if (n != 1L) {
    die("Substitution '", label, "' matched ", n, " times, expected exactly 1.\n",
        "Upstream has changed; review tools/convert-bamdd.R.")
  }
  sub(pattern, replacement, text, fixed = TRUE)
}

# 1. Drop the install/toolchain preamble; start at the library block.
start <- regexpr("library(here)", src, fixed = TRUE)
if (start == -1L) die("Could not find the library() block.")
src <- substring(src, start)

# 2. here is only used for cache paths and i_am(); neither applies here.
src <- sub_once(src, "library(here)\n", "", "drop library(here)")

# 3. Backend: no compiler here; chains sample in parallel on webR workers.
old_options <- 'options(
  # how many processor cores would you like to use?
  mc.cores = 4, 
  # how would you like to access Stan?
  brms.backend = "cmdstanr",
  # cache model binaries
  cmdstanr_write_stan_file_dir=here::here("_brms-cache"),
  # no need to normalize likelihoods
  brms.normalize = FALSE
)

dir.create(here::here("_brms-cache"), FALSE)'
new_options <- '# brms keeps its default rstan backend; stanliWebR runs it on stanli, which
# interprets the Stan program -- there is no C++ toolchain in the browser.
library(stanliWebR)

# Each chain samples on a webR worker of its own. Needs 5 CPU cores; on fewer, lower
# the number. On a phone there are no workers and the chains run one after another.
library(miraiWebR)
daemons(0)  # so the file can be run again
daemons(4)

options(
  # how many processor cores would you like to use?
  mc.cores = 4,
  # no need to normalize likelihoods
  brms.normalize = FALSE
)'
src <- sub_once(src, old_options, new_options, "options block -> stanliWebR")

# 4. here::i_am() calls sit above the library block and are removed by the truncation
# in step 1, so nothing to do here.

## --------------------------------------------------------------------- header

header <- c(
  "# Novartis bamdd workshop exercises (Leiden 2026), adapted to run in the browser.",
  "#",
  "# Source: https://github.com/Novartis/bamdd",
  "#   workshops/leiden2026/exercises/bamdd_leiden2026_exercises.R",
  "#",
  "# Copyright (C) Novartis Pharma AG. Licensed under the GNU General Public License",
  "# version 2, as upstream: https://github.com/Novartis/bamdd/blob/main/LICENSE",
  "# (copy in LICENSE-GPL-2). Modified in 2026, as listed below.",
  "#",
  "# Regenerate with: Rscript tools/convert-bamdd.R",
  "#",
  "# What was changed, and why:",
  "#   * backend cmdstanr -> rstan, run on stanli by library(stanliWebR). There is no",
  "#     C++ toolchain here; stanli interprets the Stan program that brms generates.",
  "#   * library(miraiWebR) and daemons(4): four webR workers, one per chain.",
  "#   * the install/toolchain preamble and here::i_am() project anchoring are dropped.",
  "#",
  "# Everything else, including all brms models, is upstream's code unchanged.",
  "# These models are slower than the toy examples: expect minutes, not seconds.",
  "",
  ""
)

dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
writeLines(c(header, src), out)

n_out <- length(readLines(out, warn = FALSE))
say("Wrote", out, "-", n_out, "lines")

leftovers <- grep("cmdstanr|here::", readLines(out, warn = FALSE), value = TRUE)
leftovers <- grep("^#", leftovers, value = TRUE, invert = TRUE)
if (length(leftovers)) {
  say("NOTE: remaining references to removed tooling (check these are inside comments):")
  cat(paste0("  ", leftovers), sep = "\n")
}
