# BAMDD with webR/brms/stanli

A static site that runs R, Stan and the packages used in
[Applied Modelling in Drug Development (BAMDD)](https://opensource.nibr.com/bamdd/) --
brms, RBesT, OncoBayes2, rbmi -- entirely client-side using
[webR](https://docs.r-wasm.org/webr/latest/) and the
[stanli](https://discourse.mc-stan.org/t/stan-stanr-and-brms-running-client-side-in-the-browser-via-webr/41549)
Stan interpreter. No server-side computation, no C++ toolchain, and after the build step
no network access at all.

The page is an R workspace in the style of RStudio: editor, console, environment,
files, packages, plots, viewer and help.

> **Experimental software.** Provided as is, for research and teaching. It has not been
> validated for regulated or clinical use; results that matter should be checked against
> a native R installation.

## Status

| Works | Notes |
| --- | --- |
| R 4.6.0 terminal, editor, plots, file upload/download | fully offline |
| Environment, Packages and rendered Help panes; `View()` data grid | see "The workspace" below |
| HTML output (`gt`, htmlwidgets) in a Viewer pane | via `webr::viewer_install()` |
| Stan models via the `stanli` package directly | `webr-examples/stanli-eight-schools.R` |
| `brm()`, `summary()`, `plot()`, sampled by stanli | `webr-examples/brms-kidney.R`; needs `library(stanliWebR)`, see below |
| Novartis bamdd Leiden 2026 workshop exercises | `bamdd_leiden2026_exercises.R`, opened at startup; runs end to end in ~2 min, chains in parallel on four webR workers |
| R code of the bamdd Leiden 2026 slides (7 case studies) | `slides/`, with the `data/` and `stan/` files they read; converted by `tools/convert-bamdd-slides.R`; upstream sampler settings, chains on four webR workers: 01–04 and 07 take 2–30 s each, 05 and 06 ~4 min each |
| Bit-wise exact reproducibility (base R, stanli, brms, rbmi) | `webr-examples/reproducibility.R`; stops unless every SHA-256 matches the recorded one |
| `RBesT` (`gMAP`, `automixfit`, `ess`, decision/OC functions) | cross-compiled here; with `library(stanliWebR)`, sampled by stanli; see below |
| `OncoBayes2` (`blrm_exnex`, `blrm_trial`) | cross-compiled here; with `library(stanliWebR)`, sampled by stanli; see below |
| `mmrm`, and `rbmi` imputation built on it | in the library; no dedicated example |
| `rbmi::method_bayes()`, sampled by stanli | `webr-examples/rbmi-bayes-stanli.R`; needs `library(stanliWebR)`, see below |
| Installing further packages at runtime | `install.packages()`; see "Installing more packages" |
| Compiling a *new* Stan program with rstan (`rstan::stan_model()`, `rstan::stan()`) | with `library(stanliWebR)`, kept as code and sampled by stanli via `sampling()`; see below |
| Parallel tasks and MCMC chains on background webR workers | `webr-examples/parallel.R`; `library(miraiWebR)`, a subset of mirai's API, plus a `future` backend; desktop only, see below |
| `brms::loo_moment_match()`, `brms::bridge_sampler()` | with `library(stanliWebR)` and `save_pars(all = TRUE)`, on stanli's model |

The session pre-loads nothing: packages are installed in the mounted library and the
examples attach them with `library()`, so it behaves like an ordinary R session. The
home directory, which is also the working directory, holds the workshop exercises,
`slides/`, `data/`, `stan/` and `webr-examples/`, as `workspace/` does in this
repository.

### The workspace

The layout follows [webr.sh](https://webr.sh): editor over console on the left;
Environment / Files / Packages over Plots / Viewer / Help on the right. Below 768 px
wide or 500 px tall (a phone in either orientation), one pane is shown at a time,
picked from a bottom bar; there a new plot marks
Output instead of leaving the console.

* **Environment** lists the global environment after every command; lists and data
  frames expand one level.
* **`View()`** opens an editor tab. The data stays in R and rows are fetched in blocks
  as they scroll into view, already sorted and filtered there, so large frames are fine.
* **Packages** shows every installed package; the checkbox runs `library()` /
  `detach()` in the console, and a package name opens its help index.
* **Help** renders `?topic` as HTML, with links, back/forward and a topic search.
* **Source** saves the file and runs it as one `source()` call, so Stop interrupts all
  of it. As in RStudio it does not auto-print, so bare `ggplot(...)` lines draw nothing;
  use **Source with echo** (or Run all) for the bamdd example.
* **`q()` and Restart** start a fresh R in a new worker without asking to save the
  workspace. Files under `/home/web_user` are carried across; objects, plots and
  `View()` tabs are not.
* **Ctrl/Cmd+Enter** runs the whole statement under the cursor (a multi-line call, a
  pipe chain, an `if`/`else` block), worked out from the editor's own R tokens so it
  still queues while R is busy.
* **Debugging:** at a `Browse[n]>` prompt the console header shows Next, Step into,
  Finish, Continue and Quit (RStudio's keys: F10, Shift+F4, Shift+F6, Shift+F5,
  Shift+F8), and for sourced files the current line is highlighted. The **Traceback**
  tab (next to Help) shows the live call stack; clicking a frame lists it in the
  Environment pane and opens its line. After an uncaught error the console offers
  **Show traceback**, which fills the same tab, and **Rerun with debug** (`recover()`).
  `file#line` references in the console open the editor there. Setting your own
  `options(error = )` replaces the traceback hook.
* **Environment selector:** like RStudio's, it walks the chain of enclosing
  environments from the global environment or the selected frame down to
  `package:base`. Package and namespace environments list names only (click one to
  describe it), which keeps large ones fast; a filter box narrows any list.

The panes only query R while it is idle, never during a running model. Their helpers
live in `r/webrapp.R`, attached as `tools:webrapp`, so `rm(list = ls())` cannot break
them.

### brms, rbmi, RBesT, OncoBayes2 and rstan on stanli: stanliWebR

brms and `rbmi::method_bayes()` both hand a generated Stan program to rstan, which
compiles it with a C++ toolchain and so fails here. `stanliWebR`, whose source is in
`pkg/stanliWebR`, swaps out the few package internals that compile and sample for
equivalents that run the same program on stanli and return an ordinary rstan
`stanfit`:

```r
library(stanliWebR)   # patches brms, rbmi, RBesT, OncoBayes2, rstan, now or whenever loaded
library(brms)
fit <- brm(time ~ age * sex, data = kidney)   # default backend, sampled by stanli
```

* **brms:** `.compile_model_rstan()` only checks and keeps the code, so a broken
  program fails before any data are prepared, and `.fit_model_rstan()` samples with
  stanli. The fitted object, and everything downstream of it (`summary()`,
  `posterior_predict()`, `loo()`, `update()`), is brms's own. Parameters brms excludes,
  such as `z_1`, are dropped as rstan drops them, so no `save_pars()` is needed. The
  fit keeps stanli's model, so `loo_moment_match()` and `bridge_sampler()` work as
  with rstan (both need `save_pars(all = TRUE)`); a fit read back from disk gets its
  model rebuilt. Only NUTS is supported; `control` may set `adapt_delta`,
  `max_treedepth`, `stepsize`, `metric` (`"diag_e"`, `"dense_e"` or `"unit_e"`) and
  `adapt_engaged`, and anything else stops with an error rather than being ignored.
* **rbmi:** `get_stan_model()` only renders the program, and `fit_mcmc()` samples it
  with stanli. rbmi's own draw extraction and diagnostics then run unchanged. rbmi's
  Stan helper functions walk their input with a `while` loop and a mutable index,
  which stanli rejects, so they are swapped for `for`-loop equivalents.
* **RBesT and OncoBayes2:** these ship precompiled models and work without
  stanliWebR (see "Where rstan comes from"). With it, the one `rstan::sampling()`
  call in `gMAP()` and in `blrm_exnex()` runs the same Stan program on stanli instead,
  which is much faster here: `gMAP()` on `AS` takes 3 s instead of 26 s, and
  OncoBayes2's single-agent example 8 s instead of 34 s. OncoBayes2's program needs two
  rewrites stanli can run, neither changing the model: `sort_asc()`, which stanli does
  not implement, becomes a Stan function, and a `reject()` guard inside a function that
  sizes data is dropped (an empty input still fails, with Stan's index error).
  Their `control` settings, including the starting step size, reach stanli as they
  would reach rstan.
* **rstan:** `stan_model()` checks the Stan program and keeps it instead of compiling
  it, returning a `stanli_stanmodel`, a subclass of rstan's `stanmodel`; `sampling()`
  on it, and so `stan()`, runs the program on stanli and returns a `stanfit`, with the
  same arguments as above. Compiler options are ignored, and the ones that need C++
  (`allow_undefined`, `standalone_functions`, `use_opencl`) stop with an error.

Starting values, seeds and the caller's random stream behave as with rstan:
`"random"`, `"0"` and lists of starting values are honoured (unnamed parameters start
uniform on (-2, 2), unconstrained), and a given `seed` gives bit-identical draws.
stanli also draws from R's own generator, so stanliWebR seeds it from `seed` and puts
the caller's state back afterwards.

`options(stanliWebR.fast_math = TRUE)` builds every model in stanli's fast mode (fused
multiply-add, less exactly rounded arithmetic). It is off by default: the draws then
differ from a default run with the same seed, and the reproducibility fingerprints no
longer match. stanliWebR needs stanli 0.21.0 or later and says so if it finds an
older one.

`brm(backend = "stanli")` is not a brms backend; plain `brm()` is the way.
`webr-examples/rbmi-bayes-stanli.R` runs rbmi on `antidepressant_data` under
jump-to-reference. `method_condmean()`, `method_approxbayes()` and `method_bmlmi()`
need none of this -- they go through mmrm's maximum-likelihood fit.

### Parallel R: miraiWebR

A webR session is one thread, and webR has no processes, sockets or threads to start
more, so [mirai](https://mirai.r-lib.org) itself cannot run (nor can `nanonext`, which
it needs). `miraiWebR`, in `pkg/miraiWebR`, offers a subset of mirai's interface on
*background webR sessions* instead: each worker is another webR in its own Web
Worker, with the same package library mounted, started and driven by the page
(`js/workers.js`). The console's R talks to them through `webr::eval_js()`.

```r
library(miraiWebR)
daemons(2)                                    # start two workers (~2 s each, in parallel)
m <- mirai(sum(rnorm(n)), n = 1e6)           # returns at once
m[]                                           # waits for the value
mirai_map(1:4, function(i) i^2)[.flat]        # one task per element
everywhere(library(brms))                     # set every worker up

library(stanliWebR); library(brms)
fit <- brm(..., chains = 4, cores = 4)        # one chain per worker

future::plan(miraiWebR::webr_workers)         # future, future.apply, furrr, ...
```

* **API:** `daemons()`, `daemons_set()`, `status()`, `info()`, `mirai()`, `m[]`,
  `m$data`, `unresolved()`, `call_mirai()`, `collect_mirai()`, `stop_mirai()`,
  `mirai_map()` with `[.flat]`, `[.progress]` and `[.stop]`, `everywhere()`, and the
  `is_mirai_error()` family. Errors in a task come back as `miraiError` values, as in
  mirai. Arguments with no browser counterpart (`url`, `remote`, `dispatcher`,
  `.timeout`, `.compute`, `.promise`) stop with an error rather than being ignored.
* **Workers start clean.** They share no objects, attached packages or files with the
  console: pass data through `...` / `.args`, and load packages with `everywhere()` or
  in the task. Packages installed at runtime in the console are not visible to them.
  What a task prints appears in the console as `[worker n] ...`.
* **Random numbers:** every task draws from its own L'Ecuyer-CMRG stream, in the order
  tasks are created, so `daemons(n, seed = )` makes results reproducible whichever
  worker runs what.
* **Stop** cancels every queued and running task (their values become
  `errorValue` 20), ends any wait on them and interrupts R; Restart and `q()` stop the
  workers. While workers run, the toolbar shows e.g. `workers 2/2 busy · 2 queued`,
  and its ✕ offers **Cancel tasks** (as Stop, but R carries on with the error values)
  and **Shut down workers** (as `daemons(0)`; the next `mirai()` says so).
* **MCMC chains:** with workers running, `brm(cores = )`, `rstan::sampling(cores = )`
  (and so RBesT and OncoBayes2, which default to `getOption("mc.cores")`) sample each
  chain on a worker of its own. Chain 1 equals the sequential run's chain 1; the others
  use seeds derived from `seed`, so a parallel fit is reproducible, but not identical to
  `cores = 1`. Asking for cores without workers runs the chains in sequence and says so.
  The epilepsy model in `webr-examples/parallel.R`, 4 chains: 31 s in sequence, 16 s on two
  workers, 8 s on four (warm).
* **No fork:** webR cannot fork, so `parallel::mclapply()`, `mcmapply()` and `pvec()`
  run on one core whatever `mc.cores` says, and say so once per session. That keeps
  `options(mc.cores = 4)`, set for the chains, from breaking `loo()` and the like.
* **future:** `plan(miraiWebR::webr_workers)` uses running workers, or starts as many
  as the device allows and stops them when the plan changes.
* **Limits:** each worker is a whole R heap, so there are at most four, and one core is
  left free (`navigator.hardwareConcurrency - 1`). In the phone layout there are none:
  `daemons(n)` says so and runs every task in the console, one at a time, so the same
  code still works.

The library image is fetched and unpacked once per page into a single Blob, which the
console and every worker read through ranged requests (`js/library.js`). Mounting it
per R with `webr::mount()` would keep one 280 MB copy per R, and in a private window,
where Chrome cannot page blobs to disk, four workers then ran out of blob storage. A
side effect: Restart no longer downloads the image again.

### Where rstan comes from

rstan is not on `repo.r-wasm.org`, and the one build that does exist
(`2.39.0.9000`, from `stan-dev.r-universe.dev`) fails to load:

```
unable to load shared object '.../rstan/libs/rstan.so'
  could not load dynamic lib: TypeError: resolved is not a function
.onLoad failed: .Call("get_rng_", seed): "get_rng_" not resolved
```

A pure-R stand-in for rstan cannot serve RBesT: `gMAP()` calls `rstan::sampling()`, and
RBesT's Stan model is an Rcpp module inside its own `.so`, so it needs a real rstan and
must itself be cross-compiled. `OncoBayes2` is built the same way and needs the same
thing for `blrm_exnex()`.

rstan 2.32.7 and StanHeaders 2.32.10 therefore come from RBesT's own webR build harness
([`Novartis/RBesT`](https://github.com/Novartis/RBesT), `tools/webr/docker`), with the
Intel TBB entry points Stan Math instantiates stubbed out (`inst/webr/tbb-stubs.cpp`);
RBesT and OncoBayes2 are cross-compiled against them by `tools/build-wasm-pkg.sh`.
`tools/vendor-wasm-repo.R` collects these and the other packages built here into
`vendor/wasm-repo/`, a small CRAN-like wasm repo that `build-library.R` resolves
against first.

The engine is real, so `gMAP()` samples, but there is still no C++ toolchain in the
browser: without stanliWebR, anything that *compiles* a Stan program
(`rstan::stan_model()`) fails with "The `system()` function is unsupported under
Emscripten". Precompiled models work as they are. With stanliWebR loaded, programs from
`stan_model()`, brms and rbmi, and the models in RBesT and OncoBayes2, are all
interpreted by stanli instead (see stanliWebR above).

## Build

Needs R (for the build scripts only), `bash` and `curl`.

**No build outputs are committed.** `vendor/` is ignored in full, so the seven wasm
packages that have no usable upstream build are absent and `build-library.R` fails
loudly until they are rebuilt. Every input is public: RBesT, OncoBayes2, rstan,
StanHeaders and jinjar are all on CRAN; `tools/build-wasm-pkg.sh` cross-compiles RBesT,
OncoBayes2 and jinjar, the build harness of
[`Novartis/RBesT`](https://github.com/Novartis/RBesT) (`tools/webr/docker`, cloned at
`vendor/BesT`) cross-compiles rstan and StanHeaders and supplies the Emscripten image
`build-wasm-pkg.sh` uses, and stanliWebR and miraiWebR are in `pkg/` here. Rebuilding
everything needs Docker; only the first-party packages, which are pure R, do not.

Without Docker, download the seven as the bundle published by `wasm-repo.yml` and pinned
in `lib/WASM_REPO`; [DEPLOY.md](DEPLOY.md) ("The wasm package bundle") explains how it is
built and verified. This works once a bundle has been published, i.e. once
`lib/WASM_REPO` no longer says `PENDING`:

```sh
git clone https://github.com/luwidmer/bamdd-webr.git && cd bamdd-webr
Rscript -e 'remotes::install_github("r-wasm/rwasm")'   # once; pure R, no Emscripten
bash    tools/fetch-webr.sh          # webR 0.6.0 -> vendor/webr  (~54 MB)
bash    tools/fetch-ui-libs.sh       # xterm.js + CodeMirror 5 -> vendor/
bash    tools/fetch-wasm-repo.sh     # the seven above -> vendor/wasm-repo, the other pins -> vendor/pkgcache
Rscript tools/build-library.R        # 142 wasm packages -> build/library (~286 MB)
Rscript tools/pack-library.R         # -> lib/library.tar.gz (~138 MB)
```

To build the seven yourself instead, skip `fetch-wasm-repo.sh` and follow the three
"Rebuilding ..." sections below, then `Rscript tools/vendor-wasm-repo.R`.

[BOM.md](BOM.md) lists every component the build pulls in, with versions and licences.

### Rebuilding RBesT and OncoBayes2

Both are rstantools packages built from their CRAN releases:

```sh
WASM_PKG_STAN=1 tools/build-wasm-pkg.sh RBesT 1.12-0        # ~45 s
WASM_PKG_STAN=1 tools/build-wasm-pkg.sh OncoBayes2 0.10-0   # ~5 min
Rscript tools/vendor-wasm-repo.R
Rscript tools/build-library.R --resolve
```

The CRAN tarball of RBesT is 757 KB; its development tree also carries a 5.77 MB
`sbc/calibration_data.rds` that no RBesT function reads, so building from CRAN keeps the
wasm binary at 1.4 MB. Verified in the browser: `library(RBesT)` loads and `gMAP()`
samples.

OncoBayes2 `Depends: RBesT`, and every one of its imports is already in the closure, so
it adds nothing but its own 1.3 MB binary. Verified in the browser:
`example_model("single_agent")` samples through the real rstan backend and
`summary(fit, interval_prob = ...)` returns the interval probabilities.

`WASM_PKG_STAN=1` is what makes both work; see "Cross-compiling any other package".

### Rebuilding rstan and StanHeaders

```sh
git clone --depth 1 --branch v1.12-0 https://github.com/Novartis/RBesT.git vendor/BesT
cd vendor/BesT
Rscript tools/make-ds.R              # data/*.rda and R/sysdata.rda are generated, not tracked
cd tools/webr/docker
RBEST_SRC=$(git -C ../../.. rev-parse --show-toplevel) docker compose build
RBEST_SRC=... RBEST_OUT=... RBEST_VARIANTS=notbb docker compose run --rm build
cd -
Rscript tools/vendor-wasm-repo.R     # -> vendor/wasm-repo/
Rscript tools/build-library.R --resolve
```

This also builds the image `tools/build-wasm-pkg.sh` uses, so it is still the first
step on a new machine. `make-ds.R` is not optional: `.onAttach()` reads
`pkg_create_date` out of `R/sysdata.rda`, so without it RBesT installs cleanly and then
fails on `library(RBesT)`. Behind a TLS-intercepting proxy, point `CORP_CERTS_DIR` at a
directory of `*.pem` CA roots and add the same roots to the Docker daemon's trust
store, or every https fetch in the build fails.

### Rebuilding stanliWebR and miraiWebR

Both are pure R, so they need no Docker — the host R builds them directly:

```sh
Rscript tools/build-first-party.R    # pkg/* -> build/wasm-extra/ (or name packages)
Rscript tools/vendor-wasm-repo.R     # -> vendor/wasm-repo/
```

The host R must match webR's on the minor version (4.6); R warns on load about a package
built under a newer one, so the script refuses to run otherwise.

### Cross-compiling any other package

`tools/build-wasm-pkg.sh` reuses the same image to build a CRAN package that
`repo.r-wasm.org` does not carry:

```sh
tools/build-wasm-pkg.sh jinjar 0.3.2   # -> build/wasm-extra/
Rscript tools/vendor-wasm-repo.R       # folds it into vendor/wasm-repo/
```

jinjar is the reason this exists. rbmi imports it, and it has no wasm build anywhere
because the nlohmann/json copy vendored inside inja writes `auto* const` where
libstdc++ gives a raw pointer but Emscripten's libc++ gives `std::__wrap_iter`, so it
does not compile. `tools/wasm-patches/jinjar_0.3.2.patch` is the two-line upstream fix
([nlohmann/json#3082](https://github.com/nlohmann/json/pull/3082), released in v3.10.4),
applied automatically when the versions match.

Two environment variables:

* `WASM_PKG_DEPS` — rwasm's `dependencies`, `FALSE` by default, so only the named
  package is cross-compiled. Its runtime dependencies come from `repo.r-wasm.org` when
  `build-library.R` resolves the manifest, and building the closure here only fails for
  everything that needs a Fortran toolchain (`mvtnorm`, `quadprog`, `statmod`, and
  `RcppEigen`, which wants a `libFortranRuntime.a` the image does not have). Set `NA`
  to build the closure anyway.
* `WASM_PKG_STAN=1` — prepare an rstantools package first. Such a package cannot be
  cross-compiled as it comes from CRAN: `configure` runs `rstantools::rstan_config()`,
  and the `src/Makevars` it generates asks the *host* `RcppParallel` for link flags,
  which are native — `wasm-ld: error: unknown file type: .../libtbb.so`. Stan math also
  instantiates a TBB `task_scheduler_observer` as a namespace-scope global, so the
  module imports two TBB entry points nothing in wasm defines, and since the observer
  is a global that surfaces as a `dlopen()` failure rather than a runtime error. The
  preparation drops `PKG_LIBS` (keeping `PKG_CXXFLAGS`, which carries the
  `-DSTAN_THREADS` Stan math needs to compile at all) and compiles in
  `tools/wasm-patches/webr-tbb-stubs.cpp`. The result is written as `src/Makevars.webr`,
  rwasm's override hook, which also passes `--no-configure` so `rstan_config()` cannot
  put the TBB flags back.

Then serve it (see below) and open <http://127.0.0.1:8080>.

## Running

```sh
Rscript serve.R      # needs httpuv
python3 serve.py     # no dependencies
```

### Why you cannot just open index.html

Both scripts exist only to send two headers:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Without them the page is not [cross-origin isolated](https://developer.mozilla.org/en-US/docs/Web/API/crossOriginIsolated),
`SharedArrayBuffer` is unavailable, and webR silently falls back to a `PostMessage`
channel that cannot do `readline()`, `menu()`, `browser()` or interrupt a running
computation — i.e. the terminal stops working. The app refuses to start in that case
rather than pretending to work. `crossOriginIsolated` is shown in the toolbar.

This is also why the site cannot be deployed to GitHub Pages, which cannot set those headers.
See [DEPLOY.md](DEPLOY.md) for hosting options, including Cloudflare Pages.

## Installing more packages

The mounted image is fixed at build time, but the session is also pointed at
`https://repo.r-wasm.org`, so anything else on that mirror can be added at runtime:

```r
install.packages("praise")   # or webr::install("praise")
library(praise)
```

`js/session.js` runs `webr::shim_install()` at boot so plain `install.packages()` works,
the same thing the [webR REPL demo](https://webr.sh) does. Change `PACKAGE_REPO` there
to point at an internal mirror.

Three things worth knowing:

* **This is the only part of the app that uses the network after boot.** Nothing is
  fetched unless you ask for it, so the offline behaviour is unchanged.
* **Installs go to `/home/web_user/R/library`**, not into the image, which is a
  read-only mount. That directory comes *first* on `.libPaths()`, so an installed
  package shadows a pinned one exactly as it would in an ordinary R session. Installing
  something the Stan stack depends on, `posterior` say, can therefore break `brm()`.
* **Nothing survives a reload.** The VFS is in memory; re-run the install.

Versions are also not pinned here. The mirror rebuilds continuously, so a package
installed at runtime may have been built against newer dependencies than the ones in
`lib/MANIFEST.tsv`.

## Updating dependencies

`lib/MANIFEST.tsv` pins all 142 packages by version and sha256, and is the only build
artifact that is committed. `build-library.R` defaults to `--frozen`, which downloads
exactly those files and fails loudly on any checksum mismatch or 404.

To deliberately move versions:

```sh
Rscript tools/vendor-wasm-repo.R          # write vendor/wasm-repo's PACKAGES index
Rscript tools/build-library.R --resolve   # re-resolve, rewrite the manifest
git diff lib/MANIFEST.tsv                 # review exactly what moved
Rscript tools/pack-library.R              # rebuild the image
# re-run the example end to end, then commit the manifest
```

A version bump of R, stanli, stanliWebR, brms or rbmi changes the numbers
`workspace/webr-examples/reproducibility.R` produces. Run it once, copy the printed fingerprints into
its `expected` vector, and commit them with the manifest; the smoke test fails until
you do.

The index is derived from the committed tarballs, so it is gitignored rather than
committed; `--resolve` is the only mode that reads it, and it fails loudly asking for
`vendor-wasm-repo.R` when it is absent. `--frozen` resolves each tarball straight from
`lib/MANIFEST.tsv` and needs no index at all.

To bump webR, edit `WEBR_VERSION` in `tools/fetch-webr.sh`. **The R version webR bundles
must match `R_CONTRIB` in `tools/build-library.R`** (webR 0.6.0 → R 4.6.0 → `contrib/4.6`).
Wasm binaries built for another R version will not load; `fetch-webr.sh` prints the
bundled version so you can check.

### The manifest detects drift, it does not guarantee reproducibility

r-universe does not archive old builds — its API reports an `_expires` date roughly three
months out — and repo.r-wasm.org rebuilds packages in place under the same URL. Either
breaks a pinned sha256, and `--frozen` then fails loudly. That is correct behaviour, but
it means the real reproducible artifacts are the downloaded tarballs, which
`wasm-repo.yml` publishes as the `-packages.tar` asset of the pinned Release
(`fetch-wasm-repo.sh` unpacks them into `vendor/pkgcache/`), and the built
`lib/library.tar.gz`. The seven in `vendor/wasm-repo/` are not committed, so they have
to be fetched or rebuilt before a `--frozen` run can succeed; `build-library.R` names
the missing file and the script to run.

## Layout
```
index.html            four-pane shell; phone bottom bar
favicon.svg           site icon
js/config.js          where the library image lives; rewritten by tools/deploy.sh and deploy.yml
js/version.js         the app version: "dev" here, stamped from package.json by tools/make-dist.sh
js/session.js         webR boot, checks packages are installed
js/library.js         fetches the library image once and mounts it in every R
js/workers.js         background webR workers for miraiWebR
js/layout.js          desktop / phone mode and the visible pane on a phone
js/split.js           drag-to-resize gutters
js/terminal.js        xterm.js terminal; queued editor lines are echoed at the R prompt
js/editor.js          CodeMirror 5 (v6 is excluded: it needs a bundler); also data tabs
js/theme.js           Auto/Light/Dark; CSS follows the OS, this handles the override
js/plots.js           canvasNewPage / canvasImage message handling
js/viewer.js          HTML viewer; inlines VFS assets into a sandboxed iframe
js/files.js           virtual filesystem browser (upload, download, edit)
js/environment.js     Environment pane
js/packages.js        Packages pane
js/datagrid.js        View() grid: virtual scrolling over rows paged from R
js/help.js            rendered help with in-pane link navigation
js/traceback.js       Traceback tab: live call stack while debugging, error tracebacks
js/rname.js           R name quoting for code the panes send to the console
r/webrapp.R           R side of the panes, attached as tools:webrapp
tools/                build scripts; everything they produce is gitignored
tools/convert-bamdd.R adapts the upstream Novartis bamdd exercises to this session
tools/convert-bamdd-slides.R  the same for the R code of the bamdd Leiden 2026 slides
tools/build-wasm-pkg.sh    cross-compiles one CRAN package to wasm (needs Docker)
tools/build-first-party.R  builds pkg/stanliWebR and pkg/miraiWebR for wasm (pure R, no Docker)
tools/wasm-patches/        source fixes applied before cross-compiling
tools/vendor-wasm-repo.R   assembles vendor/wasm-repo from the build outputs
tools/fetch-wasm-repo.sh   downloads the published bundle pinned in lib/WASM_REPO instead
tools/make-dist.sh         assembles the deployable site into dist/
tools/deploy.sh            manual Cloudflare deploy (Pages + R2)
tools/check-cors.sh        checks the image's CORS header from each site origin
tools/smoke-test.mjs       Playwright check: isolation, mount, a real gMAP() fit, the
                           panes; --device "Pixel 7" checks the phone layout
_headers              COOP/COEP for Cloudflare Pages; mirrors serve.py / serve.R
lib/MANIFEST.tsv      the pinned package set (committed)
lib/WASM_REPO         release pin for the cross-compiled packages (committed)
vendor/wasm-repo/     local wasm repo: RBesT, OncoBayes2, rstan, StanHeaders, jinjar,
                      stanliWebR, miraiWebR (not committed -- rebuild, then
                      vendor-wasm-repo.R)
workspace/            the R home directory as the session starts: copied in at startup
workspace/bamdd_leiden2026_exercises.R  bamdd workshop exercises (converted)
workspace/slides/     R code of the workshop slides (converted); data/ and stan/ beside it
workspace/webr-examples/  brms, stanli, rbmi, reproducibility and parallel examples
```

## Deployment

The app is designed to be served locally and offline, but it can also be hosted on
Cloudflare Pages with the filesystem image in R2, built and deployed by the two
workflows under `.github/workflows/`. The headers in requirement 1 are not optional and
rule out GitHub Pages. See [DEPLOY.md](DEPLOY.md) for the one-time account setup and the
order things have to be brought up in.

## Credits

`stanli` by Sean Talts; the original brms-in-the-browser work, wasm builds and proof of
concept by Andrew Johnson and Staffan Betnér —
see [the Stan forums thread](https://discourse.mc-stan.org/t/stan-stanr-and-brms-running-client-side-in-the-browser-via-webr/41549).
[webR](https://github.com/r-wasm/webr) by George Stagg and the webR authors. The bamdd
case studies and workshop material by Sebastian Weber, Björn Holzhauer, Lukas Widmer
and Andrew Bean ([Novartis/bamdd](https://github.com/Novartis/bamdd)).

## How to cite

If this app helped your work, please cite it:

> Widmer L (2026). *BAMDD with webR/brms/stanli*. https://github.com/luwidmer/bamdd-webr

and the software that does the actual work. In the app, `citation("brms")`,
`citation("stanli")`, `citation("RBesT")` and so on print the preferred reference of
each package you used. In particular:

* brms: Bürkner P-C (2017). brms: An R Package for Bayesian Multilevel Models Using
  Stan. *Journal of Statistical Software*, 80(1), 1–28.
  [doi:10.18637/jss.v080.i01](https://doi.org/10.18637/jss.v080.i01)
* Stan: Stan Development Team. *Stan Modeling Language Users Guide and Reference
  Manual*. https://mc-stan.org
* stanli, the Stan interpreter by Sean Talts, and [webR](https://github.com/r-wasm/webr),
  through their `citation()` entries.
* The case studies: [Applied Modelling in Drug Development](https://opensource.nibr.com/bamdd/).

## Issues and contributions

Bug reports and pull requests are welcome on the
[issue tracker](https://github.com/luwidmer/bamdd-webr/issues). Problems
in brms, stanli, webR or the other packages belong upstream; please check here first
whether one is specific to running in the browser.

## Licence

Copyright (C) 2026 Novartis Pharma AG.

This project is free software under the **GNU General Public License, version 3 or
later** — see [LICENSE](LICENSE). The exceptions are the `stanliWebR` and `miraiWebR`
packages in [pkg/stanliWebR](pkg/stanliWebR) and [pkg/miraiWebR](pkg/miraiWebR), which are
**Apache-2.0** so that they stay usable outside this project; the text is at
[pkg/stanliWebR/inst/LICENSE.md](pkg/stanliWebR/inst/LICENSE.md) (and the same in
miraiWebR) and ships inside each installed package. The bamdd workshop material,
`workspace/bamdd_leiden2026_exercises.R`, `workspace/slides/`, `workspace/data/` and
`workspace/stan/`, is converted from
[Novartis/bamdd](https://github.com/Novartis/bamdd) and keeps its **GPL-2**; the text is
at [workspace/LICENSE-GPL-2](workspace/LICENSE-GPL-2).

GPL-3 rather than GPL-2 is deliberate: Apache-2.0 is one-way compatible with GPL-3, but
its patent-termination clause counts as an added restriction under GPL-2, so the two
could not be combined there. webR bundles R as `GPL-2 | GPL-3`, so the GPL-3 option is
available.

These terms cover this repository only. The mounted library redistributes 139
third-party packages under their own licences, and serving it is a distribution act —
[BOM.md](BOM.md) records every one of them and [DEPLOY.md](DEPLOY.md) covers the
obligations that follow.
