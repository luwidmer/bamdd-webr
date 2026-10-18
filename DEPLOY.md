# Deployment

The primary way to run BAMDD with webR/brms/stanli is locally with `serve.R` or `serve.py`,
which is what the offline design is for. This document covers hosting it publicly on
Cloudflare, built and deployed from GitHub Actions. The `webr-for-brms` Pages project
and R2 bucket names below are infrastructure identifiers and keep the old name.

## The two hard requirements

1. **Cross-origin isolation.** The page must be served with
   `Cross-Origin-Opener-Policy: same-origin` and
   `Cross-Origin-Embedder-Policy: require-corp`. Without both, `SharedArrayBuffer` is
   unavailable and webR falls back to a `PostMessage` channel that cannot do
   `readline()`, `menu()`, `browser()` or interrupt a running computation — the terminal
   stops working. [js/session.js](js/session.js) refuses to boot in that state rather
   than degrade silently. [`_headers`](_headers) supplies these on Pages.
2. **A ~137 MB asset.** `lib/library.tar.gz` holds 141 wasm packages, and Cloudflare
   Pages rejects any single asset over 25 MiB. It is therefore served from R2 instead,
   and `tools/make-dist.sh` leaves it out of the upload. Plus roughly 56 MB of vendored
   webR, so a first visit downloads ~193 MB, browser-cached afterwards.

GitHub Pages cannot set custom response headers, so requirement 1 is unreachable there.
That is why it was ruled out.

## How the pipeline fits together

Two workflows, because the cross-compile is slow and changes a few times a year while
the deploy must be fast.

```
.github/workflows/wasm-repo.yml   manual; Docker; no Cloudflare credentials
  clone Novartis/RBesT -> docker compose build -> build seven packages
  -> Release asset + PR updating lib/MANIFEST.tsv and lib/WASM_REPO

.github/workflows/deploy.yml      per push
  image:  R2 HEAD on a content-addressed key; on a miss, frozen build + pack + upload
  build:  make-dist.sh, then tools/smoke-test.mjs against a local serve.py
  deploy: rewrite dist/js/config.js to the R2 URL, wrangler pages deploy, smoke test again
```

### The wasm package bundle

Seven of the 141 packages have no usable WebAssembly build anywhere: rstan,
StanHeaders, RBesT, OncoBayes2 and jinjar are cross-compiled in Docker, and stanliWebR
and miraiWebR are first-party. Rebuilding them takes Docker and about an hour, so the
deploy does not do it; it downloads a bundle that `wasm-repo.yml` built once.

* **Produced by `wasm-repo.yml`.** It builds all seven, collects them with
  `tools/vendor-wasm-repo.R` (which also writes the package index) and packs
  `vendor/wasm-repo/` into `wasm-repo-<date>-<sha>.tar.gz`. A verify job unpacks that
  archive, builds and packs the library from it and runs `tools/smoke-test.mjs`. Only
  then does a publish job attach the archive to a GitHub Release of the same name and
  open a pull request that changes two files together:
  * `lib/WASM_REPO`: the Release tag and the sha256 of the archive;
  * `lib/MANIFEST.tsv`: its seven `local:vendor/wasm-repo` rows, one sha256 per package.
* **Every other pinned package rides along.** The same Release carries
  `wasm-repo-<date>-<sha>-packages.tar`: the remote packages of `lib/MANIFEST.tsv`
  exactly as `--resolve` downloaded and hashed them, pinned by `PACKAGES_SHA256` in
  `lib/WASM_REPO`. repo.r-wasm.org rebuilds packages in place under the same URL, and
  its CDN then serves either build for up to a week; r-universe expires old builds
  after about three months. Either breaks a sha256 pin, so neither the verify job nor
  a deploy downloads from them: both build from this archive.
* **Consumed by [tools/fetch-wasm-repo.sh](tools/fetch-wasm-repo.sh)**, in `deploy.yml`
  and on any machine without Docker. It refuses either archive unless its sha256
  matches, then unpacks the bundle into `vendor/wasm-repo/` and the packages into
  `vendor/pkgcache/`. `deploy.yml` downloads both with `gh release download`
  first, so it also works while the repository is private; anywhere else the script
  downloads them itself, which needs a public repository. The frozen `build-library.R`
  then checks every package against the manifest, so each one is verified twice.
