#!/usr/bin/env node
//
// Boot the app in a real browser and prove the parts a static file check cannot:
// cross-origin isolation, the filesystem-image mount, and a real Stan model .so.
//
//   npm ci && npx playwright install --with-deps chromium
//   node tools/smoke-test.mjs http://127.0.0.1:8080
//   node tools/smoke-test.mjs http://127.0.0.1:8080 --device "Pixel 7"
//
// Set PLAYWRIGHT_CHANNEL=chrome (or msedge) to drive an already-installed browser
// instead. On a managed machine that is usually the only route: unpacking Playwright's
// own Chromium.app is gated by endpoint security and stalls indefinitely.
//
// --device takes any Playwright device name and checks the phone layout instead of the
// desktop one. It emulates size and touch only; the engine is still Chromium.
//
// Used both as the local/PR gate and against the deployed URL, where it is the only
// thing that catches a mis-set CORS/CORP header on the off-origin image.

import { readFileSync } from 'node:fs';
import { chromium, devices } from 'playwright';

// The site under test must have been built by tools/make-dist.sh from this checkout.
const PACKAGE_VERSION = JSON.parse(readFileSync(new URL('../package.json', import.meta.url))).version;

const args = process.argv.slice(2);
const deviceAt = args.indexOf('--device');
const deviceName = deviceAt >= 0 ? args.splice(deviceAt, 2)[1] : null;
const base = args[0];
if (!base || (deviceAt >= 0 && !deviceName)) {
  console.error('usage: node tools/smoke-test.mjs <base-url> [--device "<Playwright device>"]');
  process.exit(2);
}
if (deviceName && !devices[deviceName]) {
  console.error(`Unknown Playwright device: ${deviceName}`);
  process.exit(2);
}

// The library mount plus a gMAP() fit; generous because sampling runs in wasm.
const BOOT_TIMEOUT_MS = Number(process.env.SMOKE_BOOT_TIMEOUT_MS ?? 300_000);
const FIT_TIMEOUT_MS = Number(process.env.SMOKE_FIT_TIMEOUT_MS ?? 600_000);
const UI_TIMEOUT_MS = 30_000;

const failures = [];
function check(name, ok, detail = '') {
  console.log(`${ok ? 'ok  ' : 'FAIL'}  ${name}${detail ? `  ${detail}` : ''}`);
  if (!ok) failures.push(name);
}

const browser = await chromium.launch({ channel: process.env.PLAYWRIGHT_CHANNEL || undefined });
const context = await browser.newContext(deviceName ? devices[deviceName] : { viewport: { width: 1400, height: 900 } });
const page = await context.newPage();

page.on('console', (msg) => {
  if (msg.type() === 'error') console.error(`  [console] ${msg.text()}`);
});
page.on('pageerror', (err) => console.error(`  [pageerror] ${err.message}`));

