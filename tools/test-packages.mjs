// Run every package's own tests in webR, under Node, against the built library.
//
//   Rscript tools/fetch-test-inputs.R          # once per library change
//   node tools/test-packages.mjs [options]
//
//   --full              NOT_CRAN=true: the suites CRAN skips, much slower
//   --package a,b       only these packages
//   --jobs N            packages run in parallel (default: half the cores, at most 4)
//   --timeout S         seconds per package (default 900, or 3600 with --full)
//   --record-skips      append every unlisted failure to lib/TEST-SKIPS.tsv, reason TODO
//
// Each package gets a fresh webR with build/library mounted, the test frameworks from
// build/test-library ahead of it on .libPaths(), and stanliWebR loaded, so model fits
// in the tests go through stanli as they do for users. tools/test-packages.R runs the
// tests; this script plans the sessions, enforces the timeout and applies the gate.
//
// The gate is strict. The run fails on any failure or error that lib/TEST-SKIPS.tsv
// does not list, on a package that cannot be tested at all (no published source, a
// version that differs from its tests, a crash, a timeout), on a listed entry that no
// longer fails, and on any entry whose reason is still TODO. Tests a package skips
// itself (skip_on_cran(), skip_if_not_installed(), ...) are reported, not failed.
//
// Results: build/test-results/results.json, one JUnit file per package, and each
// package's console output in build/test-results/logs/.

import { cpSync, createWriteStream, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync, appendFileSync } from 'node:fs';
import { availableParallelism } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { Worker } from 'node:worker_threads';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const LIBRARY = join(root, 'build', 'library');
const TEST_LIBRARY = join(root, 'build', 'test-library');
const TEST_SOURCES = join(root, 'build', 'test-sources');
const RESULTS = join(root, 'build', 'test-results');
const SKIPS = join(root, 'lib', 'TEST-SKIPS.tsv');
const SKIP_HEADER = 'package\tfile\ttest\tdepth\treason';
const START_TIMEOUT_MS = 120_000;

// ---------------------------------------------------------------- arguments

function parseArgs(argv) {
  const opts = { full: false, packages: null, jobs: null, timeout: null, recordSkips: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const value = () => {
      if (i + 1 >= argv.length) throw new Error(`${a} needs a value`);
      return argv[++i];
    };
    if (a === '--full') opts.full = true;
    else if (a === '--record-skips') opts.recordSkips = true;
    else if (a === '--package') opts.packages = value().split(',').map((s) => s.trim()).filter(Boolean);
    else if (a === '--jobs') opts.jobs = Number(value());
    else if (a === '--timeout') opts.timeout = Number(value());
    else throw new Error(`Unknown argument: ${a}`);
  }
  opts.jobs ??= Math.max(1, Math.min(4, Math.floor(availableParallelism() / 2)));
  opts.timeout ??= opts.full ? 3600 : 900;
  if (!(opts.jobs >= 1) || !(opts.timeout > 0)) throw new Error('--jobs and --timeout must be positive');
  return opts;
}

// ---------------------------------------------------------------- webR under Node

// The repository is "type": "module", so Node would load webR's CommonJS worker as an
// ES module; a copy marked commonjs avoids that without touching vendor/webr.
function prepareWebR() {
  const src = join(root, 'vendor', 'webr');
  const dest = join(root, 'build', 'webr-node');
  if (!existsSync(join(src, 'webr.mjs'))) throw new Error('vendor/webr is missing: run tools/fetch-webr.sh');
  const stamp = (d) => (existsSync(join(d, 'R.wasm')) ? `${statSync(join(d, 'R.wasm')).size}:${statSync(join(d, 'webr.mjs')).size}` : '');
  if (stamp(src) !== stamp(dest)) {
    rmSync(dest, { recursive: true, force: true });
    cpSync(src, dest, { recursive: true });
  }
  writeFileSync(join(dest, 'package.json'), '{"type":"commonjs"}\n');
  return dest;
}

let WebR;
async function loadWebR(dir) {
  globalThis.__dirname = dir;
  globalThis.__filename = join(dir, 'webr.mjs');
  ({ WebR } = await import(join(dir, 'webr.mjs')));
  // The browser bundle replaces Worker with an empty stand-in when loaded under Node.
  globalThis.Worker = Worker;
}

const rStr = (s) => JSON.stringify(String(s));

