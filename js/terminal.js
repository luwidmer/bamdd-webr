import { CompletionPopup, commonPrefix, insertion } from './complete.js';

const PROMPT_MAIN = '> ';

// Prompts at which a line is R code; readline() and menu() prompts are not completed.
const CODE_PROMPT = /^(?:> |\+ |Browse\[\d+\]> )$/;

// Where the primary pointer is a finger, the input line is mirrored into xterm's hidden
// textarea instead of being fed through xterm's own IME handling; see mirrorInput().
const touchQuery = window.matchMedia('(pointer: coarse)');

// Keys the phone key row and the mirrored textarea send, as the sequences xterm would.
const KEY_DATA = {
  Enter: '\r',
  Tab: '\t',
  Escape: '\x1b',
  ArrowUp: '\x1b[A',
  ArrowDown: '\x1b[B',
  ArrowRight: '\x1b[C',
  ArrowLeft: '\x1b[D',
  Home: '\x1b[H',
  End: '\x1b[F',
  Delete: '\x1b[3~',
};
const CTRL_DATA = { a: '\x01', c: '\x03', e: '\x05', l: '\x0c' };

// xterm colours itself in JS, and reading the CSS palette back is not an option: an
// unregistered custom property computes to its token stream, so getComputedStyle would
// return the literal "light-dark(...)" rather than a colour. Light needs the full ANSI
// block because xterm's default one is tuned for a dark background, and R's cli output
// uses it heavily; dark keeps xterm's defaults, as it always has.
const THEMES = {
  dark: {
    background: '#1e1e1e',
    foreground: '#d4d4d4',
    cursor: '#4a9eff',
  },
  light: {
    background: '#ffffff',
    foreground: '#1f1f1f',
    cursor: '#0066cc',
    selectionBackground: '#add6ff',
    black: '#000000',
    red: '#cd3131',
    green: '#00bc00',
    yellow: '#949800',
    blue: '#0451a5',
    magenta: '#bc05bc',
    cyan: '#0598bc',
    white: '#555555',
    brightBlack: '#666666',
    brightRed: '#cd3131',
    brightGreen: '#14ce14',
    brightYellow: '#b5ba00',
    brightBlue: '#0451a5',
    brightMagenta: '#bc05bc',
    brightCyan: '#0598bc',
    brightWhite: '#a5a5a5',
  },
};

export class Terminal {
  constructor(host, { onInput, onInterrupt, onBusyChange, onPrompt, complete, theme }) {
    this.host = host;
    this.onInput = onInput;
    this.onInterrupt = onInterrupt;
    this.onBusyChange = onBusyChange;
    this.onPrompt = onPrompt;
    this.complete = complete;

    // Lines queued by "Run" are held here and echoed only when R asks for input,
    // otherwise the transcript interleaves out of order with R's own output.
    this.queue = [];
    this.line = '';
    this.cursor = 0;
    // Where xterm's cursor is, as an offset from the start of the prompt.
    this.at = 0;
    this.pendingInput = '';
    this.acceptingInput = false;
    this.history = [];
    this.historyIndex = 0;
    this.busy = false;
    // The last complete top-level command, from a "> " prompt through its "+ " lines.
    this.lastCommand = '';
    this.linkRules = [];

    this.term = new window.Terminal({
      convertEol: true,
      cursorBlink: true,
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
      fontSize: 13,
      scrollback: 20000,
      theme: THEMES[theme],
    });

    this.fit = new window.FitAddon.FitAddon();
    this.term.loadAddon(this.fit);
    this.term.open(host);
    this.fit.fit();

    new ResizeObserver(() => this.safeFit()).observe(host);
    this.term.onData((d) => this.handleData(d));
    this.term.registerLinkProvider({ provideLinks: (y, done) => done(this.linksOn(y)) });

    // A completion request in flight is dropped once this moves on.
    this.completionSeq = 0;
    // { start, all } while the list is open: the candidates replace line[start, cursor).
    this.completion = null;
    this.popup = new CompletionPopup({ onPick: (c) => this.applyCompletion(c) });
    this.term.onScroll(() => this.positionCompletion());
    // Picking from the list does not move focus, so this only fires on leaving the console.
    this.term.textarea.addEventListener('blur', () => this.closeCompletion());

    this.composing = false;
    this.mirror = touchQuery.matches;
    touchQuery.addEventListener('change', () => {
      this.mirror = touchQuery.matches;
      if (this.mirror) this.syncTextarea();
      else this.term.textarea.value = '';
    });
    this.installMirror();
  }

