# Software Bill of Materials

Every component that is shipped to the browser, vendored into this repository, or needed
to reproduce the build. Generated from
[lib/MANIFEST.tsv](lib/MANIFEST.tsv), the `DESCRIPTION` files under `build/library/`,
and the version pins in [tools/fetch-webr.sh](tools/fetch-webr.sh),
[tools/fetch-ui-libs.sh](tools/fetch-ui-libs.sh) and
[tools/build-library.R](tools/build-library.R).

* Product: BAMDD with webR/brms/stanli, app version 0.4.0
* Target runtime: a browser; **nothing runs server-side**
* Total R packages in the image: **142**, all WebAssembly builds for R 4.6 (two, `stanliWebR` and `miraiWebR`, first-party)
* Bytes served on a cold visit: ~193 MB (`vendor/webr` 56 MB + `lib/library.tar.gz` 137 MB)

---

## 1. Runtime platform

| Component | Version | Source | Licence | Role |
| --- | --- | --- | --- | --- |
| webR | 0.6.0 | `github.com/r-wasm/webr` release tarball → `vendor/webr/` | webR's own sources MIT; the distribution embeds R, so GPL-2 \| GPL-3 governs what is served | R compiled to WebAssembly; `R.wasm`, `R.js`, `webr.mjs`, worker, VFS |
| R | 4.6.0 | bundled inside webR 0.6.0 | GPL-2 \| GPL-3 | the interpreter itself |
| stanli | 0.21.0 | `seantalts.r-universe.dev` | BSD-3-Clause | Stan *interpreter* — replaces the absent C++ toolchain; `brm()`, `rbmi::method_bayes()`, `RBesT::gMAP()` and `OncoBayes2::blrm_exnex()` sample with it through `stanliWebR` |
| Emscripten | 5.0.7 | `emscripten/emsdk` image (build-time only) | MIT / NCSA | the ABI everything above is compiled to |

