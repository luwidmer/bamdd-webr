import { WebR } from '../vendor/webr/webr.mjs';
import { LIBRARY_IMAGE_URL } from './config.js';
import { WorkerPool } from './workers.js';
import { mountLibrary } from './library.js';

const LIBRARY_MOUNT = '/library';
const HOME = '/home/web_user';

// Installs land here rather than in the mounted image, which is read-only. It comes
// first on the library path so an installed package wins over a pinned one, as in an
// ordinary R session -- see README "Installing more packages".
const USER_LIBRARY = `${HOME}/R/library`;

// Repointable at an internal mirror. Only used on demand; nothing is fetched at boot.
const PACKAGE_REPO = 'https://repo.r-wasm.org';

// Checked for presence on the library path at startup, but deliberately NOT loaded:
// the examples call library() themselves, so the session behaves like a plain R REPL.
const REQUIRED_PACKAGES = ['brms', 'stanli', 'stanliWebR', 'miraiWebR', 'rstan', 'RBesT', 'OncoBayes2', 'mmrm', 'rbmi'];

// Built from pkg/ in this repository, so not counted as third-party in the About dialog.
const FIRST_PARTY_PACKAGES = ['stanliWebR', 'miraiWebR'];

// workspace/ in the repository, installed into the home directory with the same layout.
const WORKSPACE = [
  'bamdd_leiden2026_exercises.R',
  ...[
    '01_overview', '02_hist_control', '03_priors', '03b_prior_example_blrm',
    '04_dose_finding', '05_mmrm', '06_longitudinal_data', '07_time_to_event',
  ].map((name) => `slides/${name}.R`),
  'data/longitudinal.csv',
  'stan/conflict_normal_student-t.stan',
  'LICENSE-GPL-2',
  ...[
    'brms-kidney.R', 'stanli-eight-schools.R', 'rbmi-bayes-stanli.R', 'reproducibility.R',
    'parallel.R',
  ].map((name) => `webr-examples/${name}`),
];

/** Escape a JS string for embedding in an R double-quoted literal. */
export function rString(value) {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

function rValue(value) {
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new Error(`Not a finite number: ${value}`);
    return String(value);
  }
  if (typeof value === 'boolean') return value ? 'TRUE' : 'FALSE';
  return rString(value);
}

export class Session {
  constructor(callbacks = {}) {
    this.callbacks = callbacks;
    this.console = null;
    this.webR = null;
    this.homedir = HOME;
    // Background R sessions for miraiWebR; R reaches them through webr::eval_js().
    this.pool = new WorkerPool({
      baseUrl: new URL('vendor/webr/', location.href).href,
      libraryUrl: new URL(LIBRARY_IMAGE_URL, location.href).href,
      libraryMount: LIBRARY_MOUNT,
      unavailable: () => callbacks.workersUnavailable?.() ?? '',
      onOutput: (index, type, line) => callbacks.workerOutput?.(index, type, line),
      onChange: (info) => callbacks.workersChanged?.(info),
    });
    globalThis.__webrPool = this.pool;
  }

  async boot(onProgress = () => {}) {
    // The SharedArrayBuffer channel is what makes readline()/menu()/interrupt work.
    // Without it webR silently degrades to PostMessage and the terminal is unusable,
    // so refuse to start rather than hand over a half-working session.
    if (!self.crossOriginIsolated) {
      throw new Error(
        'This page is not cross-origin isolated, so webR cannot use SharedArrayBuffer.\n\n' +
        'The R terminal needs it for readline() and for interrupting a running model.\n\n' +
        'Serve the directory with the required headers instead of opening index.html directly:\n' +
        '    Rscript serve.R        (or)        python3 serve.py\n' +
        'then browse to http://127.0.0.1:8080'
      );
    }

    onProgress(5, 'Starting R…');
    // Must be absolute: webR resolves baseUrl inside the worker, so a relative path
    // would be joined onto the worker's own location and doubled up.
    const baseUrl = new URL('vendor/webr/', location.href).href;
    this.webR = new WebR({ baseUrl });
    await this.webR.init();
    this.live = this.webR;

    onProgress(35, 'Mounting package library…');
    this.readLoop(this.webR);
    await this.mountLibrary();
    await this.configurePackages();

    onProgress(70, 'Checking packages…');
    await this.verifyPackages();

    onProgress(85, 'Installing output hooks…');
    await this.installHooks();
    await this.loadHelpers();

    onProgress(90, 'Preparing example files…');
    await this.installExamples();

    const rVersion = await this.webR.evalRString('paste(R.version$major, R.version$minor, sep=".")');
    const packages = await this.packageVersions();
    const thirdParty = await this.thirdPartyCount();
    onProgress(100, 'Ready');
    return { rVersion, packages, thirdParty };
  }

