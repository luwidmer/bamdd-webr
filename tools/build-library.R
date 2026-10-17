#!/usr/bin/env Rscript
#
# Build the offline WebAssembly R library that the browser app mounts.
#
#   Rscript tools/build-library.R            # --frozen (default)
#   Rscript tools/build-library.R --resolve  # re-resolve versions, rewrite manifest
#
# --frozen   Download exactly the versions pinned in lib/MANIFEST.tsv and verify
#            each sha256. Never contacts the package indexes. Fails loudly on any
#            mismatch, missing file, or 404.
# --resolve  Query the repositories, recompute the dependency closure and REWRITE
#            lib/MANIFEST.tsv. Run this only when deliberately updating; review the
#            `git diff` afterwards. See README "Updating dependencies".

options(warn = 1)

# stanli bundles its interpreter and is tens of MB; R's 60s default is not enough.
options(timeout = max(1800L, getOption("timeout")))

## ---------------------------------------------------------------- configuration

# MUST match the R version bundled by vendor/webr (webR 0.6.0 -> R 4.6.0).
# Wasm binaries built for a different R version will not load.
R_CONTRIB <- "4.6"

# Order matters: the first repository providing a package wins.
#
# The local repo is a `local:` marker rather than a file:// URL so the committed
# manifest stays portable across checkouts; it is resolved against the repo root
# at download time. It holds only the packages that have no usable upstream wasm
# build and must be cross-compiled (tools/vendor-wasm-repo.R), so putting it first
# cannot silently displace any other pinned version.
#
# openpharma carries mmrm far newer than repo.r-wasm.org's 0.2.2, and
# insightsengineering carries a released rbmi rather than openpharma's .9000 dev
# build. seantalts is stanli's author and holds nothing else. brms is CRAN's, from
# repo.r-wasm.org: none of the universes above it carries brms.
# stan-dev is left out on purpose: its .9000 builds of GPL packages (bayesplot, loo)
# expire, and a served GPL binary must keep its source obtainable. CRAN's are used.
# Nothing else in any of these universes collides with the closure below.
LOCAL_REPO <- "local:vendor/wasm-repo"

REPOS <- c(
  LOCAL_REPO,
  "https://seantalts.r-universe.dev",
  "https://insightsengineering.r-universe.dev",
  "https://openpharma.r-universe.dev",
  "https://repo.r-wasm.org"
)

# stanli is the Stan interpreter. stanliWebR is first-party (pkg/stanliWebR); it
# routes brms's default rstan backend and rbmi::method_bayes() through stanli, which
# is what makes both usable without a C++ toolchain. rstan stays for the stanfit
# class that brms and rbmi work with. miraiWebR, also first-party (pkg/miraiWebR),
# runs tasks and chains on background webR workers.
#
# RBesT and OncoBayes2 are precompiled rstan models rather than stanli programs, so
# they resolve out of LOCAL_REPO; see "Cross-compiling any other package" in README.
TARGETS <- c("stanli", "stanliWebR", "miraiWebR", "rstan", "brms", "RBesT", "OncoBayes2")

# Needed by the bundled examples rather than by the Stan stack itself. Packages the
# examples call directly are listed even when something above already pulls them in,
# so they cannot vanish with an upstream dependency change. survival and ggfortify are
# only Suggests of bayesplot, but pp_check(type = "km_overlay") needs both.
EXAMPLE_PACKAGES <- c(
  "here", "knitr", "tidybayes", "ggrepel", "patchwork", "gt", "ggthemes", "ggdist",
  "mmrm", "rbmi",
  # workspace/slides
  "dplyr", "tidyr", "ggplot2", "tibble", "purrr", "stringr", "forcats", "readr",
  "emmeans", "simsurv", "survival", "ggfortify", "MASS", "scales", "mvtnorm",
  "distributional", "glue", "posterior", "bayesplot",
  # workspace/webr-examples/reproducibility.R, workspace/bamdd_leiden2026_exercises.R
  "digest", "withr",
  # workspace/webr-examples/parallel.R
  "future", "future.apply"
)

ALL_TARGETS <- c(TARGETS, EXAMPLE_PACKAGES)

# Only Depends+Imports: the runtime closure. LinkingTo is compile-time only and we
# never compile in the browser (stanli interprets Stan code), so pulling it in would
# add large header-only packages such as BH and RcppEigen for no benefit.
DEP_TYPES <- c("Depends", "Imports")

# Shipped inside webR itself. Note webR bundles NO recommended packages, so Matrix,
# mgcv, nlme and friends must still be downloaded.
BASE_PKGS <- c(
  "base", "compiler", "datasets", "graphics", "grDevices", "grid", "methods",
  "parallel", "splines", "stats", "stats4", "tcltk", "tools", "utils", "webr"
)

## ---------------------------------------------------------------------- paths

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
root <- if (length(script_arg) == 1L) {
  dirname(dirname(normalizePath(sub("^--file=", "", script_arg))))
} else {
  normalizePath(getwd())
}

manifest_path <- file.path(root, "lib", "MANIFEST.tsv")
cache_dir <- file.path(root, "vendor", "pkgcache")
lib_dir <- file.path(root, "build", "library")

