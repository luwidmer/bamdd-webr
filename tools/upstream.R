# Pure-R packages built from an upstream source until a wasm build of it exists, read by
# tools/build-first-party.R, which builds them, and tools/fetch-test-inputs.R, which takes
# their tests from the same archives. rbmi: MMRM starting values in Stan's names and
# shapes (openpharma/rbmi#609) and two-visit correlation priors (#613), from PR #614.
# brms: its own stanli backend (paul-buerkner/brms#1966), on master only. future: brms
# master needs >= 1.80.0, and repo.r-wasm.org has 1.76.0. `url` is tried in order; a CRAN
# release moves to the Archive once superseded.
UPSTREAM <- list(
  rbmi = list(
    url = "https://github.com/openpharma/rbmi/archive/2d7b92b25a69289c2d297aaf65dee55d8d643c6f.tar.gz",
    sha256 = "1d7e488012927323f71ffc3ef295047af8ecaa939c4db33aff835fc08490d49b"
  ),
  brms = list(
    url = "https://github.com/paul-buerkner/brms/archive/426188cdb88b194676af43731fc88b8259d3bae7.tar.gz",
    sha256 = "4de4bd030d200fad850e491d908a70a37d65aba569bb79ab774186b63472a782"
  ),
  future = list(
    url = c("https://cloud.r-project.org/src/contrib/future_1.82.0.tar.gz",
            "https://cloud.r-project.org/src/contrib/Archive/future/future_1.82.0.tar.gz"),
    sha256 = "30a6eeb5289f70f81f86eb2d379caba5cf36604299e689907d92710c45f7e946"
  )
)

# The Stan pair the RBesT harness cross-compiles (tools/wasm-patches/BesT-webr-harness.patch)
# and tools/build-wasm-pkg.sh builds StanHeaders from. rstan: develop of stan-dev/rstan, as
# rstan >= 2.36 has no CRAN release; `subdir` is the package inside the archive. StanHeaders:
# CRAN's current release, newer than develop's 2.39.0.9000.
STAN <- list(
  rstan = list(
    version = "2.39.0.9000",
    url = "https://github.com/stan-dev/rstan/archive/6d858e0a7e16931334f7dd4e84270ee504a0852f.tar.gz",
    sha256 = "26fe605899c65df2f78ffc09443fab0db343d9e8441fa840ce3754c549b2ba62",
    subdir = "rstan/rstan"
  ),
  StanHeaders = list(
    version = "2.39.1.1",
    url = c("https://cloud.r-project.org/src/contrib/StanHeaders_2.39.1.1.tar.gz",
            "https://cloud.r-project.org/src/contrib/Archive/StanHeaders/StanHeaders_2.39.1.1.tar.gz"),
    sha256 = "025e433e64f94667f3649466a8c2d45da64af05308e884959dea09b71eada706"
  )
)

# `Rscript tools/upstream.R --env`: the STAN pins as KEY=value lines, for the harness's
# docker compose build (eval "$(...)" locally, >> "$GITHUB_ENV" in CI).
if (identical(commandArgs(trailingOnly = TRUE), "--env")) {
  writeLines(c(
    paste0("RBEST_RSTAN_URL=", STAN$rstan$url),
    paste0("RBEST_RSTAN_SHA256=", STAN$rstan$sha256),
    paste0("RBEST_RSTAN_SUBDIR=", STAN$rstan$subdir),
    paste0("RBEST_RSTAN_VERSION=", STAN$rstan$version),
    paste0("RBEST_STANHEADERS_VERSION=", STAN$StanHeaders$version),
    paste0("RBEST_STANHEADERS_SHA256=", STAN$StanHeaders$sha256)
  ))
}