  /**
   * A fresh R in a new worker, as RStudio's Restart R. The filesystem lives in the
   * worker, so /home/web_user is copied across; the workspace is not.
   */
  async restart(onProgress) {
    // Output still queued by the old R (its last prompt) must not reach the console.
    this.live = null;
    const files = await this.snapshot(this.homedir);
    this.pool.close();
    this.webR.close();
    this.deviceWidth = undefined;
    this.deviceHeight = undefined;
    const result = await this.boot(onProgress);
    // After installExamples(), so edited copies of the examples win.
    for (const { path, isDir, bytes } of files) {
      if (isDir) await this.webR.evalRVoid(`dir.create(${rString(path)}, showWarnings = FALSE, recursive = TRUE)`);
      else await this.webR.FS.writeFile(path, bytes);
    }
    return result;
  }

  /** Every file under `dir`, parents before children. */
  async snapshot(dir) {
    const out = [];
    for (const entry of await this.listDir(dir)) {
      if (entry.isDir) {
        out.push({ path: entry.path, isDir: true });
        out.push(...(await this.snapshot(entry.path)));
      } else {
        out.push({ path: entry.path, isDir: false, bytes: await this.webR.FS.readFile(entry.path) });
      }
    }
    return out;
  }

  /** Versions of webR and the pinned packages, for the About dialog. */
  async packageVersions() {
    const names = ['webr', ...REQUIRED_PACKAGES];
    const versions = await this.webR.evalRString(`
      paste(vapply(
        c(${names.map(rString).join(', ')}),
        function(p) as.character(packageVersion(p)),
        character(1)
      ), collapse = " ")
    `);
    const parsed = versions.split(' ');
    return names.map((name, i) => ({ name, version: parsed[i] }));
  }

  /** How many packages in the mounted library come from third parties. */
  async thirdPartyCount() {
    return Number(await this.webR.evalRString(`
      as.character(length(setdiff(
        basename(dirname(Sys.glob(file.path(${rString(LIBRARY_MOUNT)}, "*", "DESCRIPTION")))),
        c(${FIRST_PARTY_PACKAGES.map(rString).join(', ')})
      )))
    `));
  }

  /**
   * webR's bundled Console class only forwards stdout/stderr/prompt/canvas and warns
   * about everything else, so drive the output queue directly to also get `browse`
   * (HTML viewer), `view` and `pager`.
   */
  async readLoop(webR) {
    for (;;) {
      let msg;
      try {
        msg = await webR.read();
      } catch (err) {
        if (webR !== this.live) return;
        throw err;
      }
      if (webR !== this.live) {
        if (msg.type === 'closed') return;
        continue;
      }
      switch (msg.type) {
        case 'stdout':
          this.callbacks.stdout?.(msg.data);
          break;
        case 'stderr':
          this.callbacks.stderr?.(msg.data);
          break;
        case 'prompt':
          this.callbacks.prompt?.(msg.data);
          break;
        case 'canvas':
          if (msg.data.event === 'canvasImage') this.callbacks.canvasImage?.(msg.data.image);
          else if (msg.data.event === 'canvasNewPage') this.callbacks.canvasNewPage?.();
          break;
        case 'browse':
          this.callbacks.browse?.(msg.data.url);
          break;
        case 'view':
          this.callbacks.view?.(msg.data.title, msg.data.data);
          break;
        case 'pager':
          this.callbacks.pager?.(msg.data.path, msg.data.title, msg.data.deleteFile);
          break;
        case 'closed':
          return;
        default:
          this.callbacks.warn?.(`Unhandled webR output message: ${msg.type}`);
      }
    }
  }

  async installHooks() {
    // Without viewer_install(), htmlwidgets and gt fall back to utils::browseURL(),
    // which calls system() and fails under Emscripten.
    await this.webR.evalRVoid('webr::viewer_install()');
    await this.webR.evalRVoid('webr::pager_install()');
    await this.installPlotHistory();
    await this.setDeviceSize(800, 500);
  }

  /** The R side of the Environment, Packages, data viewer and Help panes. */
  async loadHelpers() {
    const res = await fetch(new URL('r/webrapp.R', location.href));
    if (!res.ok) throw new Error(`Missing r/webrapp.R (HTTP ${res.status})`);
    const path = '/tmp/webrapp.R';
    await this.webR.FS.writeFile(path, new Uint8Array(await res.arrayBuffer()));
    await this.webR.evalRVoid(`
      local({
        env <- attach(NULL, name = "tools:webrapp")
        sys.source(${rString(path)}, envir = env, keep.source = FALSE)
      })
      # Source positions drive the debugger's current line and the traceback links.
      options(keep.source = TRUE, error = quote(as.environment("tools:webrapp")$on_error()))
    `);
  }

