// Run the first-party tests that need real webR workers, in the application itself.
//
//   node tools/test-browser.mjs http://127.0.0.1:8080
//
// tools/test-packages.mjs runs every package's tests under Node, where there is no
// page and so no worker pool: miraiWebR's worker tests and stanliWebR's parallel-
// chains test skip themselves there. This boots the site in Chromium, as
// tools/smoke-test.mjs does, copies the test frameworks and the tests of miraiWebR
// and stanliWebR into the console's R, and runs them there, where daemons() starts
// real workers. It fails if any test fails, if the skip list does not cover it, or if
// a test meant for this run still skipped for want of workers.
//
// Needs `npm ci` and a Playwright browser (PLAYWRIGHT_CHANNEL=chrome to use an
// installed Chrome), and `Rscript tools/fetch-test-inputs.R` beforehand. Results go
// to build/test-results/browser/.

import { mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { junit, matches, readSkips } from './test-packages.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const PACKAGES = ['miraiWebR', 'stanliWebR'];
const WORKER_SKIP = /needs two webR workers/;
const BOOT_TIMEOUT_MS = Number(process.env.TEST_BOOT_TIMEOUT_MS ?? 300_000);
const RUN_TIMEOUT_MS = Number(process.env.TEST_RUN_TIMEOUT_MS ?? 1_800_000);
const OUT = join(root, 'build', 'test-results', 'browser');

const base = process.argv[2];
if (!base) {
  console.error('usage: node tools/test-browser.mjs <base-url>');
  process.exit(2);
}

function files(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? files(path) : [path];
  });
}

const browser = await chromium.launch({ channel: process.env.PLAYWRIGHT_CHANNEL || undefined });
let exitCode = 0;
try {
  const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage();
  page.on('pageerror', (err) => console.error(`  [pageerror] ${err.message}`));
  await page.goto(base, { waitUntil: 'domcontentloaded' });
  await page.locator('#boot').waitFor({ state: 'hidden', timeout: BOOT_TIMEOUT_MS });

  const max = await page.evaluate(() => JSON.parse(window.__app.session.pool.limits()).max);
  if (max < 2) throw new Error(`this browser allows ${max} webR worker(s); the worker tests need 2`);

  // The frameworks and the tests, into the console R's filesystem.
  const copies = [
    [join(root, 'build', 'test-library'), '/home/web_user/.test-library'],
    ...PACKAGES.map((p) => [join(root, 'build', 'test-sources', p), `/home/web_user/.test-sources/${p}`]),
  ];
  for (const [from, to] of copies) {
    const batch = files(from).map((f) => ({
      path: `${to}/${relative(from, f)}`,
      data: readFileSync(f).toString('base64'),
    }));
    await page.evaluate(async (items) => {
      const { FS } = window.__app.session.webR;
      const made = new Set();
      const mkdirs = async (dir) => {
        const parts = dir.split('/').filter(Boolean);
        for (let i = 1; i <= parts.length; i++) {
          const d = `/${parts.slice(0, i).join('/')}`;
          if (made.has(d)) continue;
          made.add(d);
          try {
            await FS.mkdir(d);
          } catch {
            // Exists.
          }
        }
      };
      for (const { path, data } of items) {
        await mkdirs(path.slice(0, path.lastIndexOf('/')));
        await FS.writeFile(path, Uint8Array.from(atob(data), (c) => c.charCodeAt(0)));
      }
    }, batch);
  }
  await page.evaluate(async (src) => {
    await window.__app.session.webR.FS.writeFile('/tmp/test-packages.R', new TextEncoder().encode(src));
  }, readFileSync(join(root, 'tools', 'test-packages.R'), 'utf8'));

  mkdirSync(OUT, { recursive: true });
  const skips = readSkips();
  const unlisted = [];
  for (const pkg of PACKAGES) {
    const started = Date.now();
    const json = await page.evaluate(async ({ pkg, timeout }) => {
      const run = window.__app.session.webR.evalRString(`
        local({
          .libPaths(c("/home/web_user/.test-library", .libPaths()))
          Sys.setenv(NOT_CRAN = "", TESTTHAT_PARALLEL = "false")
          env <- new.env()
          sys.source("/tmp/test-packages.R", envir = env)
          dir <- env$webrtest$stage("/home/web_user/.test-sources/${pkg}", "/tmp/work-${pkg}")
          suppressPackageStartupMessages(library(stanliWebR))
          res <- env$webrtest$run_testthat("${pkg}", dir)
          try(miraiWebR::daemons(0), silent = TRUE)
          as.character(jsonlite::toJSON(res, dataframe = "rows", auto_unbox = TRUE))
        })
      `);
      return Promise.race([run, new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), timeout))]);
    }, { pkg, timeout: RUN_TIMEOUT_MS });
    const results = JSON.parse(json);
    for (const r of results) {
      if (r.status === 'skip' && WORKER_SKIP.test(r.message)) {
        r.status = 'error';
        r.message = `still skipped with workers running: ${r.message}`;
      }
      if (r.status !== 'fail' && r.status !== 'error') continue;
      const entry = skips.find((e) => matches(e, pkg, r, 'cran'));
      if (entry) r.listed = entry.reason;
      else unlisted.push({ pkg, ...r });
    }
    const seconds = Math.round((Date.now() - started) / 1000);
    writeFileSync(join(OUT, `${pkg}.xml`), junit(pkg, results, seconds));
    const n = (s) => results.filter((r) => r.status === s && !r.listed).length;
    console.log(`${n('fail') + n('error') ? 'FAIL' : 'ok  '}  ${pkg.padEnd(12)} ${n('pass')} pass  ${n('skip')} skip  ${n('fail') + n('error')} failed  ${seconds} s`);
  }
  for (const u of unlisted) console.log(`FAIL  ${u.pkg} | ${u.file} | ${u.test}\n        ${String(u.message).slice(0, 300)}`);
  if (unlisted.length) exitCode = 1;
} catch (err) {
  console.error(`test-browser: ${err.message}`);
  exitCode = 2;
} finally {
  await browser.close();
}
process.exit(exitCode);
