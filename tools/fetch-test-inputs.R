#!/usr/bin/env Rscript
#
# Fetch what tools/test-packages.mjs needs to run every package's own tests, pinned
# like the library itself.
#
#   Rscript tools/fetch-test-inputs.R            # --frozen (default)
#   Rscript tools/fetch-test-inputs.R --resolve  # re-resolve, rewrite lib/TEST-MANIFEST.tsv
#
# lib/TEST-MANIFEST.tsv has two kinds of rows:
#
#   lib  wasm builds of the test frameworks -- testthat, RUnit, tinytest, testit --, of
#        the few Suggests that packages' tests need (TEST_SUGGESTS), and of those of
#        their dependencies the image lacks, from repo.r-wasm.org. They are unpacked
#        into build/test-library, which only the test run puts on .libPaths(); the
#        deployed image never contains them.
#   src  one source tarball per package in lib/MANIFEST.tsv, at exactly the pinned
#        version: CRAN (current or archive), stanli's r-universe, or pkg/ for the
#        first-party packages. Installed wasm packages do not carry their tests, so
#        only the test directories are taken from these, into build/test-sources.
#
# --frozen   Download exactly what the manifest pins, verify each sha256, unpack.
#            Never queries a package index. Fails loudly on any mismatch or 404.
# --resolve  Rebuild the manifest from lib/MANIFEST.tsv and the current indexes. A
#            pinned version with no published source -- an unreleased development
#            build -- is recorded as `unpublished`; its tests then fail the run.

options(warn = 1)
options(timeout = max(600L, getOption("timeout")))

# MUST match tools/build-library.R.
R_CONTRIB <- "4.6"
WASM_REPO <- "https://repo.r-wasm.org"
CRAN <- "https://cloud.r-project.org"
FRAMEWORKS <- c("testthat", "RUnit", "tinytest", "testit")
# Suggests that packages' tests use without skipping when they are absent; each one
# turns entries in lib/TEST-SKIPS.tsv into real tests. patrick: bit64's parameterised
# tests; mnormt: brms's skew-normal distribution tests; calculus to Rsolnp: metafor's
# tests; whoami: desc; maps: ggplot2; eha: simsurv; vdiffr: patchwork; shiny: bslib.
# car and Greg (metafor, forestplot) are left out: each pulls in 20+ packages. usethis
# (rstantools) has no complete wasm closure: it imports pak.
TEST_SUGGESTS <- c(
  "mnormt", "patrick",
  "calculus", "clubSandwich", "gsl", "lme4", "multcomp", "MuMIn", "Rsolnp",
  "whoami", "maps", "eha", "vdiffr", "shiny"
)
# Where packages keep tests outside tests/: tinytest's files, RUnit suites.
INST_TEST_DIRS <- c("inst/tinytest", "inst/unitTests")

BASE_PKGS <- c(
  "base", "compiler", "datasets", "graphics", "grDevices", "grid", "methods",
  "parallel", "splines", "stats", "stats4", "tcltk", "tools", "utils", "webr"
)

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
root <- if (length(script_arg) == 1L) {
  dirname(dirname(normalizePath(sub("^--file=", "", script_arg))))
} else {
  normalizePath(getwd())
}

library_manifest <- file.path(root, "lib", "MANIFEST.tsv")
test_manifest <- file.path(root, "lib", "TEST-MANIFEST.tsv")
cache_dir <- file.path(root, "vendor", "testcache")
test_lib <- file.path(root, "build", "test-library")
test_src <- file.path(root, "build", "test-sources")

die <- function(...) stop("\n[fetch-test-inputs] ", ..., call. = FALSE)
say <- function(...) cat("[fetch-test-inputs]", ..., "\n", sep = " ")

sha256 <- function(path) unname(tools::sha256sum(path))

# HEAD rather than GET: resolving checks a few hundred URLs.
exists_url <- function(url) {
  h <- tryCatch(curlGetHeaders(url, redirect = TRUE), error = function(e) NULL)
  !is.null(h) && attr(h, "status") == 200L
}