// miraiWebR drives the page's worker pool through webr::eval_js(await = TRUE), which
// under Node runs in this process. A pool that offers no workers makes daemons() fall
// back to running tasks in the console, as on a phone, so that path is tested here;
// workers themselves need the page (tools/test-browser.mjs).
globalThis.__webrPool = {
  limits: () => JSON.stringify({ max: 0, reason: 'the package tests run without webR workers' }),
  status: () => JSON.stringify({ generation: 0, workers: 0, ready: 0, busy: 0, queued: 0, completed: 0 }),
  close: () => 0,
  cancelAll: () => 0,
};

class Session {
  constructor(webrDir, log) {
    this.webR = new WebR({ baseUrl: `${webrDir}/`, interactive: false });
    this.log = log;
  }

  // Output and messages to the queue, which drain() logs, rather than to this
  // process's console, where webR's default capture replays them. With conditions
  // uncaptured an R error no longer rejects, so it is caught in R and thrown here.
  async evalString(code) {
    const out = await this.webR.evalRString(
      `tryCatch(paste0("\x01", local({\n${code}\n})), error = function(e) paste0("\x02", conditionMessage(e)))`,
      { captureStreams: false, captureConditions: false }
    );
    if (out.startsWith('\x02')) throw new Error(`R: ${out.slice(1)}`);
    return out.slice(1);
  }

  async evalVoid(code) {
    await this.evalString(`${code}\n""`);
  }

  async start({ pkg, full }) {
    await this.webR.init();
    this.drain();
    const R = { FS: this.webR.FS, evalRVoid: (code) => this.evalVoid(code) };
    // eval_js() code that require()s (stanli's runtime loader) needs it in the worker.
    await R.evalRVoid('webr::eval_js("globalThis.require ??= process.getBuiltinModule(\'module\').createRequire(\'/\'), 0")');
    for (const [dir, mount] of [[LIBRARY, '/library'], [TEST_LIBRARY, '/test-library'], [join(TEST_SOURCES, pkg), '/pkgsrc']]) {
      await R.FS.mkdir(mount);
      await R.FS.mount('NODEFS', { root: dir }, mount);
    }
    await R.FS.writeFile('/tmp/test-packages.R', readFileSync(join(root, 'tools', 'test-packages.R')));
    await R.evalRVoid(`
      .libPaths(c("/test-library", "/library", .libPaths()))
      Sys.setenv(NOT_CRAN = ${full ? '"true"' : '""'}, R_TESTS = "", TESTTHAT_PARALLEL = "false", TZ = "UTC")
      options(warn = 1, useFancyQuotes = FALSE)
      # On the search path, where a test's rm(list = ls()) cannot reach it.
      sys.source("/tmp/test-packages.R", envir = attach(NULL, name = "webrtest"))
      webrtest$stage("/pkgsrc", "/work")
      setwd("/work")
      suppressPackageStartupMessages(library(stanliWebR))
    `);
  }

  // webR queues console output until it is read; keep the queue empty and log it.
  async drain() {
    for (;;) {
      let msg;
      try {
        msg = await this.webR.read();
      } catch {
        return;
      }
      if (msg.type === 'closed') return;
      if (msg.type === 'stdout' || msg.type === 'stderr') this.log(`${msg.data}\n`);
    }
  }

  async results(code) {
    await this.evalVoid(`webrtest$write(${code}, "/tmp/results.json")`);
    return JSON.parse(new TextDecoder().decode(await this.webR.FS.readFile('/tmp/results.json')));
  }

  close() {
    try {
      this.webR.close();
    } catch {
      // Already gone.
    }
  }
}

// ---------------------------------------------------------------- one package

function pkgFailure(test, message) {
  return [{ file: '*', test, status: 'error', message }];
}

