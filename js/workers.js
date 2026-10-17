import { WebR } from '../vendor/webr/webr.mjs';
import { mountLibrary } from './library.js';

// Background R sessions for the miraiWebR package. Each worker is a separate webR,
// i.e. its own Web Worker with its own WebAssembly memory and filesystem, so tasks
// genuinely run in parallel with the console's R and with each other.
//
// The console's R drives the pool through webr::eval_js(), which runs on this
// (main) thread while R waits; that is why everything R calls here is either
// synchronous or returns a promise that eval_js(await = TRUE) can block on.
// Payloads cross as base64 text because eval_js only carries code in and a JS
// value out; workers exchange the bytes with R through files in their own FS.

// More than this buys little on a laptop and each worker holds a full R heap.
const MAX_WORKERS = 4;

function toBase64(bytes) {
  if (bytes.toBase64) return bytes.toBase64();
  let out = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    out += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(out);
}

function fromBase64(text) {
  // R's base64 encoder wraps lines; both decoders below skip ASCII whitespace.
  if (Uint8Array.fromBase64) return Uint8Array.fromBase64(text.replace(/\s+/g, ''));
  const bin = atob(text);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export class WorkerPool {
  /**
   * @param {object} opts
   * @param {string} opts.baseUrl     webR's own baseUrl
   * @param {string} opts.libraryUrl  the package library image
   * @param {string} opts.libraryMount where to mount it
   * @param {() => string} opts.unavailable  why workers cannot run here, or ''
   * @param {(index: number, type: string, line: string) => void} opts.onOutput
   * @param {(info: object) => void} opts.onChange
   */
  constructor({ baseUrl, libraryUrl, libraryMount, unavailable, onOutput, onChange }) {
    Object.assign(this, { baseUrl, libraryUrl, libraryMount, unavailable, onOutput, onChange });
    this.workers = [];
    this.tasks = new Map();
    this.queue = [];
    this.nextId = 1;
    this.completed = 0;
    this.generation = 0;
  }

  /** The most workers this device may start, and if none, why not. */
  limits() {
    const reason = this.unavailable();
    if (reason) return JSON.stringify({ max: 0, reason });
    const cores = navigator.hardwareConcurrency || 1;
    // One core stays with the console's R and the page.
    const max = Math.min(MAX_WORKERS, cores - 1);
    return JSON.stringify({
      max,
      reason: max > 0 ? '' : `this browser reports ${cores} CPU core(s), leaving none for workers`,
    });
  }

  /** Replace the pool with `n` fresh workers; resolves to `n` once all are ready. */
  async start(n) {
    this.close();
    if (n === 0) return 0;
    const { max, reason } = JSON.parse(this.limits());
    if (n > max) {
      throw new Error(max === 0
        ? `webR workers are not available: ${reason}`
        : `this device allows at most ${max} webR worker(s); ${n} requested`);
    }
    const generation = ++this.generation;
    const workers = Array.from({ length: n }, (_, index) => ({ index, webR: null, task: null, ready: false }));
    this.workers = workers;
    this.changed();
    try {
      await Promise.all(workers.map((w) => this.boot(w)));
    } catch (err) {
      if (generation === this.generation) this.close();
      throw err;
    }
    if (generation !== this.generation) throw new Error('the worker pool was closed while starting');
    for (const w of workers) w.ready = true;
    this.changed();
    this.dispatch();
    return n;
  }

  async boot(w) {
    w.webR = new WebR({ baseUrl: this.baseUrl });
    await w.webR.init();
    this.readLoop(w);
    await mountLibrary(w.webR, this.libraryUrl, this.libraryMount);
    const q = (s) => JSON.stringify(s);
    await w.webR.evalRVoid(`
      .libPaths(c(${q(this.libraryMount)}, .libPaths()))
      Sys.setenv(MIRAI_WEBR_WORKER = ${w.index + 1})
    `);
  }

  async readLoop(w) {
    const webR = w.webR;
    for (;;) {
      let msg;
      try {
        msg = await webR.read();
      } catch (err) {
        // close() drops the worker from the pool first, so only a live worker's failure is news.
        if (this.workers.includes(w)) {
          this.onOutput(w.index + 1, 'stderr', `output channel failed: ${err.message ?? err}\n`);
        }
        return;
      }
      if (msg.type === 'closed') return;
      // Only a task's own output: not R's startup banner.
      if (w.task === null) continue;
      if (msg.type === 'stdout' || msg.type === 'stderr') this.onOutput(w.index + 1, msg.type, msg.data);
    }
  }

  /**
   * Queue a task; `pin` restricts it to one worker (0-based), as everywhere() needs.
   * Returns the task id at once.
   */
  submit(base64, pin = -1) {
    if (!this.workers.length) throw new Error('no webR workers are running; call daemons(n) first');
    if (pin >= this.workers.length) throw new Error(`there is no worker ${pin + 1}`);
    const id = this.nextId++;
    let resolve;
    const done = new Promise((r) => { resolve = r; });
    this.tasks.set(id, { id, payload: fromBase64(base64), pin, state: 'queued', reply: null, done, resolve });
    this.queue.push(id);
    this.dispatch();
    this.changed();
    return id;
  }

  dispatch() {
    for (const w of this.workers) {
      if (!w.ready || w.task !== null) continue;
      const at = this.queue.findIndex((id) => {
        const pin = this.tasks.get(id).pin;
        return pin < 0 || pin === w.index;
      });
      if (at < 0) continue;
      const [id] = this.queue.splice(at, 1);
      this.run(w, this.tasks.get(id));
    }
  }

  async run(w, task) {
    w.task = task.id;
    task.state = 'running';
    task.worker = w.index;
    this.changed();
    const input = `/tmp/mirai-${task.id}.in`;
    const output = `/tmp/mirai-${task.id}.out`;
    let reply;
    try {
      await w.webR.FS.writeFile(input, task.payload);
      task.payload = null;
      // Not captured, so whatever the task prints reaches readLoop() as it happens.
      await w.webR.evalRVoid(`miraiWebR:::worker_run(${JSON.stringify(input)}, ${JSON.stringify(output)})`, {
        captureStreams: false,
        captureConditions: false,
      });
      reply = `R:${toBase64(await w.webR.FS.readFile(output))}`;
      await w.webR.FS.unlink(output);
    } catch (err) {
      // worker_run() catches every R condition, so this is the worker itself failing.
      reply = this.workers.includes(w)
        ? `E:19:worker ${w.index + 1} failed: ${err.message ?? err}`
        : 'E:20:the worker pool was closed';
    }
    w.task = null;
    this.finish(task, reply);
    this.dispatch();
  }

  finish(task, reply) {
    if (task.state === 'done') return;
    task.state = 'done';
    task.reply = reply;
    this.completed++;
    task.resolve();
    this.changed();
  }

  /** 'queued', 'running' or 'done'. */
  state(id) {
    const task = this.tasks.get(id);
    if (!task) throw new Error(`unknown webR worker task ${id}`);
    return task.state;
  }

  /**
   * Resolve once the task is done, to "R:<base64 serialized value>" or
   * "E:<code>:<message>". The reply is kept until release(): R may be interrupted
   * between receiving it and storing it, and must then be able to ask again.
   */
  async collect(id) {
    const task = this.tasks.get(id);
    if (!task) throw new Error(`unknown webR worker task ${id}`);
    await task.done;
    return task.reply;
  }

  /** Forget a collected task. */
  release(id) {
    return this.tasks.delete(id);
  }

  /** Resolve to the id of the first of `ids` to finish. */
  async waitAny(ids) {
    const tasks = ids.map((id) => {
      const task = this.tasks.get(id);
      if (!task) throw new Error(`unknown webR worker task ${id}`);
      return task;
    });
    return Promise.race(tasks.map((t) => t.done.then(() => t.id)));
  }

  /** Stop a task: dropped if still queued, interrupted if running. */
  cancel(id) {
    const task = this.tasks.get(id);
    if (!task || task.state === 'done') return false;
    if (task.state === 'queued') {
      this.queue.splice(this.queue.indexOf(id), 1);
      this.finish(task, 'E:20:canceled');
      return true;
    }
    const w = this.workers[task.worker];
    if (w?.task === id) w.webR.interrupt();
    return true;
  }

  /** What the console's Stop does: nothing queued or running survives it. */
  cancelAll() {
    for (const id of [...this.tasks.keys()]) this.cancel(id);
  }

  close() {
    this.generation++;
    const workers = this.workers;
    this.workers = [];
    this.queue.length = 0;
    for (const task of this.tasks.values()) this.finish(task, 'E:20:the worker pool was closed');
    for (const w of workers) w.webR?.close();
    if (workers.length) this.changed();
  }

  info() {
    return {
      generation: this.generation,
      workers: this.workers.length,
      ready: this.workers.filter((w) => w.ready).length,
      busy: this.workers.filter((w) => w.task !== null).length,
      queued: this.queue.length,
      completed: this.completed,
    };
  }

  /** info() as JSON, for R. */
  status() {
    return JSON.stringify(this.info());
  }

  changed() {
    this.onChange?.(this.info());
  }
}