try {
  const response = await page.goto(base, { waitUntil: 'domcontentloaded' });
  check('page loads', response?.ok() === true, `HTTP ${response?.status()}`);

  check('crossOriginIsolated', await page.evaluate(() => self.crossOriginIsolated === true));

  // The boot overlay hides only at the very end of Session.boot(); probing earlier
  // races the mount and options(device=) setup.
  const bootError = page.locator('#boot-error');
  await Promise.race([
    page.locator('#boot').waitFor({ state: 'hidden', timeout: BOOT_TIMEOUT_MS }),
    bootError.waitFor({ state: 'visible', timeout: BOOT_TIMEOUT_MS }).then(async () => {
      throw new Error(`boot failed: ${await bootError.textContent()}`);
    }),
  ]);
  check('session boots', true);

  const evalR = (code) =>
    page.evaluate(async (src) => {
      const session = window.__app?.session;
      if (!session?.webR) throw new Error('window.__app.session is not exposed');
      return session.webR.evalRString(src);
    }, code);

  check('R evaluates', (await evalR('as.character(1 + 1)')) === '2');
  const shown = await page.evaluate(() => document.getElementById('about-version').textContent);
  check('About shows the package.json version', shown === PACKAGE_VERSION, `shown=${shown} package.json=${PACKAGE_VERSION}`);
  check('mclapply(mc.cores > 1) runs on one core',
    (await evalR('paste(unlist(suppressMessages(parallel::mclapply(1:3, identity, mc.cores = 4))), collapse = ",")')) === '1,2,3');

  // Proves the image mounted and a cross-compiled .so dlopens with the TBB stubs.
  const fitClass = await page.evaluate(
    (ms) =>
      Promise.race([
        window.__app.session.webR.evalRString(
          'suppressMessages(library(RBesT));' +
          'fit <- gMAP(cbind(r, n - r) ~ 1 | study, data = AS, family = binomial,' +
          '            tau.dist = "HalfNormal", tau.prior = 1, beta.prior = 2,' +
          '            chains = 1, iter = 400, warmup = 200, cores = 1);' +
          'as.character(class(fit)[1])'
        ),
        new Promise((_, reject) => setTimeout(() => reject(new Error('gMAP timed out')), ms)),
      ]),
    FIT_TIMEOUT_MS
  );
  check('RBesT gMAP() samples', fitClass === 'gMAP', `class=${fitClass}`);

  await checkPanes(page, evalR);
} catch (err) {
  check('smoke test', false, err.message);
} finally {
  await browser.close();
}

/** The workspace and output panes, driven through the console as a user would. */
async function checkPanes(page, evalR) {
  const phone = Boolean(deviceName);
  const settle = async (fn, ...args) => {
    try {
      await page.waitForFunction(fn, args, { timeout: UI_TIMEOUT_MS });
      return true;
    } catch {
      return false;
    }
  };
  // Panes refresh when R goes idle, so wait for that rather than for the call to return.
  const run = async (code) => {
    await page.evaluate((c) => window.__app.terminal.enqueue(c), code);
    await page.waitForFunction(() => !window.__app.terminal.busy, null, { timeout: UI_TIMEOUT_MS });
  };
  const pane = () => page.evaluate(() => document.getElementById('app').dataset.pane);
  const showPane = async (name) => {
    if (phone) await page.click(`#mobile-nav button[data-pane="${name}"]`);
  };

  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  const navShown = await page.locator('#mobile-nav').isVisible();
  const splitters = await page.locator('.splitter:visible').count();
  check(
    `${phone ? 'phone' : 'desktop'} layout`,
    overflow <= 0 && navShown === phone && splitters === (phone ? 0 : 3),
    `overflow=${overflow}px nav=${navShown} splitters=${splitters}`
  );

  const heights = await page.evaluate(() => [...new Set(
    [...document.querySelectorAll('#toolbar button, #toolbar select, .pane-head button:not(.tab):not(.etab)')]
      .filter((b) => b.offsetParent)
      .map((b) => b.offsetHeight)
  )]);
  check('buttons share one height', heights.length === 1, `heights=${heights.join(',')}`);

  await showPane('console');
  await checkConsoleInput(page, evalR);

  await run('smoke_x <- 1:3');
  await showPane('side');
  await page.click('.tab[data-view="env"]');
  check('Environment lists a new object', await settle(
    () => [...document.querySelectorAll('#side-env .env-name')].some((n) => n.textContent === 'smoke_x')
  ));

  await showPane('console');
  await run('plot(1:10)');
  if (phone) {
    const badged = await page.locator('#mobile-nav button.badge[data-pane="output"]').count();
    const stayed = (await pane()) === 'console';
    check('phone: plot badges Output without leaving Console', badged === 1 && stayed);
  } else {
    check('plot reaches the Plots pane', await settle(() => document.getElementById('plot-count').textContent !== ''));
  }

  await run('View(mtcars)');
  check('View() opens a 32-row grid', await settle(
    () => /^32 rows/.test(document.querySelector('.dg-status')?.textContent ?? '')
  ));
  if (phone) check('phone: View() switches to Editor', (await pane()) === 'editor');
  await page.locator('.dg-table thead tr.dg-head th', { hasText: 'mpg' }).click();
  // Column 0 is the row names, so mpg is the second cell.
  check('grid sorts by a column in R', await settle(
    () => document.querySelector('.dg-table tbody tr:not(.dg-pad) td:nth-child(2)')?.textContent === '10.4'
  ));

  await run('?lm');
  if (phone) check('phone: help switches to Output', (await pane()) === 'output');
  const help = page.frameLocator('#view-help iframe');
  const title = await help.locator('h2').first().innerText({ timeout: UI_TIMEOUT_MS }).catch(() => '');
  check('?lm renders in Help', title === 'Fitting Linear Models', `h2=${title}`);
  await help.locator('a', { hasText: /^formula$/ }).first().click();
  const linked = await help.locator('h2', { hasText: 'Model Formulae' }).waitFor({ timeout: UI_TIMEOUT_MS })
    .then(() => true, () => false);
  check('help links navigate in the pane', linked);

  await showPane('side');
  await page.click('.tab[data-view="pkgs"]');
  const box = page.locator('#side-pkgs input[type="checkbox"][data-pkg="MASS"]');
  await box.waitFor({ timeout: UI_TIMEOUT_MS });
  await box.check();
  await page.waitForFunction(() => !window.__app.terminal.busy, null, { timeout: UI_TIMEOUT_MS });
  check('Packages checkbox attaches', (await evalR('as.character("package:MASS" %in% search())')) === 'TRUE');

  await checkReproducible(page, evalR);
  await checkDebugging(page, evalR, { run, showPane, settle });
  await checkWorkers(page, evalR, { run, showPane, settle });
  await checkStopSourceRestart(page, evalR, { run, showPane, settle });
  check('restart stops the webR workers', await settle(
    () => document.getElementById('status-workers').hidden && window.__app.session.pool.info().workers === 0
  ));
}