## ------------------------------------------------------------------ utilities

die <- function(...) stop("\n[build-library] ", ..., call. = FALSE)
say <- function(...) cat("[build-library]", ..., "\n", sep = " ")

repo_base <- function(repo) {
  vapply(repo, function(one) {
    if (!startsWith(one, "local:")) return(one)
    dir <- file.path(root, sub("^local:", "", one))
    if (!dir.exists(dir)) {
      die(
        "Local repository not found: ", dir, "\n",
        "Build it first:  Rscript tools/vendor-wasm-repo.R"
      )
    }
    # Derived from the committed tarballs, so it is gitignored rather than committed.
    index <- file.path(dir, "bin", "emscripten", "contrib", R_CONTRIB, "PACKAGES")
    if (!file.exists(index)) {
      die(
        "Local repository has no index: ", index, "\n",
        "Write it first:  Rscript tools/vendor-wasm-repo.R"
      )
    }
    paste0("file://", normalizePath(dir))
  }, character(1), USE.NAMES = FALSE)
}

contrib_url <- function(repo) paste0(repo_base(repo), "/bin/emscripten/contrib/", R_CONTRIB)

# Both repo styles serve a plain <pkg>_<version>.tgz at the contrib root; the
# r-universe `Path` field with its query string is not needed (verified 2026-09-09).
#
# This keeps the `local:` prefix rather than expanding it, because the result is what
# lands in the committed manifest: an absolute file:// path would pin the manifest to
# one machine. resolve_url() expands it again at download time.
pkg_url <- function(repo, package, version) {
  sprintf("%s/bin/emscripten/contrib/%s/%s_%s.tgz", repo, R_CONTRIB, package, version)
}

resolve_url <- function(url) {
  if (!startsWith(url, "local:")) return(url)
  path <- file.path(root, sub("^local:", "", url))
  if (!file.exists(path)) {
    die(
      "Missing vendored package: ", path, "\n",
      "Rebuild it:  Rscript tools/vendor-wasm-repo.R"
    )
  }
  paste0("file://", normalizePath(path))
}

pkg_file <- function(package, version) sprintf("%s_%s.tgz", package, version)

sha256 <- function(path) unname(tools::sha256sum(path))

# A truncated download still leaves a file behind, so check it is a readable archive.
is_valid_tarball <- function(path) {
  if (!file.exists(path) || file.size(path) == 0) return(FALSE)
  entries <- tryCatch(
    suppressWarnings(utils::untar(path, list = TRUE)),
    error = function(e) character(0)
  )
  length(entries) > 0L
}

download_verified <- function(url, dest, expected_sha = NA_character_) {
  if (file.exists(dest)) {
    if (!is.na(expected_sha)) {
      if (identical(sha256(dest), expected_sha)) return("cached")
    } else if (is_valid_tarball(dest)) {
      return("cached")
    }
  }

  attempts <- 3L
  for (attempt in seq_len(attempts)) {
    ok <- tryCatch(
      utils::download.file(url, dest, mode = "wb", quiet = TRUE),
      error = function(e) {
        message("    attempt ", attempt, "/", attempts, " failed: ", conditionMessage(e))
        -1L
      }
    )
    if (identical(as.integer(ok), 0L) && is_valid_tarball(dest)) break
    unlink(dest)
    if (attempt == attempts) die("Download failed after ", attempts, " attempts: ", url)
  }

  got <- sha256(dest)
  if (!is.na(expected_sha) && !identical(got, expected_sha)) {
    unlink(dest)
    die(
      "Checksum mismatch for ", basename(dest), "\n",
      "  expected ", expected_sha, "\n",
      "  actual   ", got, "\n",
      "The upstream build changed. Re-run with --resolve and review the manifest diff."
    )
  }
  "downloaded"
}

## ------------------------------------------------------------------- resolving

read_merged_db <- function() {
  keep <- c("Package", "Version", "Depends", "Imports")
  frames <- list()
  for (repo in REPOS) {
    say("Reading index:", repo)
    db <- tryCatch(
      available.packages(contriburl = contrib_url(repo), filters = list()),
      error = function(e) die("Cannot read PACKAGES from ", repo, "\n  ", conditionMessage(e))
    )
    if (nrow(db) == 0L) die("Empty PACKAGES index at ", repo)
    say("  ", nrow(db), "packages")
    frames[[repo]] <- data.frame(
      db[, keep, drop = FALSE],
      Repo = repo,
      stringsAsFactors = FALSE
    )
  }
  merged <- do.call(rbind, frames)
  rownames(merged) <- NULL
  # First repository wins.
  merged[!duplicated(merged$Package), , drop = FALSE]
}