  /** Make text matching `pattern` (a global regex) clickable anywhere in the console. */
  addLinkRule(pattern, activate) {
    this.linkRules.push({ pattern, activate });
  }

  linksOn(y) {
    const line = this.term.buffer.active.getLine(y - 1);
    if (!line) return undefined;
    const text = line.translateToString(true);
    const links = [];
    for (const { pattern, activate } of this.linkRules) {
      for (const m of text.matchAll(pattern)) {
        links.push({
          range: { start: { x: m.index + 1, y }, end: { x: m.index + m[0].length, y } },
          text: m[0],
          activate: () => activate(m, y - 1),
        });
      }
    }
    return links.length ? links : undefined;
  }

  /** Write a line while R is running and resolve to an xterm marker on it. */
  writeMarked(text) {
    return new Promise((resolve) => {
      this.term.write(`${text.replace(/\n/g, '\r\n')}\r\n`, () => resolve(this.term.registerMarker(-1)));
    });
  }

  safeFit(retries = 10) {
    // Opened in a hidden pane (the phone layout), xterm has no cell size until it has
    // rendered once while visible; until then fit() silently does nothing.
    let dims;
    try {
      dims = this.fit.proposeDimensions();
    } catch {
      // Hidden pane, zero size.
    }
    if (!dims || !this.host.offsetWidth) {
      if (retries > 0 && this.host.offsetWidth) requestAnimationFrame(() => this.safeFit(retries - 1));
      return;
    }
    const cols = this.term.cols;
    this.fit.fit();
    // xterm reflows the wrapped input; repaint so the cursor arithmetic matches it.
    if (this.term.cols !== cols && this.acceptingInput) this.redrawAll();
    this.positionCompletion();
  }

  focus() {
    this.term.focus();
  }

  setTheme(scheme) {
    this.term.options.theme = THEMES[scheme];
  }

  setBusy(busy) {
    if (this.busy === busy) return;
    this.busy = busy;
    this.onBusyChange?.(busy);
  }

  write(text) {
    this.term.write(text.replace(/\n/g, '\r\n'));
  }