/** miraiWebR: workers in parallel on a desktop, Stop ends a wait on them; none on a phone. */
async function checkWorkers(page, evalR, { run, showPane, settle }) {
  await showPane('console');
  if (deviceName) {
    await run('library(miraiWebR); daemons(2); smoke_w <- mirai(6 * 7)[]');
    check('phone: daemons() falls back to running tasks in the console',
      (await evalR('paste(status()$mode, smoke_w)')) === 'sequential 42');
    await run('everywhere(smoke_f <- function(x) x + 1); smoke_fx <- mirai_map(1:2, function(x) smoke_f(x))[.flat]');
    check('phone: what everywhere() defines reaches later tasks, not the workspace',
      (await evalR('paste(paste(smoke_fx, collapse = " "), exists("smoke_f", envir = globalenv(), inherits = FALSE))')) === '2 3 FALSE');
    await run('daemons(0)');
    check('phone: daemons(0) removes the stand-in environment',
      (await evalR('as.character("miraiWebR:sequential" %in% search())')) === 'FALSE');
    return;
  }
  // Private-repository CI runners have 2 cores, which leaves room for one worker only.
  const { max } = await page.evaluate(() => JSON.parse(window.__app.session.pool.limits()));
  if (max < 2) {
    const refused = await evalR('library(miraiWebR); tryCatch({ daemons(2); "started" }, error = conditionMessage)');
    check('daemons(2) beyond the device limit is refused', /allows at most \d+ webR worker/.test(refused), refused);
    console.log(`skip  worker checks: this browser allows ${max} webR worker(s); they need 2`);
    return;
  }
  await run('library(miraiWebR); daemons(2)');
  check('daemons(2) shows the workers pill', await settle(
    () => document.getElementById('workers-label').textContent === 'workers 0/2 busy'
  ));
  // Two 1.5 s tasks per worker: about 3 s in parallel, 6 s in sequence.
  const timing = await evalR(`
    smoke_busy <- function(i) { t0 <- proc.time()[[3]]; while (proc.time()[[3]] - t0 < 1.5) NULL; i }
    el <- system.time(v <- mirai_map(1:4, smoke_busy)[.flat])[["elapsed"]]
    paste(identical(v, 1:4), el < 5, round(el, 1))
  `);
  check('mirai_map() runs on two workers in parallel', timing.startsWith('TRUE TRUE'), `elapsed=${timing}`);
  await page.evaluate(() => window.__app.terminal.enqueue(
    'smoke_m <- mirai_map(1:4, function(i) { t0 <- proc.time()[[3]]; while (proc.time()[[3]] - t0 < 60) NULL; i }); smoke_v <- smoke_m[]'
  ));
  await page.waitForTimeout(2000);
  const t0 = Date.now();
  await page.click('#btn-interrupt-console');
  await page.waitForFunction(() => !window.__app.terminal.busy, null, { timeout: UI_TIMEOUT_MS });
  const waited = Date.now() - t0;
  const canceled = await evalR('paste(vapply(smoke_m[], function(v) as.integer(v), 1L), collapse = ",")');
  check('Stop cancels the workers\' tasks and ends the wait', waited < 5000 && canceled === '20,20,20,20',
    `stopped in ${waited} ms; values ${canceled}`);

  const menuItem = async (action) => {
    await page.click('#btn-workers-stop');
    await page.click(`#workers-menu button[data-action="${action}"]`);
  };
  await page.click('#btn-workers-stop');
  await page.keyboard.press('Escape');
  const escaped = await page.evaluate(() =>
    document.getElementById('workers-menu').hidden && document.activeElement?.id === 'btn-workers-stop');
  check('workers menu closes on Escape', escaped);

  await page.evaluate(() => window.__app.terminal.enqueue(
    'smoke_m2 <- mirai_map(1:4, function(i) { t0 <- proc.time()[[3]]; while (proc.time()[[3]] - t0 < 60) NULL; i }); smoke_v2 <- smoke_m2[]; smoke_after2 <- TRUE'
  ));
  await settle(() => /2\/2 busy · 2 queued/.test(document.getElementById('workers-label').textContent));
  const t1 = Date.now();
  await menuItem('cancel');
  await page.waitForFunction(() => !window.__app.terminal.busy, null, { timeout: UI_TIMEOUT_MS });
  const cancelled = await evalR('paste(exists("smoke_after2"), paste(vapply(smoke_v2, as.integer, 1L), collapse = ","))');
  check('workers menu: Cancel tasks ends the wait and R carries on', Date.now() - t1 < 5000 &&
    cancelled === 'TRUE 20,20,20,20', `after ${Date.now() - t1} ms: ${cancelled}`);

  await menuItem('close');
  const hidden = await settle(() => document.getElementById('status-workers').hidden);
  const refused = await evalR('tryCatch({ mirai(1); "accepted" }, error = conditionMessage)');
  const restarted = await evalR('daemons(2); s <- status()$connections; daemons(0); as.character(s)');
  check('workers menu: Shut down workers, and daemons() starts them again',
    hidden && /shut down from the toolbar/.test(refused) && restarted === '2',
    `hidden=${hidden} mirai=${refused} restarted=${restarted}`);
}