  /**
   * Call a helper from r/webrapp.R and parse its JSON. Only valid while R is idle:
   * webR serves these requests between console reads, so during a running command it
   * would block until the command finishes. Callers check first.
   */
  async query(fn, ...args) {
    const call = `as.environment("tools:webrapp")$${fn}(${args.map(rValue).join(', ')})`;
    const out = await this.webR.evalRString(call);
    return out === '' ? null : JSON.parse(out);
  }

  /**
   * Keep a replayable recording of every plot page, so a resized pane can re-render
   * at the new size instead of rescaling a bitmap drawn for the old one.
   *
   * webr::canvas() opens with displayListOn = FALSE, so R records nothing by default
   * and recordPlot() would come back empty; setDeviceSize() turns the display list on
   * for every device it opens. Recording then happens only when a page ends or when a
   * resize asks for it, never per command, because recordPlot() copies the whole list.
   *
   * The entry points hang off an option rather than a global binding so that
   * rm(list = ls(all = TRUE)) in the user's session cannot break plot handling.
   */
  async installPlotHistory() {
    await this.webR.evalRVoid(`
      local({
        store <- new.env(parent = emptyenv())
        store$pages <- list()
        store$n <- 0L
        store$replaying <- FALSE
        # Each recording retains the objects it drew, so the history must be bounded.
        limit <- 30L

        on_canvas <- function() {
          d <- dev.cur()
          d > 1L && identical(names(d), "canvas")
        }

        # Page numbers are list names, so dropping the oldest never renumbers the rest.
        save_page <- function(...) {
          if (store$replaying || store$n < 1L || !on_canvas()) return(invisible(FALSE))
          rec <- recordPlot()
          if (length(rec[[1]]) == 0L) return(invisible(FALSE))
          store$pages[[as.character(store$n)]] <- rec
          if (length(store$pages) > limit) {
            store$pages <- store$pages[order(as.integer(names(store$pages)))]
            store$pages <- store$pages[-seq_len(length(store$pages) - limit)]
          }
          invisible(TRUE)
        }

        # Runs after the page exists, so the device can be checked; this keeps the
        # counter in step with the canvasNewPage messages the Plots pane counts.
        start_page <- function(...) {
          if (store$replaying || !on_canvas()) return(invisible(NULL))
          store$n <- store$n + 1L
          invisible(NULL)
        }

        setHook("before.plot.new", save_page)
        setHook("plot.new", start_page)
        setHook("before.grid.newpage", save_page)
        setHook("grid.newpage", start_page)

        options(webr_plot_history = list(
          save = save_page,
          clear = function() {
            store$pages <- list()
            store$n <- 0L
            invisible(NULL)
          },
          replay = function(page) {
            key <- as.character(page)
            if (is.null(store$pages[[key]])) return(invisible(FALSE))
            store$replaying <- TRUE
            on.exit(store$replaying <- FALSE, add = TRUE)
            replayPlot(store$pages[[key]])
            invisible(TRUE)
          }
        ))
      })
    `);
  }

  /**
   * Text in a plot is sized relative to the device, so a small square device makes
   * labels look oversized and clips legends. Matching the device to the pane keeps
   * the proportions close to a desktop session. Applies to subsequently drawn plots;
   * pages already drawn are re-rendered on demand by replayPlotPage().
   *
   * The device is deliberately the pane's CSS pixel size, which keeps webR's bitmap
   * (always 2x the device) pixel-exact on a 2x display. It also means plots are drawn
   * 3/4 of native size, because canvas hard-codes 72 dpi while a CSS pixel is 1/96
   * inch. The two cannot both be satisfied here: sharpness needs a bitmap-to-device
   * factor of at least 1.333 * devicePixelRatio, and webR's is fixed at 2. Scaling
   * only the text is not a way out either -- ggplot2 takes its sizes from its theme
   * and ignores the device pointsize, and canvas pins par("cin") to the 12pt metric.
   */
  async setDeviceSize(width, height, pointsize = 12) {
    const w = Math.max(240, Math.round(width));
    const h = Math.max(240, Math.round(height));
    if (w === this.deviceWidth && h === this.deviceHeight) return;
    this.deviceWidth = w;
    this.deviceHeight = h;
    this.devicePointsize = pointsize;
    // options(device=) only applies to the next device R opens, so close the current
    // one -- but record the page it is showing first, because closing it discards the
    // display list that re-rendering needs.
    await this.webR.evalRVoid(`
      getOption("webr_plot_history")$save()
      options(device = function(...) {
        webr::canvas(width = ${w}, height = ${h}, pointsize = ${pointsize})
        dev.control(displaylist = "enable")
      })
      while (!is.null(dev.list())) dev.off()
    `);
  }