async function withDeadline(promise, deadline, onTimeout) {
  let timer;
  const left = deadline - Date.now();
  if (left <= 0) {
    onTimeout();
    throw new Error('timeout');
  }
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      onTimeout();
      reject(new Error('timeout'));
    }, left);
  });
  try {
    return await Promise.race([promise, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

async function testPackage(pkg, opts, webrDir) {
  const logStream = createWriteStream(join(RESULTS, 'logs', `${pkg}.log`));
  logStream.on('error', () => {});
  // A closed session's output can still arrive after the package is done.
  const log = (s) => {
    if (!logStream.writableEnded) logStream.write(s);
  };
  try {
    return await testPackageLogged(pkg, opts, webrDir, log);
  } finally {
    await new Promise((resolve) => logStream.end(resolve));
  }
}

async function testPackageLogged(pkg, opts, webrDir, log) {
  const started = Date.now();
  const deadline = started + opts.timeout * 1000;

  const versionFile = join(TEST_SOURCES, pkg, 'VERSION');
  const [want, untestable] = readFileSync(versionFile, 'utf8').trim().split('\n');
  if (untestable) return { results: pkgFailure('(untestable)', untestable), seconds: 0 };
  const installed = existsSync(join(LIBRARY, pkg, 'DESCRIPTION'))
    ? /^Version:\s*(\S+)/m.exec(readFileSync(join(LIBRARY, pkg, 'DESCRIPTION'), 'utf8'))?.[1]
    : null;
  if (installed !== want) {
    return {
      results: pkgFailure('(version)', `build/library has ${pkg} ${installed ?? 'missing'}, the tests are for ${want}; rebuild the library or re-run tools/fetch-test-inputs.R`),
      seconds: 0,
    };
  }

  const results = [];
  let session = null;
  const run = async (fn) => {
    try {
      return await withDeadline(fn(), deadline, () => session?.close());
    } catch (err) {
      session?.close();
      throw err;
    }
  };
  // Under load a webR worker occasionally never finishes starting; a fresh one does.
  const startSession = async () => {
    for (let attempt = 1; ; attempt++) {
      session = new Session(webrDir, log);
      const limit = Math.min(deadline, Date.now() + START_TIMEOUT_MS);
      try {
        await withDeadline(session.start({ pkg, full: opts.full }), limit, () => session.close());
        return;
      } catch (err) {
        session.close();
        if (err.message !== 'timeout' || attempt >= 3 || Date.now() >= deadline) throw err;
        log(`\n== webR did not start within ${START_TIMEOUT_MS / 1000} s; retrying\n`);
      }
    }
  };

  try {
    await startSession();
    const plan = JSON.parse(await run(() => session.evalString('as.character(jsonlite::toJSON(webrtest$discover("/work"), auto_unbox = TRUE))')));
    if (plan.testthat) {
      log('\n== testthat\n');
      try {
        results.push(...(await run(() => session.results(`webrtest$run_testthat(${rStr(pkg)}, "/work")`))));
      } catch (err) {
        if (err.message === 'timeout' && Date.now() >= deadline) throw err;
        // Something brought R down: run the files one by one, so the crash costs one.
        log(`\n== CRASH: ${err.stack ?? err}\n== testthat, one file per session\n`);
        await startSession();
        const testFiles = JSON.parse(await run(() => session.evalString(
          'as.character(jsonlite::toJSON(webrtest$testthat_files("/work")))'
        )));
        session.close();
        for (const file of testFiles) {
          log(`\n== tests/testthat/${file}\n`);
          try {
            await startSession();
            results.push(...(await run(() => session.results(`webrtest$run_testthat(${rStr(pkg)}, "/work", ${rStr(file)})`))));
          } catch (fileErr) {
            if (fileErr.message === 'timeout' && Date.now() >= deadline) throw fileErr;
            log(`\n== CRASH: ${fileErr.stack ?? fileErr}\n`);
            results.push({ file, test: '(crash)', status: 'error', message: String(fileErr.message ?? fileErr).slice(0, 2000) });
          } finally {
            session?.close();
          }
        }
        await startSession();
      }
    }
    if (plan.tinytest) {
      log('\n== tinytest\n');
      results.push(...(await run(() => session.results(`webrtest$run_tinytest(${rStr(pkg)}, "/work", ${opts.full ? 'TRUE' : 'FALSE'})`))));
    }
    session.close();
    // As R CMD check: each script in an R of its own.
    for (const script of plan.scripts) {
      log(`\n== tests/${script}\n`);
      try {
        await startSession();
        results.push(...(await run(() => session.results(`webrtest$run_script("/work", ${rStr(script)})`))));
      } catch (err) {
        // A script that brings its R down fails alone; the package's time running out ends all.
        if (err.message === 'timeout' && Date.now() >= deadline) throw err;
        log(`\n== CRASH: ${err.stack ?? err}\n`);
        results.push({ file: script, test: '(script)', status: 'error', message: String(err.message ?? err).slice(0, 2000) });
      } finally {
        session?.close();
      }
    }
    if (!plan.testthat && !plan.tinytest && !plan.scripts.length) {
      results.push({ file: '*', test: '(no tests)', status: 'skip', message: 'the package has no tests' });
    }
  } catch (err) {
    session?.close();
    const timedOut = err.message === 'timeout';
    log(`\n== ${timedOut ? 'TIMEOUT' : 'CRASH'}: ${err.stack ?? err}\n`);
    results.push(...pkgFailure(timedOut ? '(timeout)' : '(crash)',
      timedOut ? `did not finish within ${opts.timeout} s` : String(err.message ?? err).slice(0, 2000)));
  }
  return { results, seconds: Math.round((Date.now() - started) / 1000) };
}

// ---------------------------------------------------------------- the gate

export function readSkips() {
  if (!existsSync(SKIPS)) return [];
  const lines = readFileSync(SKIPS, 'utf8').split('\n').filter((l) => l.trim() && !l.startsWith('#'));
  if (lines[0] !== SKIP_HEADER) throw new Error(`lib/TEST-SKIPS.tsv must start with the header: ${SKIP_HEADER.replace(/\t/g, '<TAB>')}`);
  return lines.slice(1).map((line, i) => {
    const [pkg, file, test, depth, reason] = line.split('\t');
    if (![pkg, file, test, depth, reason].every((v) => v !== undefined && v !== '')) {
      throw new Error(`lib/TEST-SKIPS.tsv line ${i + 2}: five tab-separated fields needed`);
    }
    if (!['cran', 'full', 'both'].includes(depth)) throw new Error(`lib/TEST-SKIPS.tsv line ${i + 2}: depth must be cran, full or both`);
    return { pkg, file, test, depth, reason, line: i + 2, used: false };
  });
}

export const matches = (entry, pkg, r, depth) =>
  entry.pkg === pkg &&
  (entry.depth === 'both' || entry.depth === depth) &&
  (entry.file === '*' || entry.file === r.file) &&
  (entry.test === '*' || entry.test === r.test);

const clean = (s) => String(s).replace(/[\t\r\n]+/g, ' ');

export function junit(pkg, results, seconds) {
  const esc = (s) => String(s).replace(/[<>&"]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;' })[c]);
  const failures = results.filter((r) => r.status === 'fail').length;
  const errors = results.filter((r) => r.status === 'error').length;
  const skipped = results.filter((r) => r.status === 'skip' || r.listed).length;
  const cases = results.map((r) => {
    const name = `name="${esc(r.test)}" classname="${esc(`${pkg}.${r.file}`)}"`;
    if (r.listed) return `  <testcase ${name}><skipped message="${esc(`listed: ${r.listed}`)}"/></testcase>`;
    if (r.status === 'skip') return `  <testcase ${name}><skipped message="${esc(r.message)}"/></testcase>`;
    if (r.status === 'fail') return `  <testcase ${name}><failure message="${esc(r.message)}"/></testcase>`;
    if (r.status === 'error') return `  <testcase ${name}><error message="${esc(r.message)}"/></testcase>`;
    return `  <testcase ${name}/>`;
  });
  return `<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="${esc(pkg)}" tests="${results.length}" failures="${failures}" errors="${errors}" skipped="${skipped}" time="${seconds}">\n${cases.join('\n')}\n</testsuite>\n`;
}

// ---------------------------------------------------------------- main

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const depth = opts.full ? 'full' : 'cran';
  for (const [dir, how] of [[LIBRARY, 'Rscript tools/build-library.R'], [TEST_LIBRARY, 'Rscript tools/fetch-test-inputs.R'], [TEST_SOURCES, 'Rscript tools/fetch-test-inputs.R']]) {
    if (!existsSync(dir)) throw new Error(`${dir} is missing: run ${how}`);
  }
  const all = readdirSync(TEST_SOURCES).filter((p) => existsSync(join(TEST_SOURCES, p, 'VERSION'))).sort();
  const packages = opts.packages ?? all;
  const unknown = packages.filter((p) => !all.includes(p));
  if (unknown.length) throw new Error(`Not in build/test-sources: ${unknown.join(', ')}`);
  const skips = readSkips();

  mkdirSync(join(RESULTS, 'logs'), { recursive: true });
  mkdirSync(join(RESULTS, 'junit'), { recursive: true });
  const webrDir = prepareWebR();
  await loadWebR(webrDir);

  console.log(`Testing ${packages.length} package(s), ${depth} depth, ${opts.jobs} at a time, ${opts.timeout} s each`);
  const report = {};
  const queue = [...packages];
  const worker = async () => {
    while (queue.length) {
      const pkg = queue.shift();
      let { results, seconds } = await testPackage(pkg, opts, webrDir);
      // A package that timed out without a single result was stalled, not slow -- the
      // host suspended, or a webR worker hung at start -- so it gets one more go.
      if (results.length === 1 && results[0].test === '(timeout)') {
        console.log(`retry ${pkg}: no result within ${opts.timeout} s`);
        ({ results, seconds } = await testPackage(pkg, opts, webrDir));
      }
      for (const r of results) {
        if (r.status !== 'fail' && r.status !== 'error') continue;
        const entry = skips.find((e) => matches(e, pkg, r, depth));
        if (entry) {
          entry.used = true;
          r.listed = entry.reason;
        }
      }
      report[pkg] = { seconds, results };
      writeFileSync(join(RESULTS, 'junit', `${pkg}.xml`), junit(pkg, results, seconds));
      const n = (s) => results.filter((r) => r.status === s && !r.listed).length;
      const listed = results.filter((r) => r.listed).length;
      const bad = n('fail') + n('error');
      console.log(`${bad ? 'FAIL' : 'ok  '}  ${pkg.padEnd(22)} ${String(n('pass')).padStart(5)} pass  ${String(n('skip')).padStart(4)} skip  ${String(listed).padStart(3)} listed  ${String(bad).padStart(3)} failed  ${seconds} s`);
    }
  };
  await Promise.all(Array.from({ length: Math.min(opts.jobs, packages.length) }, worker));

  writeFileSync(join(RESULTS, 'results.json'), `${JSON.stringify({ depth, packages: report }, null, 1)}\n`);

  const unlisted = [];
  for (const pkg of packages) {
    for (const r of report[pkg].results) {
      if ((r.status === 'fail' || r.status === 'error') && !r.listed) unlisted.push({ pkg, ...r });
    }
  }
  const tested = new Set(packages);
  // A "flaky:" entry covers a test that fails in some runs only (the network), so its
  // passing does not make it stale.
  const stale = skips.filter((e) => tested.has(e.pkg) && (e.depth === 'both' || e.depth === depth) && !e.used &&
    !e.reason.startsWith('flaky:'));
  const todo = skips.filter((e) => tested.has(e.pkg) && e.reason.trim() === 'TODO');

  if (opts.recordSkips && unlisted.length) {
    if (!existsSync(SKIPS)) writeFileSync(SKIPS, `${SKIP_HEADER}\n`);
    appendFileSync(SKIPS, unlisted.map((u) => `${u.pkg}\t${clean(u.file)}\t${clean(u.test)}\t${depth}\tTODO\n`).join(''));
    console.log(`\nRecorded ${unlisted.length} failure(s) in lib/TEST-SKIPS.tsv with reason TODO; review each.`);
  }

  console.log('');
  for (const u of unlisted) console.log(`FAIL  ${u.pkg} | ${u.file} | ${u.test}\n        ${u.message.slice(0, 300)}`);
  for (const e of stale) console.log(`STALE lib/TEST-SKIPS.tsv line ${e.line}: ${e.pkg} | ${e.file} | ${e.test} no longer fails; remove it`);
  for (const e of todo) console.log(`TODO  lib/TEST-SKIPS.tsv line ${e.line}: ${e.pkg} | ${e.file} | ${e.test} needs a reason`);

  const total = (s) => packages.reduce((n, p) => n + report[p].results.filter((r) => r.status === s && !r.listed).length, 0);
  const listed = packages.reduce((n, p) => n + report[p].results.filter((r) => r.listed).length, 0);
  console.log(`\n${total('pass')} passed, ${total('skip')} skipped by their packages, ${listed} listed in lib/TEST-SKIPS.tsv, ${unlisted.length} failed; ${stale.length} stale and ${todo.length} TODO skip entries.`);
  console.log(`Details: build/test-results/ (results.json, junit/, logs/)`);
  const failed = unlisted.length + stale.length + todo.length > 0;
  process.exit(failed ? 1 : 0);
}

// tools/test-browser.mjs imports the gate from here.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error(`test-packages: ${err.message}`);
    process.exit(2);
  });
}