/** webr-examples/reproducibility.R stops unless every fingerprint matches the recorded ones. */
async function checkReproducible(page, evalR) {
  const out = await page.evaluate(() => window.__app.session.webR.evalRString(`
    tryCatch({
      utils::capture.output(source("/home/web_user/webr-examples/reproducibility.R", local = new.env()))
      "ok"
    }, error = function(e) conditionMessage(e))
  `));
  check('reproducibility example is bit-identical to the reference', out === 'ok', out === 'ok' ? '' : out);
}

/** Ctrl+Enter runs whole statements; browser() gets a toolbar, the line, and the frame. */
async function checkDebugging(page, evalR, { run, showPane, settle }) {
  const idle = () => page.waitForFunction(() => !window.__app.terminal.busy, null, { timeout: UI_TIMEOUT_MS });
  const prompt = (re) => page.waitForFunction((src) => new RegExp(src).test(window.__app.terminal.currentPrompt ?? ''),
    re.source, { timeout: UI_TIMEOUT_MS }).then(() => true, () => false);
  const consoleText = () => page.evaluate(async () => {
    const t = window.__app.terminal;
    await new Promise((resolve) => t.term.write('', resolve));
    const b = t.term.buffer.active;
    const lines = [];
    for (let i = 0; i < b.length; i++) lines.push(b.getLine(i).translateToString(true));
    return lines.join('\n');
  });
  // Activate a console link the way a click would, without hunting for canvas pixels.
  const clickLink = (text) => page.evaluate((needle) => {
    const t = window.__app.terminal;
    const b = t.term.buffer.active;
    for (let row = b.length - 1; row >= 0; row--) {
      const link = t.linksOn(row + 1)?.find((l) => l.text.includes(needle));
      if (link) {
        link.activate();
        return true;
      }
    }
    return false;
  }, text);

  const script = [
    'smoke_v <- c(1,', '  2,', '  3)',
    'smoke_w <- 1:3 |>', '  sum()',
    'if (TRUE) {', '  smoke_i <- 1', '} else {', '  smoke_i <- 2', '}',
    'smoke_z <- 0',
  ].join('\n');
  await page.evaluate((text) => window.__app.editor.open('/home/web_user/smoke-enter.R', text), script);
  await showPane('editor');
  const ctrlEnterAt = async (line) => {
    await page.evaluate((l) => {
      window.__app.editor.cm.setCursor({ line: l, ch: 0 });
      window.__app.editor.runSelectionOrLine();
    }, line);
    await idle();
    return page.evaluate(() => window.__app.editor.cm.getCursor().line);
  };
  const after = [await ctrlEnterAt(1), await ctrlEnterAt(3), await ctrlEnterAt(6)];
  check('Ctrl+Enter runs the whole statement',
    (await evalR('paste(length(smoke_v), smoke_w, smoke_i, exists("smoke_z"))')) === '3 6 1 FALSE' &&
    after.join(',') === '3,5,10', `cursor after=${after.join(',')}`);

  const debugFile = '/home/web_user/smoke-debug.R';
  await page.evaluate((p) => window.__app.session.writeFile(p, [
    'smoke_inner <- function(x) {', '  a <- x', '  browser()', '  b <- 2', '  b', '}',
    'smoke_outer <- function() {', '  o <- 1', '  smoke_inner(21)', '}',
    'smoke_outer()', '',
  ].join('\n')), debugFile);
  await showPane('side');
  await page.click('.tab[data-view="env"]');
  await run(`source("${debugFile}")`);
  const stopped = await prompt(/^Browse\[\d+\]> $/);
  const toolbar = await page.locator('#debug-actions').isVisible().catch(() => false);
  const envHas = (name) => settle(
    ([n]) => [...document.querySelectorAll('#side-env .env-name')].some((el) => el.textContent === n), name
  );
  const frameVars = await envHas('a');
  check('browser() shows the debug toolbar and the frame', stopped && frameVars &&
    (deviceName ? true : toolbar), `stopped=${stopped} toolbar=${toolbar} frame=${frameVars}`);

  const stackRows = () => page.evaluate(() =>
    [...document.querySelectorAll('#view-traceback .tb-row .tb-call')].map((el) => el.textContent));
  await settle(() => document.querySelectorAll('#view-traceback .tb-row').length >= 2);
  const rows = await stackRows();
  const tabbed = await page.evaluate(() =>
    document.querySelector('.tab[data-view="traceback"]').classList.contains('active'));
  check('Traceback tab shows the live call stack, innermost first', tabbed &&
    /smoke_inner\(21\)/.test(rows[0] ?? '') && /smoke_outer\(\)/.test(rows[1] ?? ''), `rows=${rows.join(' | ')}`);

  await showPane('console');
  await page.click('#debug-actions [data-debug="n"]');
  await prompt(/^Browse\[\d+\]> $/);
  const marked = await settle(() => {
    const cm = window.__app.editor.cm;
    return window.__app.editor.activePath?.endsWith('smoke-debug.R') &&
      cm.lineInfo(3)?.bgClass?.includes('cm-debug-line');
  });
  check('Next highlights the current line in the editor', marked);

  await showPane('output');
  await page.locator('#view-traceback .tb-row', { hasText: 'smoke_outer()' }).click();
  const outerVars = await envHas('o');
  const atCall = await settle(() => window.__app.editor.cm.getCursor().line === 8);
  check('clicking a frame lists it and opens its line', outerVars && atCall, `vars=${outerVars} line=${atCall}`);

  await showPane('side');
  const chain = await page.evaluate(() =>
    [...document.querySelectorAll('#side-env .env-bar select option')].map((o) => o.textContent.trim()));
  const stats = chain.findIndex((label) => label === 'package:stats');
  await page.selectOption('#side-env .env-bar select', String(stats));
  const listed = await envHas('lm');
  await page.fill('#side-env .env-bar input', 'lm');
  const filtered = await settle(() => {
    const names = [...document.querySelectorAll('#side-env .env-name')].map((el) => el.textContent);
    return names.length > 0 && names.every((n) => n.includes('lm'));
  });
  const envState = filtered ? '' : JSON.stringify(await page.evaluate(() => ({
    select: document.querySelector('#side-env .env-bar select')?.value,
    input: document.querySelector('#side-env .env-bar input')?.value,
    names: [...document.querySelectorAll('#side-env .env-name')].slice(0, 8).map((el) => el.textContent),
    msg: document.querySelector('#side-env .pane-msg')?.textContent,
  })));
  check('environment selector walks the enclosing chain', chain.includes('Global Environment') &&
    chain.at(-1) === 'package:base' && stats > 0 && listed && filtered,
    `listed=${listed} filtered=${filtered} ${envState} chain=${chain.join(' > ')}`);
  await page.fill('#side-env .env-bar input', '');

  await showPane('console');
  await page.click('#debug-actions [data-debug="c"]');
  const back = await prompt(/^> $/);
  await settle(() => document.getElementById('debug-actions').hidden);
  const state = await page.evaluate(() => ({
    hidden: document.getElementById('debug-actions').hidden,
    // CodeMirror repaints a hidden editor (phone layout) only when shown, so ask the doc.
    line: Boolean(window.__app.editor.cm.lineInfo(3)?.bgClass?.includes('cm-debug-line')),
    title: document.querySelector('#view-traceback .tb-title')?.textContent ?? '',
  }));
  const cleared = state.hidden && !state.line && /\(finished\)/.test(state.title);
  check('Continue leaves the debugger cleanly', back && cleared, `prompt=${back} ${JSON.stringify(state)}`);

  await run('smoke_g <- function() stop("boom"); smoke_h <- function() smoke_g(); smoke_h()');
  const offered = (await consoleText()).includes('\u25b8 Show traceback');
  await clickLink('Show traceback');
  await idle();
  const shown = await settle(() => /boom/.test(document.querySelector('#view-traceback .tb-title')?.textContent ?? ''));
  const calls = await stackRows();
  check('Show traceback fills the Traceback tab', offered && shown &&
    calls.some((c) => c.includes('smoke_g()')) && calls.some((c) => c.includes('smoke_h()')) &&
    !(await consoleText()).includes('Traceback, most recent'), `offered=${offered} calls=${calls.join(' | ')}`);

  await clickLink('Rerun with debug');
  const recovering = await prompt(/^Selection: $/);
  await page.evaluate(() => window.__app.terminal.enqueue('0'));
  await idle();
  const restored = (await evalR('paste(deparse(getOption("error")), collapse = "")')).includes('on_error');
  check('Rerun with debug reaches recover() and restores the handler', recovering && restored,
    `recover=${recovering} restored=${restored}`);
}

