const PROMPT_MAIN = '> ';

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
  constructor(host, { onInput, onInterrupt, onBusyChange, onPrompt, theme }) {
    this.host = host;
    this.onInput = onInput;
    this.onInterrupt = onInterrupt;
    this.onBusyChange = onBusyChange;
    this.onPrompt = onPrompt;

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
    // From the end of the input, or R's output lands on the wrapped rows after the cursor.
    this.term.write(`${this.moveTo(this.promptLen + this.line.length)}\r\n`);
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

    switch (data) {
      case '\r':
        this.submit(this.line);
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
}