# With no expected sha256 -- resolving -- a cached file is reused: a released source
# tarball, or an archive named by its commit, does not change.
download <- function(url, dest, expected = NA_character_) {
  if (file.exists(dest) && file.size(dest) > 0 &&
      (is.na(expected) || identical(sha256(dest), expected))) {
    return("cached")
  }
  for (attempt in 1:3) {
    ok <- tryCatch(
      utils::download.file(url, dest, mode = "wb", quiet = TRUE),
      error = function(e) -1L
    )
    if (identical(as.integer(ok), 0L) && file.size(dest) > 0) break
    unlink(dest)
    if (attempt == 3L) die("Download failed after 3 attempts: ", url)
  }
  got <- sha256(dest)
  if (!is.na(expected) && !identical(got, expected)) {
    unlink(dest)
    die(
      "Checksum mismatch for ", basename(dest), "\n  expected ", expected,
      "\n  actual   ", got,
      "\nUpstream changed. Re-run with --resolve and review the manifest diff."
    )
  }
  "downloaded"
}

read_library_manifest <- function() {
  if (!file.exists(library_manifest)) die("No lib/MANIFEST.tsv")
  utils::read.delim(library_manifest, stringsAsFactors = FALSE, colClasses = "character")
}

first_party <- function(package) dir.exists(file.path(root, "pkg", package))

# The DESCRIPTION of the pinned wasm binary, as build-library.R cached it.
pinned_description <- function(row) {
  bin <- file.path(root, "vendor", "pkgcache", row$filename)
  if (!file.exists(bin)) {
    if (startsWith(row$url, "local:")) return(NULL)
    download(row$url, bin, row$sha256)
  }
  work <- file.path(tempdir(), "desc", row$package)
  unlink(work, recursive = TRUE)
  dir.create(work, recursive = TRUE)
  if (utils::untar(bin, files = paste0(row$package, "/DESCRIPTION"), exdir = work) != 0L) return(NULL)
  as.list(read.dcf(file.path(work, row$package, "DESCRIPTION"))[1, ])
}

# Where the source of a pinned package is published, or NA. r-universe drops a
# version's source with its next build, so a package from there is taken from the
# exact commit it was built from, which its DESCRIPTION records; `#subdir` names the
# package's directory inside that archive.
source_url <- function(row) {
  package <- row$package
  version <- row$version
  if (grepl("r-universe\\.dev", row$repo)) {
    d <- pinned_description(row)
    if (!is.null(d$RemoteUrl) && !is.null(d$RemoteSha) && identical(d$Version, version) &&
        grepl("^https://github.com/", d$RemoteUrl)) {
      url <- paste0(sub("/$", "", d$RemoteUrl), "/archive/", d$RemoteSha, ".tar.gz")
      if (exists_url(url)) {
        return(paste0(url, if (!is.null(d$RemoteSubdir)) paste0("#", d$RemoteSubdir)))
      }
    }
    candidates <- paste0(row$repo, "/src/contrib/", package, "_", version, ".tar.gz")
  } else {
    file <- sprintf("%s_%s.tar.gz", package, version)
    candidates <- c(
      paste0(CRAN, "/src/contrib/", file),
      paste0(CRAN, "/src/contrib/Archive/", package, "/", file)
    )
  }
  for (url in candidates) if (exists_url(url)) return(url)
  NA_character_
}

strip_fragment <- function(url) sub("#.*$", "", url)

# The cache file name: a GitHub archive is named by its commit, not the package.
cache_name <- function(package, url) {
  url <- strip_fragment(url)
  if (grepl("^https://github.com/", url)) paste0(package, "_", basename(url)) else basename(url)
}

## ------------------------------------------------------------------- resolving

