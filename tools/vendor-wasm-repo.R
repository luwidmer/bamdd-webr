#!/usr/bin/env Rscript
#
# Assemble vendor/wasm-repo, the small CRAN-like wasm repository holding the packages
# that have no usable build on repo.r-wasm.org. tools/build-library.R resolves against
# it first. Two sources feed it, and either can be refreshed on its own:
#
#   * vendor/BesT's cross-compile output -- the rstan/StanHeaders pair that everything
#     else is ABI-matched to, built by RBesT's harness (github.com/Novartis/RBesT,
#     tools/webr/docker). See "Rebuilding rstan and StanHeaders" in README.md.
#   * build/wasm-extra -- anything built by tools/build-wasm-pkg.sh: RBesT and
#     OncoBayes2 from their CRAN releases, jinjar, sass, vroom, Matrix with a CHOLMOD
#     fix, TMB, and mmrm compiled against it; and stanliWebR and miraiWebR from
#     pkg/, built by tools/build-first-party.R.
#
#   Rscript tools/vendor-wasm-repo.R [path/to/BesT/contrib/4.6]

options(warn = 1)

die <- function(...) stop("\n[vendor-wasm-repo] ", ..., call. = FALSE)
say <- function(...) cat("[vendor-wasm-repo]", ..., "\n", sep = " ")

# MUST match tools/build-library.R.
R_CONTRIB <- "4.6"

FROM_BEST <- c("RBesT", "rstan", "StanHeaders")

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
root <- if (length(script_arg) == 1L) {
  dirname(dirname(normalizePath(sub("^--file=", "", script_arg))))
} else {
  normalizePath(getwd())
}

args <- commandArgs(trailingOnly = TRUE)
best_dir <- if (length(args) == 1L) {
  args[[1]]
} else if (length(args) == 0L) {
  file.path(
    root, "vendor", "BesT", "build", "webr", "output",
    "repo", "bin", "emscripten", "contrib", R_CONTRIB
  )
} else {
  die("Usage: Rscript tools/vendor-wasm-repo.R [contrib-dir]")
}

extra_dir <- file.path(root, "build", "wasm-extra")
dest_dir <- file.path(root, "vendor", "wasm-repo", "bin", "emscripten", "contrib", R_CONTRIB)
dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)

vendored <- function(pkg) {
  list.files(dest_dir, pattern = paste0("^", pkg, "_.*\\.tgz$"), full.names = TRUE)
}

copy_one <- function(src_dir, pkg) {
  hits <- list.files(src_dir, pattern = paste0("^", pkg, "_.*\\.tgz$"), full.names = TRUE)
  if (length(hits) > 1L) {
    die(
      "Ambiguous: ", length(hits), " builds of ", pkg, " in ", src_dir, "\n  ",
      paste(basename(hits), collapse = "\n  "),
      "\nClean the output directory and rebuild."
    )
  }
  if (length(hits) == 0L) return(FALSE)
  unlink(vendored(pkg))
  if (!file.copy(hits[[1]], dest_dir)) die("Could not copy ", hits[[1]])
  say("vendored", basename(hits[[1]]))
  TRUE
}

for (pkg in FROM_BEST) {
  if (dir.exists(best_dir) && copy_one(best_dir, pkg)) next
  # Nothing under vendor/ is committed, so an existing copy only survives
  # from an earlier local run.
  if (!length(vendored(pkg))) {
    die(
      "No ", pkg, " in\n  ", best_dir, "\nand none already vendored. ",
      "Run the RBesT webR build; see README.md."
    )
  }
  say("kept existing", basename(vendored(pkg)))
}

if (dir.exists(extra_dir)) {
  for (f in list.files(extra_dir, pattern = "\\.tgz$")) copy_one(extra_dir, sub("_.*", "", f))
}

tools::write_PACKAGES(dest_dir, type = "mac.binary")

db <- available.packages(contriburl = paste0("file://", dest_dir), filters = list())
missing <- setdiff(FROM_BEST, rownames(db))
if (length(missing)) die("PACKAGES index does not list: ", paste(missing, collapse = ", "))

say("Index written:", file.path(dest_dir, "PACKAGES"))
print(db[, c("Package", "Version"), drop = FALSE])
say("Next:  Rscript tools/build-library.R --resolve")
