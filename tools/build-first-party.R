#!/usr/bin/env Rscript
#
# Build the first-party packages in pkg/ (stanliWebR, miraiWebR), and the pure-R
# packages pinned to an upstream commit in UPSTREAM, into build/wasm-extra, ready for
# tools/vendor-wasm-repo.R.
#
# They are pure R, so there is nothing to cross-compile and the host R can build
# them directly -- unlike jinjar and friends, which need tools/build-wasm-pkg.sh and
# the Emscripten image. The one constraint is the R version: webR bundles R 4.6.0, and
# R warns on load about anything built under a newer R, down to the patch level. The
# host is unlikely to be exactly 4.6.0, so the build records the target version the
# way every cross-compiled package in the image does, and refuses to run unless the
# host matches on the minor version, which is what actually governs compatibility.
#
#   Rscript tools/build-first-party.R [package ...]   # default: pkg/* and UPSTREAM
#   Rscript tools/vendor-wasm-repo.R      # fold them into vendor/wasm-repo
#   Rscript tools/build-library.R         # unpack the pinned library
#   Rscript tools/pack-library.R          # rebuild lib/library.tar.gz

options(warn = 1)

die <- function(...) stop("\n[build-first-party] ", ..., call. = FALSE)
say <- function(...) cat("[build-first-party]", ..., "\n", sep = " ")

# MUST match the R that webR bundles, and R_CONTRIB in tools/build-library.R.
R_TARGET <- "4.6.0"

# Pure-R packages built from an upstream commit until a release carries what the image
# needs. rbmi: MMRM starting values in Stan's names and shapes (openpharma/rbmi#609) and
# two-visit correlation priors (#613), from PR #614. lib/TEST-MANIFEST.tsv pins the same
# archive as the package's test source.
UPSTREAM <- list(
  rbmi = list(
    url = "https://github.com/openpharma/rbmi/archive/2d7b92b25a69289c2d297aaf65dee55d8d643c6f.tar.gz",
    sha256 = "1d7e488012927323f71ffc3ef295047af8ecaa939c4db33aff835fc08490d49b"
  )
)

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
root <- if (length(script_arg) == 1L) {
  dirname(dirname(normalizePath(sub("^--file=", "", script_arg))))
} else {
  normalizePath(getwd())
}

target_minor <- paste(unlist(numeric_version(R_TARGET))[1:2], collapse = ".")
running_minor <- paste(unlist(getRversion())[1:2], collapse = ".")
if (!identical(running_minor, target_minor)) {
  die(
    "This R is ", getRversion(), ", but webR bundles R ", R_TARGET, ". Package code\n",
    "is only portable across the patch level, so build with an R ", target_minor, ".x."
  )
}

packages <- commandArgs(trailingOnly = TRUE)
if (!length(packages)) {
  packages <- c(basename(dirname(Sys.glob(file.path(root, "pkg", "*", "DESCRIPTION")))),
                names(UPSTREAM))
}

extra_dir <- file.path(root, "build", "wasm-extra")
dir.create(extra_dir, recursive = TRUE, showWarnings = FALSE)

# Record the R the package is built *for*, as the cross-compiled packages do; without
# this every session opens with "package was built under R version <host>". library()
# reads Meta/package.rds rather than the DESCRIPTION file, so both have to be stamped.
stamp <- function(x) sub("^(Built: )?R [0-9.]+;", paste0("\\1R ", R_TARGET, ";"), x)

r_cmd <- function(args, what) {
  out <- system2(file.path(R.home("bin"), "R"), c("CMD", args), stdout = TRUE, stderr = TRUE)
  if (!is.null(attr(out, "status"))) die(what, " failed:\n", paste(out, collapse = "\n"))
  out
}