resolve_closure <- function(db) {
  missing_targets <- setdiff(ALL_TARGETS, db$Package)
  if (length(missing_targets)) {
    die(
      "Package(s) not available as wasm binaries for R ", R_CONTRIB, ": ",
      paste(missing_targets, collapse = ", "),
      "\nChecked: ", paste(REPOS, collapse = ", ")
    )
  }

  mat <- as.matrix(db[, c("Package", "Version", "Depends", "Imports")])
  rownames(mat) <- db$Package

  deps <- tools::package_dependencies(
    packages = ALL_TARGETS, db = mat, which = DEP_TYPES, recursive = TRUE
  )
  wanted <- sort(unique(c(ALL_TARGETS, unlist(deps, use.names = FALSE))))
  wanted <- setdiff(wanted, BASE_PKGS)

  unavailable <- setdiff(wanted, db$Package)
  if (length(unavailable)) {
    die(
      "Dependencies could not be resolved to wasm binaries: ",
      paste(unavailable, collapse = ", ")
    )
  }
  db[match(wanted, db$Package), , drop = FALSE]
}

## ------------------------------------------------------------------- manifest

write_manifest <- function(sel) {
  dir.create(dirname(manifest_path), recursive = TRUE, showWarnings = FALSE)
  out <- data.frame(
    package = sel$Package,
    version = sel$Version,
    repo = sel$Repo,
    filename = pkg_file(sel$Package, sel$Version),
    sha256 = sel$sha256,
    url = pkg_url(sel$Repo, sel$Package, sel$Version),
    stringsAsFactors = FALSE
  )
  out <- out[order(out$package), , drop = FALSE]
  write.table(out, manifest_path, sep = "\t", quote = FALSE, row.names = FALSE)
  say("Wrote", manifest_path, "-", nrow(out), "packages")
  invisible(out)
}

read_manifest <- function() {
  if (!file.exists(manifest_path)) {
    die(
      "No manifest at lib/MANIFEST.tsv.\n",
      "Create one first:  Rscript tools/build-library.R --resolve"
    )
  }
  m <- utils::read.delim(manifest_path, stringsAsFactors = FALSE, colClasses = "character")
  required <- c("package", "version", "repo", "filename", "sha256", "url")
  if (!all(required %in% names(m))) {
    die("Manifest is missing columns: ", paste(setdiff(required, names(m)), collapse = ", "))
  }
  m
}

## ---------------------------------------------------------------------- unpack

unpack_all <- function(files) {
  unlink(lib_dir, recursive = TRUE)
  dir.create(lib_dir, recursive = TRUE, showWarnings = FALSE)
  for (i in seq_along(files)) {
    res <- utils::untar(files[[i]], exdir = lib_dir)
    if (!identical(as.integer(res), 0L)) {
      die("Failed to unpack ", basename(files[[i]]))
    }
  }
  installed <- list.dirs(lib_dir, recursive = FALSE, full.names = FALSE)
  say("Unpacked", length(installed), "packages into build/library")
  installed
}

## ------------------------------------------------------------------------ main

args <- commandArgs(trailingOnly = TRUE)
unknown <- setdiff(args, c("--frozen", "--resolve"))
if (length(unknown)) die("Unknown argument(s): ", paste(unknown, collapse = " "))
mode <- if ("--resolve" %in% args) "resolve" else "frozen"

dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
say("Mode:", mode, "| R contrib:", R_CONTRIB)

if (mode == "resolve") {
  db <- read_merged_db()
  sel <- resolve_closure(db)
  say("Resolved closure:", nrow(sel), "packages")

  sel$sha256 <- NA_character_
  for (i in seq_len(nrow(sel))) {
    url <- pkg_url(sel$Repo[i], sel$Package[i], sel$Version[i])
    dest <- file.path(cache_dir, pkg_file(sel$Package[i], sel$Version[i]))
    cat(sprintf("  [%3d/%3d] %-24s %s\n", i, nrow(sel), sel$Package[i], sel$Version[i]))
    # Rebuilds change a tarball's content but not its name, so a cached copy would be
    # re-stamped into the manifest under the same version and hide the drift. r-universe
    # rebuilds continuously and a local cross-compile does the same, so never reuse the
    # cache here: --resolve exists precisely to find out what upstream is serving now.
    unlink(dest)
    download_verified(resolve_url(url), dest)
    sel$sha256[i] <- sha256(dest)
  }
  manifest <- write_manifest(sel)
} else {
  manifest <- read_manifest()
  say("Manifest pins", nrow(manifest), "packages")
  for (i in seq_len(nrow(manifest))) {
    dest <- file.path(cache_dir, manifest$filename[i])
    state <- download_verified(resolve_url(manifest$url[i]), dest, manifest$sha256[i])
    cat(sprintf("  [%3d/%3d] %-24s %-12s %s\n",
                i, nrow(manifest), manifest$package[i], manifest$version[i], state))
  }
}

files <- file.path(cache_dir, if (mode == "resolve") {
  pkg_file(manifest$package, manifest$version)
} else {
  manifest$filename
})
installed <- unpack_all(files)

missing_after <- setdiff(ALL_TARGETS, installed)
if (length(missing_after)) {
  die("Targets missing from build/library after unpack: ", paste(missing_after, collapse = ", "))
}

size <- sum(file.info(list.files(lib_dir, recursive = TRUE, full.names = TRUE))$size, na.rm = TRUE)
say(sprintf("Library size: %.0f MB (uncompressed)", size / 1e6))
say("Next:  Rscript tools/pack-library.R")
