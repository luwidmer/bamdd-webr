import { Session, rString } from './session.js';
import { Terminal } from './terminal.js';
import { Editor } from './editor.js';
import { requestCompletions } from './complete.js';
import { Plots } from './plots.js';
import { Viewer } from './viewer.js';
import { FileTree } from './files.js';
import { EnvironmentPane } from './environment.js';
import { PackagesPane } from './packages.js';
import { DataGrid } from './datagrid.js';
import { HelpPane } from './help.js';
import { TracebackPane } from './traceback.js';
import { rName } from './rname.js';
import { installSplitters } from './split.js';
import * as layout from './layout.js';
import * as theme from './theme.js';
import { APP_VERSION } from './version.js';

const $ = (id) => document.getElementById(id);

// print_help() in r/webrapp.R writes rendered help pages here.
const HELP_DIR = '/tmp/webrapp-help/';

const bootEl = $('boot');
const bootStatus = $('boot-status');
const bootProgress = $('boot-progress');
const bootError = $('boot-error');

function fail(err) {
  bootProgress.hidden = true;
  bootStatus.textContent = 'Startup failed';
  bootError.hidden = false;
  bootError.textContent = err instanceof Error ? err.message : String(err);
  console.error(err);
}

async function main() {
  let terminal;
  let restarting = false;
  let debugging = false;
  // Where R last said the debugger stopped; the innermost frame's position.
  let debugAt = null;
  let plots;
  let viewer;
  let help;
  let editor;
  const grids = new Map();

  const session = new Session({
    stdout: (line) => {
      terminal?.writeLine(line);
      // R's debugger reports where it stopped as "debug at <file>#<line>: <expr>".
      const at = /^debug at (\/[^#]+)#(\d+): /.exec(line);
      if (at) openAt(at[1], Number(at[2]), { debug: true });
    },
    stderr: (line) => terminal?.writeLine(`\x1b[31m${line}\x1b[0m`),
    warn: (line) => terminal?.writeLine(`\x1b[33m! ${line}\x1b[0m`),
    prompt: (p) => terminal?.handlePrompt(p),
    canvasNewPage: () => plots?.newPage(),
    canvasImage: (image) => {
      plots?.addImage(image);
      // On a phone a plot must not pull the user away from the console mid-script.
      showOutput('plots', { switchPane: false });
    },
    browse: async (url) => {
      try {
        if (url.startsWith(HELP_DIR)) help.showFile(await session.readFile(url));
        else await viewer.showFile(session.webR, url);
      } catch (err) {
        terminal?.writeLine(`\x1b[31mCould not display ${url}: ${err.message}\x1b[0m`);
      }
    },
    view: (title, data) => {
      if (data.webrapp_restart) {
        restartR();
        return;
      }
      if (data.webrapp_error) {
        offerTraceback(data.webrapp_error.values[0]);
        return;
      }
      const id = data.webrapp_view_id?.values?.[0];
      if (id) openGrid(id);
      // Something called the data viewer directly, bypassing View() in r/webrapp.R.
      else viewer?.showTable(title, data);
    },
    pager: async (path, title, deleteFile) => {
      const text = await session.readFile(path);
      help?.showText(title || path, text);
      if (deleteFile) await session.webR.FS.unlink(path);
    },
    // Each worker is a whole R; a phone would run out of memory long before cores.
    workersUnavailable: () => (layout.isPhone() ? 'they are disabled in the phone layout to save memory' : ''),
    workerOutput: (index, type, line) => {
      terminal?.writeLine(`\x1b[90m[worker ${index}]\x1b[0m ${type === 'stderr' ? `\x1b[31m${line}\x1b[0m` : line}`);
    },
    workersChanged: ({ workers, ready, busy, queued }) => {
      const pill = $('status-workers');
      pill.hidden = workers === 0;
      const parts = [`${busy}/${workers} busy`];
      if (queued) parts.push(`${queued} queued`);
      $('workers-label').textContent = ready < workers ? `starting ${workers} workers` : `workers ${parts.join(' · ')}`;
      pill.title = `${workers} webR worker(s): ${busy} busy, ${queued} task(s) queued`;
      pill.classList.toggle('busy', busy > 0 || ready < workers);
      $('workers-menu').querySelector('[data-action="cancel"]').disabled = busy + queued === 0;
    },
  });

  // Panes must exist before boot so the first R output has somewhere to land.
  bootEl.hidden = false;
  $('app').hidden = false;

  terminal = new Terminal($('tab-console'), {
    onInput: (line) => session.stdin(line),
    onInterrupt: () => session.interrupt(),
    onPrompt: (prompt) => setDebugging(/^Browse\[\d+\]> $/.test(prompt)),
    // Asked only at a prompt, where R is free to answer.
    complete: (line, cursor) => requestCompletions(query, line, cursor),
    theme: theme.resolved(),
    onBusyChange: (busy) => {
      const pill = $('status-busy');
      pill.textContent = restarting ? 'restarting' : busy ? 'running' : 'idle';
      pill.classList.toggle('busy', busy);
      $('btn-interrupt').disabled = !busy;
      $('btn-interrupt-console').disabled = !busy;
      if (!busy) onIdle();
    },
  });

  plots = new Plots($('plot-stage'), {
    onCountChange: (count, index) => {
      $('plot-count').textContent = count ? `(${index + 1}/${count})` : '';
      $('btn-plot-prev').disabled = index <= 0;
      $('btn-plot-next').disabled = index >= count - 1;
      for (const id of ['btn-plot-popout', 'btn-plot-save', 'btn-plot-clear']) $(id).disabled = count === 0;
    },
    onRerender: (page, width, height) => replayPage(page, width, height),
  });

  viewer = new Viewer($('view-viewer'), { onShow: () => showOutput('viewer') });

  const isBusy = () => terminal.busy;
  const query = (fn, ...args) => session.query(fn, ...args);
  const run = (code) => {
    terminal.enqueue(code);
    if (layout.isPhone()) layout.showPane('console');
  };

  help = new HelpPane($('view-help'), { query, isBusy, onShow: () => showOutput('help'), scheme: theme.resolved() });

  editor = new Editor($('editor-host'), $('editor-tabs'), {
    onSelect: ({ custom }) => {
      for (const id of ['btn-run', 'btn-run-all', 'btn-source', 'btn-source-menu', 'btn-save']) $(id).disabled = custom;
    },
    theme: theme.resolved(),
    onRun: (code) => {
      terminal.enqueue(code);
    },
    complete: (line, cursor) => (ready && !restarting && !terminal.busy ? requestCompletions(query, line, cursor) : null),
  });

  // Keys a phone keyboard lacks, shown while the console or the editor has the keyboard.
  for (const row of document.querySelectorAll('.key-row')) {
    const target = row.dataset.target === 'console' ? terminal : editor;
    const pane = row.closest('.pane');
    // Keep focus, and with it the on-screen keyboard, where it is.
    row.addEventListener('mousedown', (e) => e.preventDefault());
    row.addEventListener('click', (e) => {
      const key = e.target.closest('button')?.dataset.key;
      if (key) target.pressKey(key);
    });
    pane.addEventListener('focusin', (e) => {
      if (e.target === terminal.term.textarea || e.target.closest('.CodeMirror')) pane.classList.add('typing');
    });
    pane.addEventListener('focusout', () => pane.classList.remove('typing'));
  }

  const files = new FileTree($('file-tree'), session, {
    onOpenFile: (path, text) => {
      if (text === null) {
        terminal.writeLine(`\x1b[33m${path} is not a text file; not opening.\x1b[0m`);
        return;
      }
      editor.open(path, text);
      layout.showPane('editor');
    },
  });

  const environment = new EnvironmentPane($('side-env'), {
    query,
    // A Browse[n]> prompt resolves names in the debugged frame, so say where to look.
    onView: (name, frame) => {
      const sym = rName(name);
      if (frame > 0) run(`View(get(${rString(name)}, envir = sys.frame(${frame})), ${rString(name)})`);
      else if (debugging) run(`View(get(${rString(name)}, envir = globalenv()), ${rString(name)})`);
      else run(`View(${sym})`);
    },
  });
  const traceback = new TracebackPane($('view-traceback'), {
    onSelectFrame: async (frame) => {
      environment.selectFrame(frame);
      selectTab('side', 'env');
      layout.badge('side');
      await refreshSide();
    },
    onOpen: (file, line) => openAt(file, line),
  });
  const packages = new PackagesPane($('side-pkgs'), {
    query,
    run,
    onHelp: (pkg) => help.openIndex(pkg),
  });

  async function openGrid(id) {
    const grid = new DataGrid(id, { query, isBusy });
    let title;
    try {
      title = await grid.init();
    } catch (err) {
      terminal.writeLine(`\x1b[31mCould not open the data viewer: ${err.message}\x1b[0m`);
      return;
    }
    grids.set(id, grid);
    editor.openCustom(id, title, grid.element, () => {
      grids.delete(id);
      // The view died with the old R.
      if (restarting) return;
      // Released later if R is busy now; the object only costs memory meanwhile.
      if (terminal.busy) pendingRelease.add(id);
      else session.query('view_release', id);
    });
    layout.showPane('editor');
  }
  const pendingRelease = new Set();

  // Pane refreshes run only between commands, and not before the R helpers are loaded.
  let ready = false;
  let idleTimer;
  function onIdle() {
    if (refreshPending) refreshPlot();
    if (!ready) return;
    clearTimeout(idleTimer);
    idleTimer = setTimeout(async () => {
      if (terminal.busy) return;
      for (const id of pendingRelease) await session.query('view_release', id);
      pendingRelease.clear();
      for (const grid of grids.values()) grid.retry();
      if (debugging) await refreshStack();
      await refreshSide();
    }, 100);
  }

  // The live call stack, refreshed at every Browse[n]> prompt.
  let stackShown = false;
  async function refreshStack() {
    let stack;
    try {
      stack = await session.query('debug_stack');
    } catch (err) {
      traceback.showMessage(`Could not read the call stack: ${err.message}`);
      return;
    }
    if (!stack.length) return;
    const inner = stack.at(-1);
    if (!inner.file && debugAt) Object.assign(inner, debugAt);
    if (!stack.some((f) => f.frame === environment.frameSelected)) environment.selectFrame(inner.frame);
    traceback.showStack(stack, environment.frameSelected);
    if (!stackShown) {
      stackShown = true;
      showOutput('traceback', { switchPane: false });
    }
  }

  async function refreshSide(full = false) {
    if (!ready || terminal.busy) return;
    const view = activeTab.side;
    try {
      if (view === 'env') await environment.refresh();
      else if (view === 'pkgs' && (full || !packages.loaded)) await packages.refresh();
      else if (view === 'pkgs') await packages.refreshAttached();
      else if (view === 'files') await files.refresh();
    } catch (err) {
      const pane = view === 'pkgs' ? packages : environment;
      pane.showError(`Could not read from R: ${err.message}`);
    }
  }

  async function saveActive() {
    const path = editor.activePath;
    if (!path) return;
    await session.writeFile(path, editor.getValue());
    editor.markClean(path);
    terminal.writeLine(`\x1b[90m# saved ${path}\x1b[0m`);
  }

  // The main half of the split button repeats the last choice, as in RStudio.
  let sourceEcho = false;
  async function sourceActive(echo = sourceEcho) {
    const path = editor.activePath;
    if (!path) return;
    sourceEcho = echo;
    $('btn-source').textContent = echo ? 'Source with echo' : 'Source';
    if (!editor.isClean(path)) await saveActive();
    run(`source(${rString(path)}${echo ? ', echo = TRUE' : ''})`);
  }

  async function restartR() {
    if (restarting) return;
    restarting = true;
    ready = false;
    terminal.reset();
    terminal.write('\n\x1b[90m# Restarting R…\x1b[0m\n');
    $('status-busy').textContent = 'restarting';
    for (const id of [...grids.keys()]) editor.close(`custom:${id}`);
    pendingRelease.clear();
    // R numbers plot pages from 1 again, so old pages could no longer be replayed.
    plots.clear();
    let rVersion;
    try {
      ({ rVersion } = await session.restart(() => {}));
      const { width, height } = paneSize();
      await session.setDeviceSize(width, height);
    } catch (err) {
      bootEl.hidden = false;
      fail(err);
      return;
    }
    $('status-r').textContent = `R ${rVersion}`;
    restarting = false;
    ready = true;
    $('status-busy').textContent = terminal.busy ? 'running' : 'idle';
    await files.refresh();
    await refreshSide(true);
  }

  // ---- debugging: toolbar, current line, traceback links

  function setDebugging(on) {
    if (on === debugging) return;
    debugging = on;
    $('debug-actions').hidden = !on;
    if (on) return;
    editor.setDebugLine(null);
    debugAt = null;
    stackShown = false;
    traceback.finish();
    if (environment.frameSelected > 0) environment.selectFrame(0);
  }

  /** Open `path` at a 1-based line; `debug` marks it as where the debugger stopped. */
  async function openAt(path, line, { debug = false } = {}) {
    if (debug) debugAt = { file: path, line };
    try {
      if (!editor.tabs.has(path)) editor.open(path, await session.readFile(path));
    } catch (err) {
      terminal.writeLine(`\x1b[33m! Could not open ${path}: ${err.message}\x1b[0m`);
      return;
    }
    if (debug) editor.setDebugLine(path, line - 1);
    else editor.goToLine(path, line - 1);
    // Stepping happens in the console; on a phone, flag the editor rather than jump to it.
    if (debug) layout.badge('editor');
    else layout.showPane('editor');
  }

  // Each error's links act on that error, found by the marker on their console line.
  const errorLinks = [];
  async function offerTraceback(id) {
    const command = terminal.lastCommand;
    const marker = await terminal.writeMarked('\x1b[2m  \u25b8 Show traceback   \u25b8 Rerun with debug\x1b[0m');
    errorLinks.push({ marker, id, command });
    if (errorLinks.length > 50) errorLinks.shift().marker.dispose();
  }
  const errorAt = (row) => errorLinks.find((e) => e.marker.line === row);

  async function showTraceback(id) {
    if (terminal.busy) {
      terminal.writeLine('\x1b[33m! R is busy; show the traceback when it finishes.\x1b[0m');
      return;
    }
    try {
      const { message, rows } = await session.query('traceback_rows', id);
      traceback.showError(message, rows);
      showOutput('traceback');
    } catch (err) {
      terminal.writeLine(`\x1b[31m${err.message}\x1b[0m`);
    }
  }

  terminal.addLinkRule(/\u25b8 Show traceback/g, (m, row) => {
    const e = errorAt(row);
    if (e) showTraceback(e.id);
  });
  terminal.addLinkRule(/\u25b8 Rerun with debug/g, (m, row) => {
    const e = errorAt(row);
    if (e?.command) run(`rerun_with_debug({\n${e.command}\n})`);
  });
  terminal.addLinkRule(/(\/[^\s#:]+\.[Rr])#(\d+)/g, (m) => openAt(m[1], Number(m[2])));

  for (const button of document.querySelectorAll('#debug-actions [data-debug]')) {
    button.addEventListener('click', () => terminal.enqueue(button.dataset.debug));
  }
  // RStudio's debugger keys.
  const DEBUG_KEYS = { F10: 'n', 'Shift+F4': 's', 'Shift+F6': 'f', 'Shift+F5': 'c', 'Shift+F8': 'Q' };
  window.addEventListener('keydown', (e) => {
    if (!debugging) return;
    const cmd = DEBUG_KEYS[`${e.shiftKey ? 'Shift+' : ''}${e.key}`];
    if (!cmd) return;
    e.preventDefault();
    terminal.enqueue(cmd);
  });

  // One active tab per tabbed pane; each tab has a body and, optionally, actions.
  const activeTab = { side: 'files', output: 'plots' };

  function selectTab(group, name) {
    activeTab[group] = name;
    for (const node of document.querySelectorAll(`[data-group="${group}"]`)) {
      if (node.classList.contains('tabs')) {
        for (const tab of node.querySelectorAll('.tab')) {
          tab.classList.toggle('active', tab.dataset.view === name);
        }
      } else {
        node.classList.toggle('active', node.dataset.view === name);
      }
    }
  }

  function showOutput(name, { switchPane = true } = {}) {
    selectTab('output', name);
    if (switchPane) layout.showPane('output');
    else layout.badge('output');
  }

  // Where plots are drawn. On a phone the Output pane is often hidden, but every pane
  // fills the same cell, so whichever one is showing has the right size.
  function paneSize() {
    const panes = ['pane-output', 'pane-editor', 'pane-console', 'pane-side'].map($);
    const pane = panes.find((p) => p.clientWidth > 0) ?? panes[0];
    const head = $('pane-output').querySelector('.pane-head').offsetHeight || 34;
    return {
      width: pane.clientWidth - 16,
      height: pane.clientHeight - head - 16,
    };
  }

  // A page whose bitmap was drawn for an older device size is re-rendered from R's
  // plot history when it is shown. Only the visible page is done, so dragging a
  // splitter never replays a whole session's worth of plots.
  let refreshPending = false;
  let refreshing = false;

  // Null when R has no recording for the page, or is busy: callers keep what they have.
  async function replayPage(page, width, height) {
    // Injecting R code while a model is sampling would interleave with the run.
    if (terminal.busy) return null;
    try {
      return await session.replayPlotPage(page, width, height);
    } catch (err) {
      terminal.writeLine(`\x1b[31mCould not re-render plot ${page}: ${err.message}\x1b[0m`);
      return null;
    }
  }

  async function refreshPlot() {
    const index = plots.index;
    if (index < 0 || !plots.isStale(index) || refreshing) return;
    if (terminal.busy) {
      refreshPending = true;
      return;
    }
    refreshPending = false;
    refreshing = true;
    try {
      const bitmap = await replayPage(plots.pageNumber(index));
      // No recording: the page predates the history or has aged out of it, so the
      // bitmap already on screen stays, rescaled by CSS as before.
      if (bitmap) plots.replacePage(index, bitmap);
      else plots.markFresh(index);
    } finally {
      refreshing = false;
    }
  }

  for (const tab of document.querySelectorAll('.tabs[data-group] .tab')) {
    const group = tab.parentElement.dataset.group;
    tab.addEventListener('click', () => {
      selectTab(group, tab.dataset.view);
      if (group === 'output' && tab.dataset.view === 'plots') refreshPlot();
      if (group === 'side') refreshSide();
    });
  }
  selectTab('side', 'files');
  selectTab('output', 'plots');

  $('btn-run').addEventListener('click', () => editor.runSelectionOrLine());
  $('btn-run-all').addEventListener('click', () => editor.runAll());
  $('btn-save').addEventListener('click', () => saveActive());
  $('btn-source').addEventListener('click', () => sourceActive());
  installMenu($('btn-source-menu'), $('source-menu'), (item) => sourceActive(item.dataset.echo === 'true'));
  installMenu($('btn-workers-stop'), $('workers-menu'), (item) => {
    if (item.dataset.action === 'cancel') session.pool.cancelAll();
    else session.pool.close();
  });
  $('btn-interrupt').addEventListener('click', () => terminal.interrupt());
  $('btn-interrupt-console').addEventListener('click', () => terminal.interrupt());
  $('btn-restart').addEventListener('click', () => restartR());
  $('btn-refresh-files').addEventListener('click', () => files.refresh());
  $('btn-refresh-env').addEventListener('click', () => refreshSide(true));
  $('btn-refresh-pkgs').addEventListener('click', () => refreshSide(true));
  $('btn-install-pkg').addEventListener('click', () => packages.install());
  $('btn-plot-prev').addEventListener('click', () => {
    plots.prev();
    refreshPlot();
  });
  $('btn-plot-next').addEventListener('click', () => {
    plots.next();
    refreshPlot();
  });
  $('btn-plot-save').addEventListener('click', () => plots.savePNG());
  $('btn-plot-clear').addEventListener('click', async () => {
    plots.clear();
    await session.clearPlotHistory();
  });
  $('btn-plot-popout').addEventListener('click', () => {
    try {
      plots.popOut();
    } catch (err) {
      terminal.writeLine(`\x1b[31m${err.message}\x1b[0m`);
    }
  });

  $('btn-new-file').addEventListener('click', async () => {
    const name = prompt('New file name', 'untitled.R');
    if (!name) return;
    const path = `${session.homedir}/${name}`;
    await session.writeFile(path, '');
    editor.open(path, '');
    await files.refresh();
  });

  $('btn-upload').addEventListener('click', () => $('upload-input').click());
  $('upload-input').addEventListener('change', async (e) => {
    for (const file of e.target.files) {
      const bytes = new Uint8Array(await file.arrayBuffer());
      await session.webR.FS.writeFile(`${session.homedir}/${file.name}`, bytes);
      terminal.writeLine(`\x1b[90m# uploaded ${file.name}\x1b[0m`);
    }
    e.target.value = '';
    await files.refresh();
  });

  $('btn-download').addEventListener('click', async () => {
    const path = files.selected ?? editor.activePath;
    if (!path) {
      terminal.writeLine('\x1b[33m! Select a file in the Files pane first.\x1b[0m');
      return;
    }
    const bytes = await session.readBytes(path);
    // Copy into a fresh buffer: the view is backed by wasm memory.
    const blob = new Blob([new Uint8Array(bytes)], { type: 'application/octet-stream' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = path.split('/').pop();
    a.click();
    URL.revokeObjectURL(url);
    terminal.writeLine(`\x1b[90m# downloaded ${path}\x1b[0m`);
  });

  window.addEventListener('keydown', (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 's') {
      e.preventDefault();
      saveActive();
    }
  });

  $('theme-select').value = theme.mode();
  $('theme-select').addEventListener('change', (e) => theme.setMode(e.target.value));
  theme.onChange((scheme) => {
    editor.setTheme(scheme);
    terminal.setTheme(scheme);
    help.setTheme(scheme);
  });

  const { rVersion, packages: versions, thirdParty } = await session.boot((pct, msg) => {
    bootProgress.value = pct;
    bootStatus.textContent = msg;
  });

  // Debug handle, and what tools/smoke-test.mjs drives R through.
  window.__app = { session, terminal, editor, isRestarting: () => restarting };

  $('status-r').textContent = `R ${rVersion}`;
  $('status-r').classList.add('ok');

  $('about-version').textContent = APP_VERSION;
  $('about-third-party').textContent = thirdParty;
  const versionTable = $('about-versions');
  for (const { name, version } of [
    { name: 'R', version: rVersion },
    ...versions,
    { name: 'cross-origin isolated', version: self.crossOriginIsolated ? 'yes' : 'no' },
  ]) {
    const row = versionTable.insertRow();
    row.insertCell().textContent = name;
    row.insertCell().textContent = version;
  }
  $('btn-about').addEventListener('click', () => $('about-dialog').showModal());

  // Fetched on first expand, not at boot: 35 kB of licence text nobody usually opens.
  const licence = $('about-licence');
  licence.addEventListener('toggle', async () => {
    if (!licence.open || licence.dataset.loaded) return;
    licence.dataset.loaded = 'yes';
    const target = $('about-licence-text');
    try {
      const res = await fetch('LICENSE');
      if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
      target.textContent = await res.text();
    } catch (err) {
      licence.dataset.loaded = '';
      target.textContent = `Could not load LICENSE: ${err.message}\nThe full text is in the repository root.`;
    }
  });

  // The graphics device must match the pane, otherwise plot text is oversized and
  // legends get clipped. Debounced because each change is a round trip into R.
  let resizeTimer;
  const syncDeviceSize = () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(async () => {
      const { width, height } = paneSize();
      try {
        await session.setDeviceSize(width, height);
      } catch (err) {
        terminal.writeLine(`\x1b[31mCould not resize the graphics device: ${err.message}\x1b[0m`);
        return;
      }
      plots.markAllStale();
      refreshPlot();
    }, 250);
  };

  installSplitters($('app'), {
    onResize: () => {
      terminal.safeFit();
      syncDeviceSize();
    },
  });
  new ResizeObserver(syncDeviceSize).observe($('pane-output'));

  layout.onLayoutChange(() => {
    terminal.safeFit();
    editor.refresh();
    syncDeviceSize();
  });
  layout.onPaneChange((pane) => {
    if (pane === 'editor') requestAnimationFrame(() => editor.refresh());
    if (pane === 'output' && activeTab.output === 'plots') refreshPlot();
    if (pane === 'side') refreshSide();
  });

  const startPath = `${session.homedir}/bamdd_leiden2026_exercises.R`;
  editor.open(startPath, await session.readFile(startPath));
  await files.refresh();

  // Size the device before the session is usable, so even the very first plot is
  // drawn at pane size rather than at the placeholder default.
  const initial = paneSize();
  await session.setDeviceSize(initial.width, initial.height);

  ready = true;
  await refreshSide();
  bootEl.hidden = true;
  terminal.safeFit();
}

main().catch(fail);

/** A button's drop-down menu: click or arrow keys, closed by Escape or a click outside. */
function installMenu(toggle, menu, onChoose) {
  const items = [...menu.querySelectorAll('button')];
  const enabled = () => items.filter((b) => !b.disabled);
  const close = () => {
    menu.hidden = true;
    toggle.setAttribute('aria-expanded', 'false');
  };
  toggle.addEventListener('click', (e) => {
    e.stopPropagation();
    menu.hidden = !menu.hidden;
    toggle.setAttribute('aria-expanded', String(!menu.hidden));
    if (!menu.hidden) enabled()[0]?.focus();
  });
  for (const item of items) {
    item.addEventListener('click', () => {
      close();
      onChoose(item);
    });
  }
  menu.addEventListener('keydown', (e) => {
    const list = enabled();
    const i = list.indexOf(document.activeElement);
    if (e.key === 'ArrowDown') list[(i + 1) % list.length]?.focus();
    else if (e.key === 'ArrowUp') list[(i - 1 + list.length) % list.length]?.focus();
    else if (e.key === 'Escape') {
      close();
      toggle.focus();
    } else return;
    e.preventDefault();
  });
  document.addEventListener('click', (e) => {
    if (!menu.hidden && !menu.contains(e.target)) close();
  });
}