# The source package of an UPSTREAM entry: the archive, checked against its sha256, then
# `R CMD build` so that .Rbuildignore applies as it does for a release.
upstream_source <- function(pkg, stage) {
  spec <- UPSTREAM[[pkg]]
  archive <- file.path(stage, "upstream.tar.gz")
  utils::download.file(spec$url, archive, mode = "wb", quiet = TRUE)
  got <- unname(tools::sha256sum(archive))
  if (!identical(got, spec$sha256)) {
    die(pkg, ": ", spec$url, " has sha256 ", got, ", expected ", spec$sha256)
  }
  src <- file.path(stage, "src")
  utils::untar(archive, exdir = src)
  dir <- list.dirs(src, recursive = FALSE)
  if (length(dir) != 1L) die(pkg, ": expected one directory in ", spec$url)
  found <- read.dcf(file.path(dir, "DESCRIPTION"), fields = "Package")[1, 1]
  if (found != pkg) die(spec$url, " is the source of ", found, ", not ", pkg)
  if (dir.exists(file.path(dir, "src")) && length(list.files(file.path(dir, "src")))) {
    die(pkg, " has compiled code; build it with tools/build-wasm-pkg.sh instead")
  }
  old <- setwd(stage)
  on.exit(setwd(old))
  r_cmd(c("build", "--no-build-vignettes", "--no-manual", shQuote(dir)), paste("R CMD build", pkg))
  file.path(stage, Sys.glob(paste0(pkg, "_*.tar.gz")))
}

build_one <- function(pkg) {
  stage <- file.path(tempdir(), paste0(pkg, "-build"))
  unlink(stage, recursive = TRUE)
  lib <- file.path(stage, "lib")
  dir.create(lib, recursive = TRUE)

  src <- if (pkg %in% names(UPSTREAM)) upstream_source(pkg, stage) else file.path(root, "pkg", pkg)
  if (!pkg %in% names(UPSTREAM) && !file.exists(file.path(src, "DESCRIPTION"))) {
    die("No package source at ", src)
  }

  out <- system2(
    file.path(R.home("bin"), "R"),
    c("CMD", "INSTALL", shQuote(paste0("--library=", lib)), shQuote(src)),
    stdout = TRUE, stderr = TRUE
  )
  installed <- file.path(lib, pkg)
  if (!dir.exists(installed)) {
    die("R CMD INSTALL ", pkg, " failed:\n", paste(out, collapse = "\n"))
  }
  version <- read.dcf(file.path(installed, "DESCRIPTION"), fields = "Version")[1, 1]
  tgz <- paste0(pkg, "_", version, ".tgz")

  dcf_path <- file.path(installed, "DESCRIPTION")
  dcf <- readLines(dcf_path)
  built <- grep("^Built:", dcf)
  if (length(built) != 1L) die("Installed DESCRIPTION of ", pkg, " has no single Built: field")
  dcf[built] <- stamp(dcf[built])
  writeLines(dcf, dcf_path)

  meta_path <- file.path(installed, "Meta", "package.rds")
  meta <- readRDS(meta_path)
  meta$Built$R <- numeric_version(R_TARGET)
  meta$DESCRIPTION["Built"] <- stamp(meta$DESCRIPTION["Built"])
  saveRDS(meta, meta_path)

  if (!identical(as.character(readRDS(meta_path)$Built$R), R_TARGET)) {
    die("Failed to stamp the target R version into ", meta_path)
  }

  # Older builds of other versions would leave the repo with two candidates.
  unlink(list.files(extra_dir, pattern = paste0("^", pkg, "_.*\\.tgz$"), full.names = TRUE))
  res <- system2(
    "tar",
    c("-czf", shQuote(file.path(extra_dir, tgz)), "-C", shQuote(lib), pkg),
    stdout = TRUE, stderr = TRUE
  )
  if (!is.null(attr(res, "status"))) die("tar failed:\n", paste(res, collapse = "\n"))
  unlink(stage, recursive = TRUE)

  say("built", tgz, "for R", R_TARGET, "->", file.path("build", "wasm-extra"))
}

for (pkg in packages) build_one(pkg)
say("next: Rscript tools/vendor-wasm-repo.R")