resolve <- function() {
  lib <- read_library_manifest()
  rows <- list()

  say("Resolving the test frameworks and test-only Suggests against", WASM_REPO)
  contrib <- paste0(WASM_REPO, "/bin/emscripten/contrib/", R_CONTRIB)
  db <- available.packages(contriburl = contrib, filters = list())
  # Base packages are never resolved: repo.r-wasm.org also carries an unrelated CRAN
  # package named webr, and httpuv (shiny) imports webR's own.
  db <- db[!rownames(db) %in% BASE_PKGS, , drop = FALSE]
  wanted <- c(FRAMEWORKS, TEST_SUGGESTS)
  closure <- unique(c(wanted, unlist(tools::package_dependencies(
    wanted, db = db, which = c("Depends", "Imports"), recursive = TRUE
  ))))
  closure <- sort(setdiff(closure, c(lib$package, BASE_PKGS)))
  missing <- setdiff(closure, rownames(db))
  if (length(missing)) die("No wasm build of: ", paste(missing, collapse = ", "))
  dir.create(file.path(cache_dir, "lib"), recursive = TRUE, showWarnings = FALSE)
  for (p in closure) {
    v <- db[p, "Version"]
    file <- sprintf("%s_%s.tgz", p, v)
    url <- paste0(contrib, "/", file)
    dest <- file.path(cache_dir, "lib", file)
    download(url, dest)
    say(sprintf("  lib %-12s %s", p, v))
    rows[[length(rows) + 1L]] <- data.frame(
      kind = "lib", package = p, version = v, sha256 = sha256(dest), url = url
    )
  }

  say("Resolving", nrow(lib), "source tarballs")
  dir.create(file.path(cache_dir, "src"), recursive = TRUE, showWarnings = FALSE)
  unpublished <- character()
  for (i in seq_len(nrow(lib))) {
    p <- lib$package[i]
    v <- lib$version[i]
    if (first_party(p)) {
      rows[[length(rows) + 1L]] <- data.frame(
        kind = "src", package = p, version = v, sha256 = "-", url = paste0("local:pkg/", p)
      )
      next
    }
    url <- source_url(lib[i, ])
    if (is.na(url)) {
      unpublished <- c(unpublished, paste(p, v))
      rows[[length(rows) + 1L]] <- data.frame(
        kind = "src", package = p, version = v, sha256 = "-", url = "unpublished"
      )
      next
    }
    dest <- file.path(cache_dir, "src", cache_name(p, url))
    download(strip_fragment(url), dest)
    cat(sprintf("  [%3d/%3d] %-24s %s\n", i, nrow(lib), p, v))
    rows[[length(rows) + 1L]] <- data.frame(
      kind = "src", package = p, version = v, sha256 = sha256(dest), url = url
    )
  }
  out <- do.call(rbind, rows)
  write.table(out, test_manifest, sep = "\t", quote = FALSE, row.names = FALSE)
  say("Wrote", test_manifest, "-", sum(out$kind == "lib"), "lib,", sum(out$kind == "src"), "src")
  if (length(unpublished)) {
    say("No published source, so these packages' tests fail the run until the pin moves",
        "to a release:\n   ", paste(unpublished, collapse = "\n    "))
  }
  invisible(out)
}

## --------------------------------------------------------------------- frozen

read_test_manifest <- function() {
  if (!file.exists(test_manifest)) {
    die("No lib/TEST-MANIFEST.tsv. Create it:  Rscript tools/fetch-test-inputs.R --resolve")
  }
  m <- utils::read.delim(test_manifest, stringsAsFactors = FALSE, colClasses = "character")
  # A library pin that moved without the test pins would test the wrong sources.
  lib <- read_library_manifest()
  src <- m[m$kind == "src", ]
  stale <- setdiff(paste(lib$package, lib$version), paste(src$package, src$version))
  if (length(stale)) {
    die(
      "lib/TEST-MANIFEST.tsv does not match lib/MANIFEST.tsv for:\n  ",
      paste(stale, collapse = "\n  "),
      "\nRe-resolve it:  Rscript tools/fetch-test-inputs.R --resolve"
    )
  }
  m
}