* **The two files move in lockstep.** `R CMD INSTALL` is not byte-reproducible, so any
  local rebuild of one of the seven changes its sha256, and a manifest holding that
  checksum no longer matches the published bundle: the frozen build then fails on it.
  After changing `pkg/*`, a patch in `tools/wasm-patches/` or a pinned version of the
  five, re-run `wasm-repo.yml` and merge its pull request rather than committing a
  locally resolved manifest.
* **`PENDING`** means no bundle has been published; the fetch, and so the deploy, stops
  with an error rather than building an image without these packages.
* **The image key covers it.** `lib/WASM_REPO` is one of the hashed build inputs below,
  so a new bundle produces, and uploads, a new image.
* **Releases are the durable copy.** Unlike r-universe builds they do not expire, and
  unlike repo.r-wasm.org they never change. Do not delete a Release that a commit
  still pins.

The pull request is opened with the workflow's own token, so it does not trigger
`deploy.yml`; its checks are the verify job that ran before publishing.

### Deploying by hand

Until the workflows' triggers are enabled (step 3 of "Bringing it up" below),
deployments are made by hand with [tools/deploy.sh](tools/deploy.sh), which performs the
same steps:

```sh
npx wrangler login                   # or export CLOUDFLARE_API_TOKEN=... instead
export R2_PUBLIC_BASE=https://assets.lukaswidmer.dev
export SITE_URL=https://bamdd.lukaswidmer.dev   # default: https://webr-for-brms.pages.dev
tools/deploy.sh --smoke
```

`wrangler login` is the easier route and keeps the credential off the command line and out
of shell history, but its OAuth consent covers a fixed scope list that includes
`pages:write` and **no R2 scope**, so check `npx wrangler r2 bucket list` before relying on
it for the upload; a 403 there means that step needs a scoped API token. `npx wrangler
whoami` prints the account IDs and the credential's permissions. `CLOUDFLARE_ACCOUNT_ID` is
only needed when the credential reaches more than one account.

It keys the R2 object on the image's own bytes, so an unchanged image is never
re-uploaded, and it refuses to deploy unless [tools/check-cors.sh](tools/check-cors.sh)
finds a usable `Access-Control-Allow-Origin` for `SITE_URL` and for
`https://webr-for-brms.pages.dev`. That is the one failure that is invisible to whoever
runs the deploy and total for everyone else. `deploy.yml` runs the same check before its
smoke tests.

### Why the image is keyed on inputs

`R2_KEY` is `library-<sha256 of MANIFEST.tsv + WASM_REPO + three build scripts>.tar.gz`.
Hashing the *output* would churn on every run: `tools/pack-library.R` is not
byte-reproducible, drifting ~200 B between packs from tar and gzip timestamps. Keying on
inputs means an unchanged dependency set re-uses the uploaded object, so a CSS change
deploys in about a minute and uploads nothing.

Only that object gets `Cache-Control: immutable`. `/vendor/*` gets a one-day max-age
instead, because those paths are unversioned and a webR bump would otherwise be masked.

## One-time setup

Nothing in the repository can do these, and `deploy.yml` fails loudly until they exist.

1. A Pages project, direct-upload rather than Git integration — CI drives the deploy, so
   Cloudflare never needs to build anything.