/** Stop drops queued lines; Source runs a file as one command; q() and Restart give a fresh R. */
async function checkStopSourceRestart(page, evalR, { run, showPane, settle }) {
  const idle = () => page.waitForFunction(() => !window.__app.terminal.busy, null, { timeout: UI_TIMEOUT_MS });
  const consoleText = () => page.evaluate(async () => {
    const t = window.__app.terminal;
    await new Promise((resolve) => t.term.write('', resolve));
    const b = t.term.buffer.active;
    const lines = [];
    for (let i = 0; i < b.length; i++) lines.push(b.getLine(i).translateToString(true));
    return lines.join('\n');
  });
  const count = (text, needle) => text.split(needle).length - 1;

  await showPane('console');
  await page.evaluate(() => window.__app.terminal.enqueue('Sys.sleep(5)\nsmoke_after <- 1'));
  await page.waitForTimeout(1000);
  await page.click('#btn-interrupt-console');
  await idle();
  check('Stop drops lines queued by Run all', (await evalR('as.character(exists("smoke_after"))')) === 'FALSE');

  const path = '/home/web_user/smoke-source.R';
  await page.evaluate((p) => {
    const { editor } = window.__app;
    editor.open(p, 'smoke_src <- 1\n41 + 1\n');
    editor.cm.replaceRange('# edited\n', { line: 0, ch: 0 });
  }, path);
  await showPane('editor');
  const before = await consoleText();
  await page.click('#btn-source');
  // Source saves before it queues, so R is not busy yet when the click returns.
  await page.waitForFunction((p) => window.__app.editor.isClean(p), path, { timeout: UI_TIMEOUT_MS });
  await idle();
  const plain = await consoleText();
  const saved = await page.evaluate((p) => window.__app.session.readFile(p), path);
  const srcExists = (await evalR('as.character(exists("smoke_src"))')) === 'TRUE';
  const sourced = count(plain, '> source(') - count(before, '> source(');
  const perLine = count(plain, '> smoke_src <- 1') - count(before, '> smoke_src <- 1');
  const printed = count(plain, '[1] 42') - count(before, '[1] 42');
  check('Source saves first and runs the file as one command',
    saved.startsWith('# edited') && srcExists && sourced === 1 && perLine === 0 && printed === 0,
    `saved=${saved.startsWith('# edited')} exists=${srcExists} source-lines=${sourced} echoed=${perLine} printed=${printed}`);

  await showPane('editor');
  await page.click('#btn-source-menu');
  await page.click('#source-menu button[data-echo="true"]');
  await idle();
  const echoed = await consoleText();
  check('Source with echo prints values', count(echoed, '[1] 42') === count(plain, '[1] 42') + 1);

  await run('smoke_keep <- 1; writeLines("kept", "smoke-keep.txt"); plot(1:3)');
  const restarted = async () => {
    await page.waitForFunction(() => !window.__app.isRestarting() && !window.__app.terminal.busy, null,
      { timeout: BOOT_TIMEOUT_MS, polling: 500 });
    return (await evalR('as.character(1 + 1)')) === '2';
  };
  await showPane('console');
  await page.evaluate(() => window.__app.terminal.enqueue('q()'));
  await page.waitForFunction(() => window.__app.isRestarting(), null, { timeout: UI_TIMEOUT_MS });
  const fresh = await restarted();
  const text = await consoleText();
  check('q() restarts R without asking to save',
    fresh && !/Save workspace/i.test(text) &&
    (await evalR('as.character(exists("smoke_keep"))')) === 'FALSE' &&
    (await evalR('paste(readLines("/home/web_user/smoke-keep.txt"), collapse = "")')) === 'kept');
  check('restart clears the Plots pane', await settle(() => document.getElementById('plot-count').textContent === ''));
  await run('View(mtcars)');
  check('panes work after a restart', await settle(
    () => /^32 rows/.test(document.querySelector('.dg-status')?.textContent ?? '')
  ));

  let ok = true;
  for (let i = 0; i < 2; i++) {
    await showPane('console');
    await page.click('#btn-restart');
    await page.waitForFunction(() => window.__app.isRestarting(), null, { timeout: UI_TIMEOUT_MS });
    ok = ok && (await restarted());
  }
  check('Restart button, twice more', ok);
}