# The test directories of one unpacked source tree, copied into build/test-sources.
take_tests <- function(from, package, version) {
  dest <- file.path(test_src, package)
  unlink(dest, recursive = TRUE)
  dir.create(dest, recursive = TRUE)
  for (d in c("tests", INST_TEST_DIRS)) {
    src <- file.path(from, d)
    if (!dir.exists(src)) next
    dir.create(file.path(dest, dirname(d)), recursive = TRUE, showWarnings = FALSE)
    file.copy(src, file.path(dest, dirname(d)), recursive = TRUE)
  }
  writeLines(version, file.path(dest, "VERSION"))
}

frozen <- function() {
  m <- read_test_manifest()
  for (d in c(file.path(cache_dir, "lib"), file.path(cache_dir, "src"))) {
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
  }

  libs <- m[m$kind == "lib", ]
  unlink(test_lib, recursive = TRUE)
  dir.create(test_lib, recursive = TRUE)
  for (i in seq_len(nrow(libs))) {
    dest <- file.path(cache_dir, "lib", basename(libs$url[i]))
    download(libs$url[i], dest, libs$sha256[i])
    if (utils::untar(dest, exdir = test_lib) != 0L) die("Could not unpack ", basename(dest))
  }
  say("Test frameworks:", nrow(libs), "packages in build/test-library")

  srcs <- m[m$kind == "src", ]
  unlink(test_src, recursive = TRUE)
  dir.create(test_src, recursive = TRUE)
  work <- file.path(tempdir(), "test-src")
  with_tests <- 0L
  for (i in seq_len(nrow(srcs))) {
    p <- srcs$package[i]
    v <- srcs$version[i]
    url <- srcs$url[i]
    # A second line in VERSION says why the package cannot be tested; the runner fails it.
    untestable <- function(why) {
      dir.create(file.path(test_src, p))
      writeLines(c(v, why), file.path(test_src, p, "VERSION"))
    }
    if (identical(url, "unpublished")) {
      untestable(paste0(p, " ", v, " has no published source, so its tests cannot be pinned"))
      next
    }
    if (startsWith(url, "local:")) {
      src <- file.path(root, sub("^local:", "", url))
      have <- unname(read.dcf(file.path(src, "DESCRIPTION"), fields = "Version")[1, 1])
      if (!identical(have, v)) {
        untestable(paste0(
          "pkg/", p, " is ", have, " but lib/MANIFEST.tsv pins ", v,
          "; rebuild the wasm bundle (wasm-repo.yml) so the library carries ", have
        ))
        next
      }
      take_tests(src, p, v)
    } else {
      dest <- file.path(cache_dir, "src", cache_name(p, url))
      download(strip_fragment(url), dest, srcs$sha256[i])
      unlink(work, recursive = TRUE)
      dir.create(work)
      listing <- utils::untar(dest, list = TRUE)
      # A CRAN tarball holds <pkg>/; a GitHub archive <repo>-<sha>/[<subdir>/].
      top <- sub("/.*$", "", listing[1])
      subdir <- if (grepl("#", url, fixed = TRUE)) sub("^.*#", "", url) else ""
      pkg_dir <- if (nzchar(subdir)) paste0(top, "/", subdir) else top
      wanted <- paste0(pkg_dir, "/", c("tests", INST_TEST_DIRS), "/")
      keep <- listing[Reduce(`|`, lapply(wanted, function(w) startsWith(listing, w)))]
      if (length(keep) && utils::untar(dest, files = keep, exdir = work) != 0L) {
        die("Could not unpack the tests of ", basename(dest))
      }
      take_tests(file.path(work, pkg_dir), p, v)
    }
    if (length(list.files(file.path(test_src, p), recursive = TRUE)) > 1L) with_tests <- with_tests + 1L
  }
  say("Test sources:", nrow(srcs), "packages,", with_tests, "with tests, in build/test-sources")
  say("Next:  npm run test-packages")
}

## ------------------------------------------------------------------------ main

args <- commandArgs(trailingOnly = TRUE)
unknown <- setdiff(args, c("--frozen", "--resolve"))
if (length(unknown)) die("Unknown argument(s): ", paste(unknown, collapse = " "))
if ("--resolve" %in% args) resolve()
frozen()