The webR version, the bundled R version and the `contrib/4.6` package directory are a
single hard constraint: `R_CONTRIB` in [tools/build-library.R](tools/build-library.R#L24)
must match, or the wasm packages will not load.

The webR release tarball ships no `LICENSE` file, so [tools/fetch-webr.sh](tools/fetch-webr.sh)
fetches `LICENSE.md` from the matching `github.com/r-wasm/webr` tag into `vendor/webr/`,
where it is served with the site. It names every bundled component, R included, with a
link to its source.

## 2. Browser UI libraries (vendored, served as plain `<script>`/`<link>`)

| Component | Version | Files | Licence |
| --- | --- | --- | --- |
| xterm.js | 5.3.0 | `vendor/xterm/xterm.js`, `xterm.css`, `LICENSE` | MIT |
| xterm-addon-fit | 0.8.0 | `vendor/xterm/xterm-addon-fit.js`, `LICENSE.xterm-addon-fit` | MIT |
| CodeMirror | 5.65.16 | `vendor/codemirror/codemirror.js`, `codemirror.css`, `r.js`, `material-darker.css`, `eclipse.css`, `LICENSE` | MIT |

Fetched from unpkg by [tools/fetch-ui-libs.sh](tools/fetch-ui-libs.sh). UMD builds on
purpose: the project has no bundler and **ships no npm/Node dependency tree to the
browser**. CodeMirror 6 is out of scope for the same reason. The `package.json` in the
root is development-only (§8); nothing it installs is served.

## 3. First-party code (this repository)

Everything original here is GPL-3.0-or-later, except the `stanliWebR` and `miraiWebR`
packages, which are Apache-2.0. Apache-2.0 is one-way compatible with GPL-3, so the two combine in the
shipped image; they would *not* combine under GPL-2, which is why GPL-3 was chosen.
See [LICENSE](LICENSE) and [pkg/stanliWebR/inst/LICENSE.md](pkg/stanliWebR/inst/LICENSE.md).

| Component | Files | Licence |
| --- | --- | --- |
| Browser app shell | [index.html](index.html), [css/app.css](css/app.css), [favicon.svg](favicon.svg) | GPL-3.0-or-later |
| App modules | `js/*.js`: app, session, library, workers, terminal, editor, files, plots, viewer, split, theme, layout, environment, packages, datagrid, help, traceback, rname, config (~3.6 kLOC, ES modules, no build step) and `r/webrapp.R` (R side of the panes) | GPL-3.0-or-later |
| Development servers | [serve.py](serve.py) (stdlib only), [serve.R](serve.R) (needs `httpuv`) — exist solely to send COOP/COEP | GPL-3.0-or-later |
| Build scripts | `tools/fetch-webr.sh`, `fetch-ui-libs.sh`, `fetch-wasm-repo.sh`, `build-library.R`, `pack-library.R`, `build-first-party.R`, `build-wasm-pkg.{R,sh}`, `vendor-wasm-repo.R`, `convert-bamdd.R`, `convert-bamdd-slides.R`, `make-dist.sh`, `deploy.sh` | GPL-3.0-or-later |
| Deployment config | [_headers](_headers) (COOP/COEP for Cloudflare Pages), `.github/workflows/{wasm-repo,deploy}.yml`, [tools/smoke-test.mjs](tools/smoke-test.mjs) | GPL-3.0-or-later |
| `stanliWebR` R package | [pkg/stanliWebR](pkg/stanliWebR) 0.7.0 — runs brms's rstan backend, `rbmi::method_bayes()`, `RBesT::gMAP()`, `OncoBayes2::blrm_exnex()` and `rstan::stan_model()` programs on stanli; with `cores` > 1, one chain per webR worker | Apache-2.0 |
| `miraiWebR` R package | [pkg/miraiWebR](pkg/miraiWebR) 0.1.3 — a subset of the `mirai` API, and a `future` backend, on background webR workers started by `js/workers.js`; no code from `mirai` | Apache-2.0 |
| Patches | `tools/wasm-patches/jinjar_0.3.2.patch` (backport of nlohmann/json PR #3082, v3.10.4, MIT, for libc++), `tools/wasm-patches/webr-tbb-stubs.cpp` (TBB no-ops, from RBesT, GPL (>= 3)) | upstream terms |
| Examples | `workspace/webr-examples/`: `brms-kidney.R`, `stanli-eight-schools.R`, `rbmi-bayes-stanli.R`, `reproducibility.R`, `parallel.R` | GPL-3.0-or-later |
| bamdd workshop material | `workspace/bamdd_leiden2026_exercises.R`, `workspace/slides/` (eight slide scripts), `workspace/data/longitudinal.csv` and one Stan program in `workspace/stan/`, converted from `github.com/Novartis/bamdd`; text in [workspace/LICENSE-GPL-2](workspace/LICENSE-GPL-2) | GPL-2, as upstream |

## 4. Vendored third-party content

| Component | Version / state | Origin | Notes |
| --- | --- | --- | --- |
| RBesT build harness | `v1.12-0` tag | `github.com/Novartis/RBesT`, `tools/webr/docker` | public; cloned to `vendor/BesT/` purely to supply the Emscripten cross-compilation image for `rstan` and `StanHeaders`; GPL (>= 3). Not the source of `RBesT` itself, which is taken from CRAN |
| bamdd Leiden 2026 workshop | fetched by [tools/convert-bamdd.R](tools/convert-bamdd.R) and [tools/convert-bamdd-slides.R](tools/convert-bamdd-slides.R) | `github.com/Novartis/bamdd`, `workshops/leiden2026` | GPL-2; converted into `workspace/` |
| `vendor/wasm-repo/` | CRAN-like wasm repo, 7 packages | built here (§5) | resolved *first* by `build-library.R` |
| `vendor/pkgcache/` | downloaded `.tgz` files | the repos in §6 | build cache, not served |

## 5. Cross-compiled packages (no usable upstream wasm build)

Built with the Emscripten image from `Novartis/RBesT`'s `tools/webr/docker`, checked out
at `vendor/BesT/`, and collected into
`vendor/wasm-repo/` by [tools/vendor-wasm-repo.R](tools/vendor-wasm-repo.R). These are
not committed, so a build has to reproduce them first and therefore does
need Docker. Every input is public: five packages come from CRAN sources (`RBesT`,
`OncoBayes2` and `jinjar` via [tools/build-wasm-pkg.sh](tools/build-wasm-pkg.sh), `rstan`
and `StanHeaders` via the harness), `stanliWebR` and
`miraiWebR` from [pkg/](pkg) via [tools/build-first-party.R](tools/build-first-party.R),
and the harness from GitHub.

| Package | Version | Licence | Why it is built here |
| --- | --- | --- | --- |
| `rstan` | 2.32.7 | GPL (>= 3) | the only upstream wasm build (2.39.0.9000) fails to load its `.so` |
| `StanHeaders` | 2.32.10 | BSD-3-Clause | built with the Intel TBB entry points stubbed out (`inst/webr/tbb-stubs.cpp`) |
| `RBesT` | 1.12-0 | GPL (>= 3) | its Stan model is an Rcpp module in its own `.so`; needs a real `rstan`. Built from the CRAN release with `WASM_PKG_STAN=1`, which drops the native TBB linkage `wasm-ld` cannot use |
| `OncoBayes2` | 0.10-0 | GPL (>= 3) | same rstantools construction as `RBesT`, and built the same way with `WASM_PKG_STAN=1` |
| `jinjar` | 0.3.2 | MIT | no wasm build anywhere; vendored inja/nlohmann does not compile under libc++ |
| `stanliWebR` | 0.7.0 | Apache-2.0 | first-party, built from `pkg/stanliWebR` |
| `miraiWebR` | 0.1.3 | Apache-2.0 | first-party, built from `pkg/miraiWebR` |

## 6. Package sources

Resolution order is significant — the first repository providing a package wins.

| # | Repository | Packages |
| --- | --- | --- |
| 1 | `local:vendor/wasm-repo` | 7 |
| 2 | `seantalts.r-universe.dev` | 1 |
| 3 | `insightsengineering.r-universe.dev` | 1 |
| 4 | `openpharma.r-universe.dev` | 1 |
| 5 | `repo.r-wasm.org` | 132 |

Every entry is pinned by version **and sha256** in `lib/MANIFEST.tsv`; the default
`--frozen` build verifies each checksum and fails loudly on any mismatch or 404.

## 7. R packages in the mounted library (142)

Dependency closure of `Depends` + `Imports` over the targets `stanli`, `stanliWebR`,
`miraiWebR`, `rstan`, `brms`, `RBesT`, `OncoBayes2` plus the example-only packages in
`EXAMPLE_PACKAGES` of [tools/build-library.R](tools/build-library.R) (among them
`mmrm`, `rbmi`, and what the bamdd slides use: `readr`, `forcats`, `emmeans`,
`simsurv`, `survival`, `ggfortify`). `LinkingTo` is
deliberately excluded (compile-time only). webR bundles no recommended packages, so
`Matrix`, `mgcv`, `nlme` and friends appear here.

`*` marks an r-universe repository.

| Package | Version | Source | Licence |
| --- | --- | --- | --- |
| `abind` | 1.4-8 | repo.r-wasm.org | MIT |
| `arrayhelpers` | 1.1-2 | repo.r-wasm.org | GPL |
| `assertthat` | 0.2.1 | repo.r-wasm.org | GPL-3 |
| `backports` | 1.5.1 | repo.r-wasm.org | GPL-2 or GPL-3 |
| `base64enc` | 0.1-6 | repo.r-wasm.org | GPL-2 or GPL-3 |
| `bayesplot` | 1.16.0 | repo.r-wasm.org | GPL (>= 3) |
| `bigD` | 0.3.1 | repo.r-wasm.org | MIT |
| `bit` | 4.6.0 | repo.r-wasm.org | GPL-3 |
| `bit64` | 4.8.6 | repo.r-wasm.org | GPL-3 |
| `bitops` | 1.1-0 | repo.r-wasm.org | GPL (>= 2) |
| `bridgesampling` | 1.2-1 | repo.r-wasm.org | GPL (>= 2) |
| `brms` | 2.23.0 | repo.r-wasm.org | GPL-2 |
| `Brobdingnag` | 1.3-1 | repo.r-wasm.org | GPL |
| `bslib` | 0.12.0 | repo.r-wasm.org | MIT |
| `cachem` | 1.1.0 | repo.r-wasm.org | MIT |
| `callr` | 3.8.0 | repo.r-wasm.org | MIT |
| `checkmate` | 2.3.4 | repo.r-wasm.org | BSD-3-Clause |
| `cli` | 3.6.6 | repo.r-wasm.org | MIT |
| `clipr` | 0.8.1 | repo.r-wasm.org | GPL-3 |
| `coda` | 0.19-4.1 | repo.r-wasm.org | GPL (>= 2) |
| `codetools` | 0.2-20 | repo.r-wasm.org | GPL |
| `commonmark` | 2.0.0 | repo.r-wasm.org | BSD-2-Clause |
| `crayon` | 1.5.3 | repo.r-wasm.org | MIT + file LICENSE |
| `desc` | 1.4.3 | repo.r-wasm.org | MIT |
| `digest` | 0.6.39 | repo.r-wasm.org | GPL (>= 2) |
| `distributional` | 0.9.0 | repo.r-wasm.org | GPL-3 |
| `dplyr` | 1.2.1 | repo.r-wasm.org | MIT |
| `emmeans` | 2.0.4 | repo.r-wasm.org | GPL-3 |
| `estimability` | 2.0.0 | repo.r-wasm.org | GPL (>= 3) |
| `evaluate` | 1.0.5 | repo.r-wasm.org | MIT |
| `farver` | 2.1.2 | repo.r-wasm.org | MIT |
| `fastmap` | 1.2.0 | repo.r-wasm.org | MIT |
| `fontawesome` | 0.5.3 | repo.r-wasm.org | MIT |
| `forcats` | 1.0.1 | repo.r-wasm.org | MIT + file LICENSE |
| `Formula` | 1.2-6 | repo.r-wasm.org | GPL-2 or GPL-3 |
| `fs` | 2.1.0 | repo.r-wasm.org | MIT |
| `future` | 1.76.0 | repo.r-wasm.org | LGPL (>= 2.1) |
| `future.apply` | 1.20.2 | repo.r-wasm.org | GPL (>= 2) |
| `generics` | 0.1.4 | repo.r-wasm.org | MIT |
| `ggdist` | 3.3.3 | repo.r-wasm.org | GPL (>= 3) |
| `ggfortify` | 0.4.24 | repo.r-wasm.org | MIT + file LICENSE |
| `ggplot2` | 4.0.3 | repo.r-wasm.org | MIT |
| `ggrepel` | 0.9.8 | repo.r-wasm.org | GPL-3 |
| `ggridges` | 0.5.7 | repo.r-wasm.org | GPL-2 |
| `ggthemes` | 7.0.0 | repo.r-wasm.org | GPL-2 |
| `globals` | 0.20.0 | repo.r-wasm.org | LGPL (>= 2.1) |
| `glue` | 1.8.1 | repo.r-wasm.org | MIT |
| `gridExtra` | 2.3.1 | repo.r-wasm.org | GPL (>= 2) |
| `gt` | 0.11.1 | repo.r-wasm.org | MIT |
| `gtable` | 0.3.6 | repo.r-wasm.org | MIT |
| `here` | 1.0.2 | repo.r-wasm.org | MIT |
| `highr` | 0.12 | repo.r-wasm.org | GPL |
| `hms` | 1.1.4 | repo.r-wasm.org | MIT + file LICENSE |
| `htmltools` | 0.5.9 | repo.r-wasm.org | GPL (>= 2) |
| `htmlwidgets` | 1.6.4 | repo.r-wasm.org | MIT |
| `inline` | 0.3.21 | repo.r-wasm.org | LGPL |
| `isoband` | 0.3.0 | repo.r-wasm.org | MIT |
| `jinjar` | 0.3.2 | vendor/wasm-repo | MIT |
| `jquerylib` | 0.1.4 | repo.r-wasm.org | MIT |
| `jsonlite` | 2.0.0 | repo.r-wasm.org | MIT |
| `knitr` | 1.52 | repo.r-wasm.org | GPL |
| `labeling` | 0.4.3 | repo.r-wasm.org | MIT or Unlimited |
| `lattice` | 0.23-1 | repo.r-wasm.org | GPL (>= 2) |
| `lifecycle` | 1.0.5 | repo.r-wasm.org | MIT |
| `listenv` | 1.1.0 | repo.r-wasm.org | LGPL (>= 2.1) |
| `litedown` | 0.11 | repo.r-wasm.org | MIT |
| `loo` | 2.10.1 | repo.r-wasm.org | GPL (>= 3) |
| `magrittr` | 2.0.5 | repo.r-wasm.org | MIT |
| `markdown` | 2.0 | repo.r-wasm.org | MIT |
| `MASS` | 7.3-66 | repo.r-wasm.org | GPL-2 or GPL-3 |
| `Matrix` | 1.7-6 | repo.r-wasm.org | GPL (>= 2) + file LICENCE |
| `matrixStats` | 1.5.0 | repo.r-wasm.org | Artistic-2.0 |
| `memoise` | 2.0.1 | repo.r-wasm.org | MIT |
| `mgcv` | 1.9-4 | repo.r-wasm.org | GPL (>= 2) |
| `mime` | 0.13 | repo.r-wasm.org | GPL |
| `miraiWebR` | 0.1.3 | vendor/wasm-repo | Apache-2.0 |
| `mmrm` | 0.3.19.9000 | openpharma* | Apache-2.0 |
| `mvtnorm` | 1.2-4 | repo.r-wasm.org | GPL-2 |
| `nleqslv` | 3.3.7 | repo.r-wasm.org | GPL (>= 2) |
| `nlme` | 3.1-171 | repo.r-wasm.org | GPL (>= 2) |
| `numDeriv` | 2016.8-1.1 | repo.r-wasm.org | GPL-2 |
| `OncoBayes2` | 0.10-0 | vendor/wasm-repo | GPL (>= 3) |
| `otel` | 0.2.0 | repo.r-wasm.org | MIT |
| `parallelly` | 1.48.0 | repo.r-wasm.org | LGPL (>= 2.1) |
| `patchwork` | 1.3.2 | repo.r-wasm.org | MIT |
| `pillar` | 1.11.1 | repo.r-wasm.org | MIT |
| `pkgbuild` | 1.4.8 | repo.r-wasm.org | MIT |
| `pkgconfig` | 2.0.3 | repo.r-wasm.org | MIT |
| `pkgload` | 1.5.3 | repo.r-wasm.org | MIT |
| `plyr` | 1.8.9 | repo.r-wasm.org | MIT |
| `posterior` | 1.7.0 | repo.r-wasm.org | BSD-3-Clause |
| `processx` | 3.9.0 | repo.r-wasm.org | MIT |
| `ps` | 1.9.3 | repo.r-wasm.org | MIT |
| `purrr` | 1.2.2 | repo.r-wasm.org | MIT |
| `quadprog` | 1.5-8 | repo.r-wasm.org | GPL (>= 2) |
| `QuickJSR` | 1.11.0 | repo.r-wasm.org | MIT |
| `R6` | 2.6.1 | repo.r-wasm.org | MIT |
| `rappdirs` | 0.3.4 | repo.r-wasm.org | MIT |
| `RBesT` | 1.12-0 | vendor/wasm-repo | GPL (>= 3) |
| `rbibutils` | 2.4.1 | repo.r-wasm.org | GPL-2 |
| `rbmi` | 1.7.0 | insightsengineering* | Apache-2.0 (>= 2) |
| `RColorBrewer` | 1.1-3 | repo.r-wasm.org | Apache-2.0 |
| `Rcpp` | 1.1.2 | repo.r-wasm.org | GPL (>= 2) |
| `RcppParallel` | 5.1.11-2 | repo.r-wasm.org | GPL (>= 3) |
| `Rdpack` | 2.6.6 | repo.r-wasm.org | GPL (>= 2) |
| `reactable` | 0.4.5 | repo.r-wasm.org | MIT |
| `reactR` | 0.6.1 | repo.r-wasm.org | MIT |
| `readr` | 2.2.0 | repo.r-wasm.org | MIT + file LICENSE |
| `reshape2` | 1.4.5 | repo.r-wasm.org | MIT |
| `rlang` | 1.3.0 | repo.r-wasm.org | MIT |
| `rmarkdown` | 2.32 | repo.r-wasm.org | GPL-3 |
| `rprojroot` | 2.1.1 | repo.r-wasm.org | MIT |
| `rstan` | 2.32.7 | vendor/wasm-repo | GPL (>= 3) |
| `rstantools` | 2.7.1 | repo.r-wasm.org | GPL (>= 3) |
| `S7` | 0.2.2 | repo.r-wasm.org | MIT |
| `sass` | 0.4.10.9000 | repo.r-wasm.org | MIT |
| `scales` | 1.4.0 | repo.r-wasm.org | MIT |
| `simsurv` | 1.0.1 | repo.r-wasm.org | GPL (>= 3) |
| `StanHeaders` | 2.39.1 | vendor/wasm-repo | BSD-3-Clause |
| `stanli` | 0.22.0 | seantalts* | BSD-3-Clause |
| `stanliWebR` | 0.7.0 | vendor/wasm-repo | Apache-2.0 |
| `statmod` | 1.5.2 | repo.r-wasm.org | GPL-2 or GPL-3 |
| `stringi` | 1.8.9 | repo.r-wasm.org | file LICENSE (BSD-style + ICU) |
| `stringr` | 1.6.0 | repo.r-wasm.org | MIT |
| `survival` | 3.8-12 | repo.r-wasm.org | LGPL (>= 2) |
| `svUnit` | 1.0.8 | repo.r-wasm.org | GPL-2 |
| `tensorA` | 0.36.2.1 | repo.r-wasm.org | GPL (>= 2) |
| `tibble` | 3.3.1 | repo.r-wasm.org | MIT |
| `tidybayes` | 3.0.7 | repo.r-wasm.org | GPL (>= 3) |
| `tidyr` | 1.3.2 | repo.r-wasm.org | MIT |
| `tidyselect` | 1.2.1 | repo.r-wasm.org | MIT |
| `tinytex` | 0.61 | repo.r-wasm.org | MIT |
| `TMB` | 1.9.11 | repo.r-wasm.org | GPL-2 |
| `tzdb` | 0.5.0 | repo.r-wasm.org | MIT + file LICENSE |
| `utf8` | 1.2.6 | repo.r-wasm.org | Apache-2.0 |
| `vctrs` | 0.7.3 | repo.r-wasm.org | MIT |
| `viridisLite` | 0.4.3 | repo.r-wasm.org | MIT |
| `vroom` | 1.7.1.9000 | repo.r-wasm.org | MIT + file LICENSE |
| `withr` | 3.0.3 | repo.r-wasm.org | MIT |
| `xfun` | 0.61 | repo.r-wasm.org | MIT |
| `xml2` | 1.6.0 | repo.r-wasm.org | MIT |
| `yaml` | 2.3.12 | repo.r-wasm.org | BSD-3-Clause |

## 8. Build-time only (not shipped)

| Component | Version | Needed for |
| --- | --- | --- |
| R (host) | any recent; major.minor must match 4.6 for building R packages locally | running `tools/*.R` |
| `rwasm` | `r-wasm/rwasm` @ HEAD | `add_tar_index()` in `tools/pack-library.R`; pure R, no Emscripten |
| `httpuv` | any | `serve.R` only (`serve.py` has no dependencies) |
| `bash`, `curl`, `tar` | system | fetch scripts |
| Docker + `rocker/r-ver` | 4.6.0 | cross-compile harness, host R stage |
| `emscripten/emsdk` | 5.0.7 | cross-compile harness, must match webR's Emscripten |
| `ghcr.io/r-wasm/webr` | v0.6.0 (amd64 image, never executed) | cross-compile harness, supplies the arch-independent webR tree |
| Node.js | 22+ | `tools/smoke-test.mjs` only |
| `playwright` | 1.56.1 (Apache-2.0) | the browser check in `tools/smoke-test.mjs`; never served |
| `wrangler` | 4.147.0 (MIT OR Apache-2.0) | `tools/deploy.sh`, the manual Cloudflare deploy; never served |

The browser Playwright drives is **not** vendored. CI installs its bundled Chromium;
locally, `PLAYWRIGHT_CHANNEL=chrome` uses an already-installed Chrome or Edge instead,
which is the only workable route on a machine whose endpoint security blocks unpacking a
new application bundle.

### GitHub Actions (CI only, all pinned by commit SHA)

| Action | Licence | Used by |
| --- | --- | --- |
| `actions/checkout`, `actions/upload-artifact`, `actions/setup-node` | MIT | both workflows |
| `actions/download-artifact` | MIT | `wasm-repo.yml` |
| `r-lib/actions/setup-r`, `setup-r-dependencies` | MIT | both workflows |
| `cloudflare/wrangler-action` | Apache-2.0 | R2 upload and `pages deploy` |
| `softprops/action-gh-release` | MIT | publishing the cross-compiled bundle |
| `peter-evans/create-pull-request` | MIT | the regenerated `lib/MANIFEST.tsv` |

Pinning by SHA rather than tag is deliberate: a mutable tag on a third-party action is
an unreviewed code path with access to the deployment credentials.

## 9. Build artifacts

| Artifact | Size | Committed | Produced by |
| --- | --- | --- | --- |
| `lib/MANIFEST.tsv` | 142 pinned packages + sha256 | yes | `tools/build-library.R --resolve` |
| `lib/WASM_REPO` | release tag + sha256 of the cross-compiled bundle and of the archive of every other pinned package | yes | `.github/workflows/wasm-repo.yml` |
| `vendor/wasm-repo/` | 6.5 MB | no | `tools/vendor-wasm-repo.R` |
| `build/library/` | 268 MB | no | `tools/build-library.R` |
| `lib/library.tar.gz` | 137 MB, webR v2 image (tar + appended VFS index) | no | `tools/pack-library.R` |
| `vendor/webr/` | 56 MB | no | `tools/fetch-webr.sh` |
| `dist/` | 56 MB, 205 files | no | `tools/make-dist.sh` — the deployable site, excluding the image |

## 10. Network surface at runtime

Nothing is fetched after boot. The single exception is on-demand
`install.packages()` / `webr::install()`, pointed at `PACKAGE_REPO =
https://repo.r-wasm.org` in [js/session.js](js/session.js#L13); packages installed that
way are **not pinned**, land in `/home/web_user/R/library`, shadow the pinned versions,
and do not survive a reload.

Starting background workers (`miraiWebR::daemons()`) loads webR's own files from
`vendor/webr/` again for each worker, from the page's own origin and normally out of
the browser cache; the package library image is not fetched again.

Serving requires `Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp`; the app refuses to boot without
`crossOriginIsolated` rather than degrading to the PostMessage channel.

A Cloudflare deployment adds one more origin: `lib/library.tar.gz` exceeds the 25 MiB
Pages asset limit, so it is served from R2 and `js/config.js` points at it. Under
`require-corp` that object must carry `Cross-Origin-Resource-Policy: cross-origin` or
pass a CORS check. Locally the URL stays relative and nothing changes. See
[DEPLOY.md](DEPLOY.md).

## 11. Licence summary (the 142 mounted R packages)

| Family | Count |
| --- | --- |
| MIT | 68 |
| GPL (GPL-2 / GPL-3 / GPL >= 2 / >= 3) | 54 |
| BSD (2- and 3-clause) | 6 |
| LGPL (>= 2 / >= 2.1) | 6 |
| Apache-2.0 | 6 |
| Artistic-2.0 | 1 |
| `file LICENSE` (`stringi`) | 1 |

Copyleft obligations are live: the image redistributes GPL and LGPL code (including R
itself, `brms`, `rstan`, `RBesT`, `OncoBayes2` and `mgcv`). No AGPL code is shipped:
`dqrng`, which one slide (`05_mmrm.R`) uses, is AGPL-3, so the converted slide calls
base `sample()` instead. Hosting this publicly is a
distribution act distinct from a user installing from CRAN — review `lib/MANIFEST.tsv`
and the per-package `LICENSE`/`LICENCE` files under `build/library/` before deploying,
as noted in [DEPLOY.md](DEPLOY.md).

---

**Regenerating this document.** Versions come from `lib/MANIFEST.tsv`; licences from
`grep '^License:' build/library/*/DESCRIPTION` after a build; UI and platform pins from
the `*_VERSION` variables in `tools/fetch-*.sh` and the `ARG` pins in
`Novartis/RBesT`'s `tools/webr/docker/Dockerfile`.