  /**
   * Re-render one recorded page at the given size, returning an ImageBitmap. Null when
   * the page predates the history or has been dropped from it, in which case the caller
   * keeps the bitmap it already has.
   *
   * captureR() draws into its own capturing canvas, which emits no canvas messages, so
   * the re-render cannot be confused with a plot the user just drew.
   */
  async replayPlotPage(page, width = this.deviceWidth, height = this.deviceHeight) {
    // The page on screen is only recorded when the next one starts, so record it now
    // or the most recent plot -- the one most likely to be re-rendered -- has nothing
    // to replay from.
    await this.webR.evalRVoid('getOption("webr_plot_history")$save()');
    const shelter = await new this.webR.Shelter();
    try {
      const { images } = await shelter.captureR(
        `getOption("webr_plot_history")$replay(${page})`,
        {
          captureGraphics: {
            width: Math.max(240, Math.round(width)),
            height: Math.max(240, Math.round(height)),
            pointsize: this.devicePointsize,
          },
        }
      );
      return images[0] ?? null;
    } finally {
      await shelter.purge();
    }
  }

  async clearPlotHistory() {
    await this.webR.evalRVoid('getOption("webr_plot_history")$clear()');
  }

  async mountLibrary() {
    await mountLibrary(this.webR, new URL(LIBRARY_IMAGE_URL, location.href).href, LIBRARY_MOUNT);
  }

  async configurePackages() {
    // shim_install() makes install.packages() work, as the webR REPL demo does.
    await this.webR.evalRVoid(`
      dir.create(${rString(USER_LIBRARY)}, recursive = TRUE, showWarnings = FALSE)
      .libPaths(c(${rString(USER_LIBRARY)}, ${rString(LIBRARY_MOUNT)}, .libPaths()))
      options(
        webr_pkg_repos = ${rString(PACKAGE_REPO)},
        repos = c(CRAN = ${rString(PACKAGE_REPO)})
      )
      webr::shim_install()
    `);
  }

  async verifyPackages() {
    // find.package() locates a package without loading its namespace.
    const missing = await this.webR.evalRString(`
      paste(Filter(
        function(p) length(find.package(p, quiet = TRUE)) == 0,
        c(${REQUIRED_PACKAGES.map(rString).join(', ')})
      ), collapse = ", ")
    `);
    if (missing !== '') {
      const paths = await this.webR.evalRString('paste(.libPaths(), collapse=", ")');
      throw new Error(
        `Package(s) not found on the library path: ${missing}\n\n` +
        `.libPaths(): ${paths}\n\n` +
        'The filesystem image is incomplete. Rebuild it:\n' +
        '    Rscript tools/build-library.R\n' +
        '    Rscript tools/pack-library.R'
      );
    }
  }

  async installExamples() {
    const dirs = [...new Set(WORKSPACE.filter((path) => path.includes('/'))
      .map((path) => path.slice(0, path.lastIndexOf('/'))))];
    for (const d of dirs) {
      await this.webR.evalRVoid(`dir.create(${rString(`${this.homedir}/${d}`)}, showWarnings = FALSE, recursive = TRUE)`);
    }
    for (const path of WORKSPACE) {
      const res = await fetch(new URL(`workspace/${path}`, location.href));
      if (!res.ok) throw new Error(`Missing workspace file: workspace/${path} (HTTP ${res.status})`);
      const bytes = new Uint8Array(await res.arrayBuffer());
      await this.webR.FS.writeFile(`${this.homedir}/${path}`, bytes);
    }
    await this.webR.evalRVoid(`setwd(${rString(this.homedir)})`);
  }

  stdin(line) {
    this.webR.writeConsole(line);
  }

  interrupt() {
    // R may be blocked waiting on a worker, and only notices the interrupt once
    // that wait ends, so end it.
    this.pool.cancelAll();
    this.webR.interrupt();
  }

  async readFile(path) {
    const bytes = await this.webR.FS.readFile(path);
    return new TextDecoder().decode(bytes);
  }

  async readBytes(path) {
    return this.webR.FS.readFile(path);
  }

  async writeFile(path, text) {
    await this.webR.FS.writeFile(path, new TextEncoder().encode(text));
  }

  async listDir(path) {
    const node = await this.webR.FS.lookupPath(path);
    const entries = Object.entries(node.contents ?? {});
    const out = [];
    for (const [name, child] of entries) {
      if (name === '.' || name === '..') continue;
      out.push({
        name,
        path: path === '/' ? `/${name}` : `${path}/${name}`,
        isDir: Boolean(child.isFolder ?? child.contents),
        size: child.usedBytes ?? 0,
      });
    }
    out.sort((a, b) => (a.isDir === b.isDir ? a.name.localeCompare(b.name) : a.isDir ? -1 : 1));
    return out;
  }
}