2. An R2 bucket. Start on the managed `r2.dev` development URL (see "Starting on
   r2.dev" below) and move to a custom domain before real use (see "Custom domains").
3. **COEP for the cross-origin fetch.** Under `require-corp` a cross-origin subresource
   must carry `Cross-Origin-Resource-Policy: cross-origin` **or** pass a CORS check.
   Set the bucket CORS policy either way; on a custom domain, also add the CORP header
   with a Transform Rule, because having both means a failure in one does not take the
   app down. Verify with `curl -I` before wiring up CI: getting this wrong fails inside
   the wasm worker at mount time, which is awkward to debug.

   ```json
   [
     {
       "AllowedOrigins": [
         "https://bamdd.lukaswidmer.dev",
         "https://webr-for-brms.pages.dev",
         "https://*.webr-for-brms.pages.dev"
       ],
       "AllowedMethods": ["GET", "HEAD"],
       "ExposeHeaders": ["content-length"],
       "MaxAgeSeconds": 86400
     }
   ]
   ```

   Both origins are needed: an R2 wildcard does not match the bare apex, and every
   Pages deployment — production included — also gets a hashed preview hostname, which
   is the URL `wrangler-action` returns and the post-deploy smoke test uses. An
   `AllowedOrigins` entry must not contain a path, or the policy is rejected.
4. Repository **secrets**, defined under Settings → Environments rather than at
   repository level, so only a job declaring that environment receives them. Two
   environments, so neither job holds a credential it does not need:

   | Environment | Used by | `CLOUDFLARE_API_TOKEN` scope | Reviewers |
   | --- | --- | --- | --- |
   | `r2-write` | the `image` job | Account → Workers R2 Storage: Edit | none |
   | `production` | the `deploy` job | Account → Cloudflare Pages: Edit | optional gate on publishing |

   Both also need `CLOUDFLARE_ACCOUNT_ID`, which is not really secret but which
   `wrangler-action` reads as one. Restrict each token to the one account, set an
   expiry, and diary the renewal — expiry surfaces as a 403 partway through a deploy.
   Set `production`'s deployment branches to `main` only. Once `pull_request` is a
   trigger, the `image` job runs with the R2 token for any branch pushed to this
   repository (never for forks). Restricting `r2-write` to `main` as well would close
   that, but then every pull request fails at the `image` job, so keep write access to
   the repository tight instead.

   Splitting the token is what keeps the approval gate usable: with a single
   environment on both jobs, required reviewers would prompt twice per run.

   Fork pull requests never receive secrets for `pull_request` events regardless, so
   the environments bound which *jobs* hold credentials, not which forks.

   **While the repository is private**, environment secrets and deployment branches
   need GitHub Pro (or Team/Enterprise); on Free they exist only in public repositories.
   Required reviewers need a public repository even on Pro, so the optional approval
   gate on `production` waits until the repository is public.

   Repository **variables** (Variables tab, plain) are deliberately not secrets,
   because they are baked into `dist/js/config.js` and served to every visitor —
   masking them to `***` would only obstruct debugging a failed mount:

   | Name | Example |
   | --- | --- |
   | `R2_PUBLIC_BASE` | `https://assets.lukaswidmer.dev` (first `https://pub-<hash>.r2.dev`) |
   | `R2_BUCKET` | `webr-for-brms` |
   | `PAGES_PROJECT` | `webr-for-brms` |
   | `SITE_URL` | `https://bamdd.lukaswidmer.dev`; optional, smoke-tested after a deploy from `main`; CORS is checked from it and from `https://<PAGES_PROJECT>.pages.dev` |

5. **Check the licensing.** The image redistributes webR, brms, stanli, a
   cross-compiled `rstan`/`RBesT`/`OncoBayes2`, and 141 R packages in total under a range
   of licences (GPL, LGPL, Apache-2.0, BSD, MIT). Redistributing them from your own
   domain is a different act from a user downloading them from CRAN, and an automated
   deploy repeats it on every green build. [BOM.md](BOM.md) has the component list and a
   licence summary; `lib/MANIFEST.tsv` is the authoritative pin.
6. **Let workflows open pull requests.** Under Settings → Actions → General, enable
   "Allow GitHub Actions to create and approve pull requests"; without it the publish job
   of `wasm-repo.yml` creates the Release and then fails to open its pull request.

### Running wrangler behind a TLS-intercepting proxy

Only needed for the one-time setup; CI is unaffected. Two separate trust stores are in
play, and fixing one does not fix the other:

```sh
npm config set cafile /absolute/path/to/corp-roots.pem   # so npm/npx can fetch wrangler
export NODE_EXTRA_CA_CERTS=/absolute/path/to/corp-roots.pem   # so wrangler can call the API
```

`npm config` does **not** expand `~`, and npm ignores `NODE_EXTRA_CA_CERTS` for registry
traffic. Never reach for `strict-ssl=false`: it disables verification rather than
teaching the client whom to trust. An explicit proxy needs no extra configuration —
npm and wrangler 4 both read `http_proxy`/`https_proxy` from the environment, and
wrangler says so on startup.

### Starting on r2.dev

Enabling the bucket's public development URL is the quickest way to get something
testable, and costs nothing in the repository: `R2_PUBLIC_BASE` is a variable, so moving
to a custom domain later is a one-line change plus a re-deploy.

Two things are genuinely different there, and the first is the one that decides whether
this works at all:

* **No Transform Rules**, so the `Cross-Origin-Resource-Policy` header cannot be set.
  Cloudflare gates WAF, caching, access control and Bot Management behind a custom
  domain, and rules are zone-scoped while `r2.dev` is not in your zone. COEP therefore
  has to be satisfied by the **CORS** route alone. That holds as long as webR fetches
  the image in CORS mode, which a plain `fetch()` is by default — but it is an
  assumption about webR's internals, not a guarantee. `tools/smoke-test.mjs` is what
  proves or disproves it, which is why it runs against the deployment and not only
  against a local server.
* **No CDN caching.** `Cache-Control: immutable` is stored as object metadata and still
  reaches the browser, so repeat visits are unaffected, but every *cold* visitor pulls
  the full ~137 MB from R2 rather than an edge node, and `r2.dev` is rate limited by an
  amount Cloudflare does not publish. Fine for a handful of testers. Do not point a
  workshop room at it.

Neither is a reason to delay a first deployment; both are reasons not to announce one.

### Custom domains

The site is served at `https://bamdd.lukaswidmer.dev` **and** at
`https://webr-for-brms.pages.dev`, which is kept live rather than redirected. The image
is at `https://assets.lukaswidmer.dev`. All are on the same Cloudflare account, the
first and last in the `lukaswidmer.dev` zone.

1. **Pages:** project `webr-for-brms` → Custom domains → add `bamdd.lukaswidmer.dev`.
   With the zone on Cloudflare the DNS record is created for you. `_headers` applies
   unchanged; the `pages.dev` hostnames keep working.
2. **R2:** bucket `webr-for-brms` → Settings → Custom Domains → add
   `assets.lukaswidmer.dev`.
3. **CORS:** add `https://bamdd.lukaswidmer.dev` to the bucket policy above. Keep the
   `pages.dev` entries: CI smoke-tests every deployment on its hashed preview hostname.
4. **CORP and a wildcard ACAO:** Rules → Transform Rules → *Modify Response Header* on
   the zone, when hostname equals `assets.lukaswidmer.dev`, set both
   `Cross-Origin-Resource-Policy: cross-origin` and `Access-Control-Allow-Origin: *`.
   The bucket policy echoes the request's `Origin`, and with two live origins an edge
   cache can replay one origin's echo to the other, which then fails CORS. The image is
   public and fetched without credentials, so the wildcard gives nothing away. The
   bucket policy stays as the fallback.
5. **Check before repointing anything.** The image is now cached at the edge, and a
   cached copy must still answer every origin. Prime the cache with one origin and
   probe the other, then the first again:

   ```sh
   img=https://assets.lukaswidmer.dev/<key>      # the key tools/deploy.sh printed
   tools/check-cors.sh "$img" https://bamdd.lukaswidmer.dev \
     https://webr-for-brms.pages.dev https://bamdd.lukaswidmer.dev
   curl -sI "$img" | grep -iE '^(cross-origin-resource-policy|cf-cache-status)'
   ```

   Every origin must report `*`, and `cf-cache-status` must be `HIT` on a repeat. A
   `cf-cache-status` of `DYNAMIC` means the object is not cached; add a Cache Rule
   marking the hostname eligible for cache.
6. **Repoint and re-deploy:** set `R2_PUBLIC_BASE` to `https://assets.lukaswidmer.dev`
   and `SITE_URL` to `https://bamdd.lukaswidmer.dev`, then run `deploy.yml` (or
   `tools/deploy.sh --smoke`). Both check CORS from both origins before smoke testing.
   The object already in R2 is reused, because its key depends on the build inputs
   rather than on where it is served. Open `https://webr-for-brms.pages.dev` once by
   hand as well: the full smoke test runs only on the preview and on `SITE_URL`.
7. **Then disable the bucket's `r2.dev` URL**, so the rate-limited route cannot be
   linked to by accident.

## Bringing it up

Stages 1 and 2 are independent; 3 needs both.

Both workflows ship with `workflow_dispatch` triggers only: GitHub offers a manual run
button for workflows on the default branch, and a live `pull_request` trigger would fire
against a `PENDING` `lib/WASM_REPO` and fail.

1. **Do the one-time setup above.**
2. **Run `wasm-repo.yml` once** and merge the pull request it opens. This needs only
   `GITHUB_TOKEN`, so the heaviest part of the pipeline is proven before any Cloudflare
   account exists. Review `lib/MANIFEST.tsv` carefully: the seven `local:vendor/wasm-repo`
   rows change sha256 on every rebuild because `R CMD INSTALL` output is not
   byte-reproducible, and `--resolve` re-queries the four remote repositories, so unrelated
   r-universe movement can appear in the same diff.
3. **Enable the triggers.** Add `push: {branches: [main]}` and `pull_request:` to
   `deploy.yml`. That pull request is itself the first live run.
4. **Move off `r2.dev`** as in "Custom domains" above, before any announced use.

Worth adding at step 3: a monthly `schedule:` trigger for `wasm-repo.yml`, so that
upstream drift (new versions, in-place rebuilds, expired r-universe builds) surfaces as
a pull request on a schedule. Deploys are unaffected by it: they build from the pinned
Release, and the R2 object is the durable artifact.

## Releasing

The version is `"version"` in [package.json](package.json) and nowhere else:
`tools/make-dist.sh` stamps it into `dist/js/version.js`, the About dialog shows it, and
the smoke test checks that it does. To release, bump it (and the root entries of
`package-lock.json`, or run `npm install`), merge, deploy, and tag that commit
`v<version>`.

## Testing it locally

`tools/make-dist.sh` builds exactly what gets uploaded and fails if any asset exceeds
25 MiB. `--with-image` additionally copies `lib/library.tar.gz` in, which is for local
testing only and never reaches Pages.
```sh
npm ci && npx playwright install chromium   # once
bash tools/make-dist.sh --with-image
python3 serve.py --root dist 8080 &
node tools/smoke-test.mjs http://127.0.0.1:8080
```

On a managed machine `playwright install` can stall indefinitely: the download
succeeds, then unpacking ~1,900 files into a new `Chromium.app` is gated by endpoint
security. Drive an already-installed browser instead, which needs no download:

```sh
PLAYWRIGHT_CHANNEL=chrome node tools/smoke-test.mjs http://127.0.0.1:8080
```

The smoke test asserts cross-origin isolation, waits for the boot overlay to clear, then
runs `gMAP()` out of `RBesT` — enough to prove the mount, a cross-compiled `.so`
dlopening, and the TBB stubs resolving. CI runs the same script twice: locally, and
again against the deployment, where it is the only check that exercises R2's CORS/CORP
configuration.

## Rejected alternatives

**Split the image into sub-25 MiB chunks and stay entirely on Pages.** Fetch several
parts, concatenate them into a `Blob`, and mount that. More invasive than it sounds: a
JS-side `WORKERFS` mount needs the **v1** filesystem image format (`.data` plus
`.js.metadata`), whereas `tools/pack-library.R` produces the **v2** format — a tar with
an appended index that only the R-side `webr::mount()` parses, from a single URL.
Switching to v1 means Emscripten's `file_packager`, i.e. the Docker path the main build
deliberately avoids.

**Accept a degraded app.** Drop cross-origin isolation, let webR use the `PostMessage`
channel, and lose `readline()` and interrupt support. The editor, plots and file pane
would still work and sampling would still run, but it gives up the feature the project
was built around, and would mean relaxing the hard failure in `Session.boot()`.

## A note on scope

The offline design exists partly because CDN fetches are unreliable behind a
TLS-intercepting corporate proxy. A deployment reintroduces exactly that dependency, so
treat it as an additional target rather than a replacement for `serve.R` / `serve.py`.