/** Typing, line editing across a wrap, and paste, checked against xterm's own cursor. */
async function checkConsoleInput(page, evalR) {
  await page.click('#tab-console');
  // The phone console is fitted a few frames after it is shown.
  await page.waitForFunction(() => {
    const t = window.__app.terminal;
    return t.term.cols === t.fit.proposeDimensions()?.cols;
  }, null, { timeout: UI_TIMEOUT_MS });
  // xterm parses writes asynchronously, so flush before reading the cursor.
  const state = () => page.evaluate(async () => {
    const t = window.__app.terminal;
    await new Promise((resolve) => t.rawWrite('', resolve));
    const b = t.term.buffer.active;
    return { x: b.cursorX, y: b.baseY + b.cursorY, cols: t.term.cols, writes: t.writes };
  });
  await page.evaluate(() => {
    const t = window.__app.terminal;
    t.rawWrite = t.term.write.bind(t.term);
    t.writes = 0;
    t.term.write = (...a) => { t.writes++; return t.rawWrite(...a); };
  });

  const start = await state();
  await page.keyboard.type('abc');
  const typed = await state();
  check('one console write per keystroke', typed.writes - start.writes === 3, `writes=${typed.writes - start.writes}`);
  for (let i = 0; i < 3; i++) await page.keyboard.press('Backspace');

  // Long enough to wrap, so Home/End and edits cross a row boundary.
  const n = start.cols + 5;
  await page.keyboard.type(`smoke_s <- "${'a'.repeat(n)}"`);
  const len = `smoke_s <- "${'a'.repeat(n)}"`.length;
  const at = (offset) => ({ x: (2 + offset) % start.cols, y: start.y + Math.floor((2 + offset) / start.cols) });
  const same = (s, e) => s.x === e.x && s.y === e.y;

  await page.keyboard.press('Home');
  const home = await state();
  await page.keyboard.press('End');
  const end = await state();
  check('Home/End across a wrapped line', same(home, at(0)) && same(end, at(len)),
    `home=${home.x},${home.y} end=${end.x},${end.y} expected end=${at(len).x},${at(len).y}`);

  await page.keyboard.press('ArrowLeft');
  await page.keyboard.press('Backspace');
  const edited = await state();
  check('cursor follows a mid-line edit', same(edited, at(len - 2)), `at=${edited.x},${edited.y}`);
  await page.keyboard.press('Enter');
  await page.waitForFunction(() => !window.__app.terminal.busy, null, { timeout: UI_TIMEOUT_MS });
  check('edited line reaches R', (await evalR('as.character(nchar(smoke_s))')) === String(n - 1));

  // Input ending exactly at the right edge, where xterm defers the wrap.
  const edgeStart = await state();
  const edgeAt = (offset) => ({ x: (2 + offset) % edgeStart.cols, y: edgeStart.y + Math.floor((2 + offset) / edgeStart.cols) });
  const comment = `#${'e'.repeat(edgeStart.cols - 3)}`;
  await page.keyboard.type(comment);
  const atEdge = await state();
  await page.keyboard.press('Backspace');
  await page.keyboard.type('xy');
  const pastEdge = await state();
  check('cursor at the right edge', same(atEdge, edgeAt(comment.length)) && same(pastEdge, edgeAt(comment.length + 1)),
    `edge=${atEdge.x},${atEdge.y} past=${pastEdge.x},${pastEdge.y}`);
  await page.keyboard.press('Enter');
  await page.waitForFunction(() => !window.__app.terminal.busy, null, { timeout: UI_TIMEOUT_MS });

  await page.evaluate(() => window.__app.terminal.term.paste('smoke_p1 <- 1\nsmoke_p2 <- 2\n'));
  await page.waitForFunction(() => !window.__app.terminal.busy, null, { timeout: UI_TIMEOUT_MS });
  check('multi-line paste runs every line',
    (await evalR('as.character(exists("smoke_p1") && exists("smoke_p2"))')) === 'TRUE');
}

if (failures.length) {
  console.error(`\n${failures.length} check(s) failed: ${failures.join(', ')}`);
  process.exit(1);
}
console.log('\nAll checks passed.');