  writeLine(text = '') {
    if (!this.acceptingInput) {
      this.write(`${text}\n`);
      return;
    }
    // At a prompt: print above it and redraw prompt and input, as readline does.
    this.closeCompletion();
    const cols = this.term.cols || 80;
    const rows = Math.floor(this.at / cols);
    this.term.write(`\r${rows > 0 ? `\x1b[${rows}A` : ''}\x1b[J${text.replace(/\n/g, '\r\n')}\r\n${this.currentPrompt ?? PROMPT_MAIN}`);
    this.at = this.promptLen;
    this.renderFrom(0);
  }

  /** Queue code to be fed to R as if typed. */
  enqueue(code) {
    const lines = code.replace(/\r\n/g, '\n').split('\n');
    while (lines.length && lines[lines.length - 1].trim() === '') lines.pop();
    if (!lines.length) return;
    this.queue.push(...lines);
    this.setBusy(true);
    // If R is already waiting at a prompt, nothing will pull the queue until the
    // next prompt arrives, so drain it now.
    if (this.acceptingInput) this.drain();
  }

  /** Stop the running command and drop everything queued behind it, e.g. by Run all. */
  interrupt() {
    this.write('^C\n');
    this.queue.length = 0;
    this.pendingInput = '';
    this.onInterrupt();
  }

  /** Forget input state when R is replaced; busy until the new R prompts. */
  reset() {
    this.queue.length = 0;
    this.pendingInput = '';
    this.acceptingInput = false;
    this.line = '';
    this.cursor = 0;
    this.closeCompletion();
    this.syncTextarea();
    this.setBusy(true);
  }

  /** Called when R asks for input. */
  handlePrompt(prompt) {
    this.currentPrompt = prompt ?? PROMPT_MAIN;
    this.onPrompt?.(this.currentPrompt);
    this.write(this.currentPrompt);
    this.acceptingInput = true;
    this.line = '';
    this.cursor = 0;
    this.at = this.promptLen;
    if (this.drain()) return;
    this.setBusy(false);
    this.syncTextarea();
    // The unfinished last line of a multi-line paste waits here for more typing.
    if (this.pendingInput) {
      const text = this.pendingInput;
      this.pendingInput = '';
      this.insert(text);
    }
  }

  /** Feed one queued line, if any. Returns true if a line was sent. */
  drain() {
    if (!this.queue.length) return false;
    const line = this.queue.shift();
    this.acceptingInput = false;
    this.writeLine(line);
    this.record(line);
    this.setBusy(true);
    this.onInput(`${line}\n`);
    return true;
  }

  submit(line) {
    this.acceptingInput = false;
    this.closeCompletion();
    // From the end of the input, or R's output lands on the wrapped rows after the cursor.
    this.term.write(`${this.moveTo(this.promptLen + this.line.length)}\r\n`);
    this.syncTextarea();
    if (line.trim()) {
      this.history.push(line);
      if (this.history.length > 500) this.history.shift();
    }
    this.historyIndex = this.history.length;
    this.record(line);
    this.setBusy(true);
    this.onInput(`${line}\n`);
  }

  /** Lines at a Browse[n]> prompt are debugger commands, not part of a command. */
  record(line) {
    if (this.currentPrompt === PROMPT_MAIN) this.lastCommand = line;
    else if (this.currentPrompt === '+ ') this.lastCommand += `\n${line}`;
  }

  get promptLen() {
    return (this.currentPrompt ?? PROMPT_MAIN).length;
  }

  /**
   * Escape sequence moving the cursor from this.at to an offset counted from the start
   * of the prompt. Relative moves, never a return to column 0: every intermediate
   * position can be painted, and a cursor flashing at the line start is the visible
   * noise this replaces.
   */
  moveTo(offset) {
    const cols = this.term.cols || 80;
    const dr = Math.floor(offset / cols) - Math.floor(this.at / cols);
    const dc = (offset % cols) - (this.at % cols);
    let s = '';
    if (dr < 0) s += `\x1b[${-dr}A`;
    if (dr > 0) s += `\x1b[${dr}B`;
    if (dc > 0) s += `\x1b[${dc}C`;
    if (dc < 0) s += `\x1b[${-dc}D`;
    this.at = offset;
    return s;
  }

  /**
   * Repaint the input from character `from` onwards and place the cursor, in a single
   * write so xterm never renders a half-updated line.
   */
  renderFrom(from) {
    const cols = this.term.cols || 80;
    const end = this.promptLen + this.line.length;
    let s = this.moveTo(this.promptLen + from) + this.line.slice(from);
    // Text ending exactly at the right edge leaves xterm in a pending-wrap state, still
    // on the row above; step onto the next row so the offset arithmetic holds.
    if (from < this.line.length && end % cols === 0) s += ' \b';
    this.at = end;
    s += `\x1b[J${this.moveTo(this.promptLen + this.cursor)}`;
    this.term.write(s);
    this.syncTextarea();
  }

  /** Repaint prompt and input from scratch, e.g. after the screen was cleared. */
  redrawAll() {
    const cols = this.term.cols || 80;
    const rows = Math.floor(this.at / cols);
    this.term.write(`\r${rows > 0 ? `\x1b[${rows}A` : ''}\x1b[J${this.currentPrompt ?? PROMPT_MAIN}`);
    this.at = this.promptLen;
    this.renderFrom(0);
  }

  insert(text) {
    const at = this.cursor;
    this.line = this.line.slice(0, at) + text + this.line.slice(at);
    this.cursor += text.length;
    this.renderFrom(at);
  }

  setCursor(cursor) {
    this.cursor = cursor;
    this.term.write(this.moveTo(this.promptLen + cursor));
    this.syncTextarea();
  }

  replaceLine(next) {
    this.line = next;
    this.cursor = next.length;
    this.renderFrom(0);
  }

  /** Complete lines run in order; an unfinished last line is left at the prompt. */
  paste(text) {
    const lines = text.replace(/\r\n?/g, '\n').replace(/\t/g, '  ').split('\n');
    const first = this.line.slice(0, this.cursor) + lines.shift() + this.line.slice(this.cursor);
    this.pendingInput = lines.pop();
    this.queue.push(...lines);
    this.line = first;
    this.cursor = first.length;
    this.renderFrom(0);
    this.submit(first);
  }

  handleData(data) {
    // Ctrl+C works even while R is busy; that is the whole point of it.
    if (data === '\x03') {
      this.interrupt();
      return;
    }
    if (!this.acceptingInput) return;

    if (this.completion) {
      switch (data) {
        case '\x1b[A':
          this.popup.move(-1);
          return;
        case '\x1b[B':
          this.popup.move(1);
          return;
        case '\t':
        case '\r':
          this.applyCompletion(this.popup.selected);
          return;
        case '\x1b':
          this.closeCompletion();
          return;
        default:
          break;
      }
    }

    this.editLine(data);
    this.updateCompletion();
  }

  editLine(data) {
    switch (data) {
      case '\r':
        this.submit(this.line);
        return;
      case '\t':
        this.requestCompletion();
        return;
      case '\x7f': // backspace
        if (this.cursor > 0) {
          const at = this.cursor - 1;
          this.line = this.line.slice(0, at) + this.line.slice(this.cursor);
          this.cursor = at;
          this.renderFrom(at);
        }
        return;
      case '\x1b[3~': // delete
        if (this.cursor < this.line.length) {
          this.line = this.line.slice(0, this.cursor) + this.line.slice(this.cursor + 1);
          this.renderFrom(this.cursor);
        }
        return;
      case '\x1b[A': // up
        if (this.historyIndex > 0) {
          this.historyIndex--;
          this.replaceLine(this.history[this.historyIndex] ?? '');
        }
        return;
      case '\x1b[B': // down
        if (this.historyIndex < this.history.length - 1) {
          this.historyIndex++;
          this.replaceLine(this.history[this.historyIndex] ?? '');
        } else {
          this.historyIndex = this.history.length;
          this.replaceLine('');
        }
        return;
      case '\x1b[D': // left
        if (this.cursor > 0) this.setCursor(this.cursor - 1);
        return;
      case '\x1b[C': // right
        if (this.cursor < this.line.length) this.setCursor(this.cursor + 1);
        return;
      case '\x01': // Ctrl+A
      case '\x1b[H':
      case '\x1bOH':
      case '\x1b[1~':
        this.setCursor(0);
        return;
      case '\x05': // Ctrl+E
      case '\x1b[F':
      case '\x1bOF':
      case '\x1b[4~':
        this.setCursor(this.line.length);
        return;
      case '\x0c': // Ctrl+L
        this.term.clear();
        this.redrawAll();
        return;
      default:
        break;
    }

    if (/[\r\n]/.test(data)) {
      this.paste(data);
      return;
    }
    // Anything left with a control character is an unhandled key sequence.
    const text = data.replace(/\t/g, '  ');
    if (!/[\x00-\x1f\x7f]/.test(text)) this.insert(text);
  }

  /** A key from the phone key row, by its KeyboardEvent.key name. */
  pressKey(key) {
    if (KEY_DATA[key]) this.handleData(KEY_DATA[key]);
  }

  // ---------------------------------------------------------------- completion

  /** Tab: complete the token before the cursor, from R itself. */
  async requestCompletion() {
    if (!this.complete || !CODE_PROMPT.test(this.currentPrompt ?? PROMPT_MAIN)) return;
    const { line, cursor } = this;
    const seq = ++this.completionSeq;
    let res;
    try {
      res = await this.complete(line, cursor);
    } catch {
      return;
    }
    if (!res || seq !== this.completionSeq || !this.acceptingInput) return;
    if (this.line !== line || this.cursor !== cursor) return;
    const { start, candidates } = res;
    this.completion = { start, all: candidates };
    if (candidates.length === 1) {
      this.applyCompletion(candidates[0]);
      return;
    }
    const token = line.slice(start, cursor);
    const prefix = commonPrefix(candidates);
    if (prefix.length > token.length && prefix.startsWith(token)) this.replaceToken(start, prefix);
    this.popup.setItems(candidates);
    this.positionCompletion();
  }

  replaceToken(start, text) {
    this.line = this.line.slice(0, start) + text + this.line.slice(this.cursor);
    this.cursor = start + text.length;
    this.renderFrom(start);
  }

  applyCompletion(candidate) {
    if (!this.completion || candidate == null || !this.acceptingInput) return;
    const { start } = this.completion;
    this.closeCompletion();
    this.replaceToken(start, insertion(candidate));
  }

  /** Narrow the open list to what has been typed since, or close it. */
  updateCompletion() {
    if (!this.completion) return;
    const { start, all } = this.completion;
    const token = this.line.slice(start, this.cursor);
    const items = this.cursor < start || /[\s(),;]/.test(token) ? [] : all.filter((c) => c.startsWith(token));
    if (!items.length || (items.length === 1 && items[0] === token)) {
      this.closeCompletion();
      return;
    }
    this.popup.setItems(items);
    this.positionCompletion();
  }

  closeCompletion() {
    this.completion = null;
    this.completionSeq++;
    this.popup.close();
  }

  /** Put the list under the start of the token, once xterm has drawn the input. */
  positionCompletion() {
    if (!this.completion) return;
    const offset = this.promptLen + this.completion.start;
    // xterm's cursor reaches this.at only when the queued writes are parsed.
    const at = this.at;
    this.term.write('', () => {
      const screen = this.term.element?.querySelector('.xterm-screen');
      if (!this.completion || !screen) return;
      const rect = screen.getBoundingClientRect();
      const { cols, rows } = this.term;
      const cellW = rect.width / cols;
      const cellH = rect.height / rows;
      const b = this.term.buffer.active;
      const row = b.baseY + b.cursorY - b.viewportY + Math.floor(offset / cols) - Math.floor(at / cols);
      const top = rect.top + row * cellH;
      this.popup.show({ left: rect.left + (offset % cols) * cellW, top, bottom: top + cellH });
    });
  }

  // ---------------------------------------------------------------- touch keyboards

  /**
   * xterm turns textarea changes into keystrokes by diffing the textarea, which only
   * works for typing at the end: when a phone keyboard swaps a whole word for one of its
   * suggestions, xterm re-sends the textarea's contents and the line fills with
   * fragments. With a touch pointer xterm never sees the textarea's events. Instead the
   * textarea always holds exactly the input line, so the keyboard edits it as it would
   * any text field, and the line is read back from it after every change.
   */
  installMirror() {
    const ta = this.term.textarea;
    const swallow = (type, handler) => {
      // Capturing on the host runs first, and stopping here keeps the event from xterm.
      this.host.addEventListener(type, (e) => {
        if (!this.mirror || e.target !== ta) return;
        e.stopPropagation();
        handler?.(e);
      }, true);
    };
    swallow('keydown', (e) => this.mirrorKeydown(e));
    swallow('keypress');
    swallow('keyup');
    swallow('beforeinput');
    swallow('compositionstart', () => {
      this.composing = true;
    });
    swallow('compositionupdate');
    swallow('compositionend', () => {
      this.composing = false;
      this.mirrorInput();
    });
    swallow('input', () => this.mirrorInput());
    swallow('paste', (e) => {
      e.preventDefault();
      const text = e.clipboardData?.getData('text/plain');
      if (text) this.handleData(text);
    });
    // Moving the cursor by dragging on the space bar.
    document.addEventListener('selectionchange', () => {
      if (this.mirror && document.activeElement === ta) this.mirrorSelection();
    });
    // xterm empties the textarea when it loses focus.
    ta.addEventListener('focus', () => this.syncTextarea());
  }

  mirrorKeydown(e) {
    // An IME key; the input event that follows says what it did.
    if (e.isComposing || e.keyCode === 229) return;
    let data;
    if (e.ctrlKey && !e.altKey && !e.metaKey) data = CTRL_DATA[e.key.toLowerCase()];
    else if (!e.ctrlKey && !e.altKey && !e.metaKey) data = KEY_DATA[e.key];
    // Everything else, Backspace included, edits the textarea natively.
    if (!data) return;
    e.preventDefault();
    this.term.scrollToBottom();
    this.handleData(data);
  }

  mirrorInput() {
    const ta = this.term.textarea;
    if (!this.acceptingInput) {
      if (!this.composing) ta.value = '';
      return;
    }
    // xterm does this for input it handles itself.
    this.term.scrollToBottom();
    const value = ta.value;
    const breaks = value.match(/\r\n?|\n/g)?.length ?? 0;
    if (breaks === 1) {
      // Enter, wherever the cursor is, runs the whole line -- or picks the completion.
      this.composing = false;
      const at = value.search(/\r\n?|\n/);
      const line = value.replace(/\r\n?|\n/, '');
      if (this.completion) {
        this.applyMirror(line, at);
        this.syncTextarea();
        this.applyCompletion(this.popup.selected);
        return;
      }
      this.applyMirror(line, line.length);
      this.submit(this.line);
      return;
    }
    if (breaks > 1) {
      this.composing = false;
      this.line = '';
      this.cursor = 0;
      this.paste(value);
      return;
    }
    this.applyMirror(value, ta.selectionStart);
    this.updateCompletion();
  }

  /** Take the line from the textarea and repaint what changed. */
  applyMirror(value, cursor) {
    if (value === this.line && cursor === this.cursor) return;
    let from = 0;
    while (from < this.line.length && from < value.length && this.line[from] === value[from]) from++;
    this.line = value;
    this.cursor = Math.min(cursor, value.length);
    this.mirroring = true;
    try {
      this.renderFrom(from);
    } finally {
      this.mirroring = false;
    }
  }

  mirrorSelection() {
    const ta = this.term.textarea;
    if (!this.acceptingInput || this.composing || ta.value !== this.line) return;
    if (ta.selectionStart === this.cursor || ta.selectionStart !== ta.selectionEnd) return;
    this.mirroring = true;
    try {
      this.setCursor(ta.selectionStart);
    } finally {
      this.mirroring = false;
    }
    this.updateCompletion();
  }

  /**
   * Make the textarea hold the input line again after the line changed some other way
   * (history, completion, a prompt). Overwriting it also ends any composition in
   * progress, so the keyboard starts afresh from the new text.
   */
  syncTextarea() {
    const ta = this.term?.textarea;
    if (!this.mirror || this.mirroring || !ta) return;
    const value = this.acceptingInput ? this.line : '';
    const cursor = this.acceptingInput ? this.cursor : 0;
    if (ta.value === value && ta.selectionStart === cursor && ta.selectionEnd === cursor) return;
    this.composing = false;
    ta.value = value;
    ta.setSelectionRange(cursor, cursor);
  }
}
