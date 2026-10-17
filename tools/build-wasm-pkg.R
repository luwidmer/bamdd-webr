#!/usr/bin/env Rscript
#
# Container-side half of tools/build-wasm-pkg.sh. Cross-compiles one source tarball to
# WebAssembly with rwasm, inside vendor/BesT's build image.
#
# Two deviations from a plain rwasm::add_pkg() call, both needed to work at all here:
#
#  * rwasm hard-codes a Posit Package Manager mirror in its internal `ppm_config`.
#    Resolution against it fails with "nrow(out) must equal 1", so point it at CRAN.
#  * `remotes = NULL` skips rwasm's bundled webr-remotes list of GitHub refs for
#    packages that need patched sources. Resolving it needs GitHub API access, and the
#    packages built here are plain CRAN sources that rwasm has no patches for anyway.
#
# Two knobs, both set by tools/build-wasm-pkg.sh:
#
#  * WASM_PKG_DEPS -- rwasm's `dependencies`, FALSE by default. Runtime dependencies
#    are resolved from repo.r-wasm.org by tools/build-library.R, so cross-compiling the
#    closure here buys nothing and fails for everything that needs a Fortran toolchain
#    (mvtnorm, quadprog, statmod, and RcppEigen, which wants libFortranRuntime.a). The
#    headers the compile does need are host-installed in the image. NA restores the
#    closure build.
#  * WASM_PKG_STAN -- run prepare_stan_source() first; see there.

options(warn = 1)

die <- function(...) stop("\n[build-wasm-pkg] ", ..., call. = FALSE)
say <- function(...) cat("[build-wasm-pkg]", ..., "\n", sep = " ")

tarball <- Sys.getenv("WASM_PKG_TARBALL")
repo_dir <- Sys.getenv("WASM_REPO_DIR", "/out/repo")
mirror <- Sys.getenv("CRAN_SRC", "https://cloud.r-project.org")
stub <- Sys.getenv("WASM_TBB_STUB", "/tools/wasm-patches/webr-tbb-stubs.cpp")

if (!nzchar(tarball)) die("WASM_PKG_TARBALL is not set")
if (!file.exists(tarball)) die("No such tarball: ", tarball)

deps_env <- toupper(Sys.getenv("WASM_PKG_DEPS", "FALSE"))
deps <- switch(deps_env,
  "FALSE" = FALSE,
  "TRUE" = TRUE,
  "NA" = NA,
  die("WASM_PKG_DEPS must be TRUE, FALSE or NA, not ", deps_env)
)

# An rstantools package cannot be cross-compiled as it comes from CRAN. Its `configure`
# runs rstantools::rstan_config(), and the src/Makevars that generates asks the *host*
# RcppParallel for link flags, which are native:
#
#   wasm-ld: error: unknown file type: .../RcppParallel/lib/libtbb.so
#
# Stan math separately instantiates a TBB task_scheduler_observer as a namespace-scope
# global, so the module imports two TBB entry points that no wasm build defines, and
# because the observer is a global the failure is a dlopen() error rather than a
# runtime one. Each module needs its own definitions -- see the stub's header.
prepare_stan_source <- function(tarball, stub) {
  if (!file.exists(stub)) die("No TBB stub at ", stub)
  work <- file.path(tempdir(), "stan-prep")
  unlink(work, recursive = TRUE)
  src <- file.path(work, "src")
  dir.create(src, recursive = TRUE)
  if (utils::untar(tarball, exdir = src) != 0L) die("Could not unpack ", tarball)
  pkg <- list.dirs(src, recursive = FALSE)
  if (length(pkg) != 1L) die("Expected one package directory in ", tarball)

  rstantools::rstan_config(pkg)
  say("regenerated src/ with rstan", format(utils::packageVersion("rstan")))

  # `configure` would copy the stub in, but Makevars.webr makes rwasm pass
  # --no-configure, so it never runs.
  if (!file.copy(stub, file.path(pkg, "src", "webr-tbb-stubs.cpp"), overwrite = TRUE)) {
    die("Could not stage the TBB stub into ", pkg)
  }

  mk_path <- file.path(pkg, "src", "Makevars")
  if (!file.exists(mk_path)) die("rstan_config() generated no src/Makevars")
  mk <- readLines(mk_path, warn = FALSE)
  # PKG_CXXFLAGS stays: it carries RcppParallel's headers and the -DTBB_INTERFACE_NEW
  # and -DSTAN_THREADS that Stan math needs to compile at all. Only PKG_LIBS -- the
  # native -L.../RcppParallel/lib -ltbb -ltbbmalloc -- is dropped. The prebuilt wasm
  # RcppParallel ships an empty lib/, so upstream links no TBB either.
  mk <- c(mk[!grepl("^PKG_LIBS[[:space:]]*=", mk)], "PKG_LIBS =")
  if (any(grepl("^PKG_LIBS[[:space:]]*=.+", mk))) die("Failed to strip the TBB linkage")
  # rwasm's override hook: it copies this over src/Makevars *and* passes
  # --no-configure, so rstan_config() cannot put the TBB flags back.
  writeLines(mk, file.path(pkg, "src", "Makevars.webr"))

  out <- file.path(work, basename(tarball))
  owd <- setwd(src)
  on.exit(setwd(owd), add = TRUE)
  if (utils::tar(out, basename(pkg), compression = "gzip") != 0L) {
    die("Could not repack ", out)
  }
  say("prepared", basename(pkg), "-- TBB linkage dropped, stub added")
  out
}

options(repos = c(CRAN = mirror))
assignInNamespace("ppm_config", list(cran_mirror = mirror, platforms = "source"), ns = "rwasm")

if (nzchar(Sys.getenv("WASM_PKG_STAN"))) tarball <- prepare_stan_source(tarball, stub)

say("building", basename(tarball), "against", mirror, "| dependencies:", deps_env)

rwasm::add_pkg(
  paste0("local::", tarball),
  repo_dir = repo_dir,
  dependencies = deps,
  remotes = NULL
)

contrib <- file.path(repo_dir, "bin", "emscripten", "contrib", "4.6")
built <- list.files(contrib, pattern = "\\.tgz$")
want <- sub("_.*", "", basename(tarball))

# rwasm only warns when a build fails and carries on with the other packages, so the
# absence of the one we asked for is the real result.
if (!any(startsWith(built, paste0(want, "_")))) {
  die(want, " was not produced. Built: ", paste(built, collapse = ", "))
}

say("built:", paste(built, collapse = ", "))
