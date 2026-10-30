import { CompletionPopup, commonPrefix, insertion } from './complete.js';

const CM_THEMES = { light: 'eclipse', dark: 'material-darker' };

// The stock R mode tags every identifier "variable", so a call is indistinguishable
// from any other name. Wrapping it and peeking for the "(" separates the two while
// the real tokenizer keeps its state, so names in strings and comments stay untouched.
// Re-registering under the same name keeps its wordChars/hintWords helpers and the
// text/x-rsrc MIME pointing here.
const baseRMode = window.CodeMirror.modes.r;
window.CodeMirror.defineMode('r', (config, parserConfig) => {
  const base = baseRMode(config, parserConfig);
  return {
    ...base,
    token(stream, state) {
      // Upstream only ends a braceless body (`function(s) c(s)`) at the next line, so a
      // closing bracket of the enclosing call on the same line stayed unmatched for good.
      if (stream.match(/^\s*[)\]}]/, false)) {
        while (state.ctx.type === 'block' && state.ctx.flags & 4) {
          state.indent = state.ctx.indent;
          state.ctx = state.ctx.prev;
        }
      }
      const style = base.token(stream, state);
      if (style === 'variable' && stream.match(/^\s*\(/, false)) return 'variable callee';
      return style;
    },
  };
});

export class Editor {
  constructor(host, tabsHost, { onRun, onSelect, complete, theme }) {
    this.host = host;
    this.tabsHost = tabsHost;
    // The strip's scrollbar is hidden, so let a mouse wheel scroll it sideways.
    tabsHost.addEventListener('wheel', (e) => {
      if (Math.abs(e.deltaY) > Math.abs(e.deltaX) && tabsHost.scrollWidth > tabsHost.clientWidth) {
        tabsHost.scrollLeft += e.deltaY;
        e.preventDefault();
      }
    }, { passive: false });
    this.onRun = onRun;
    this.onSelect = onSelect;
    // key -> { doc, clean } for files (key = path), or { title, element, onClose } for
    // custom tabs such as the data viewer (key = "custom:<id>").
    this.tabs = new Map();
    this.active = null;

    this.cm = window.CodeMirror(host, {
      mode: 'r',
      theme: CM_THEMES[theme],
      lineNumbers: true,
      indentUnit: 2,
      lineWrapping: false,
      // Ctrl/Cmd+S is handled page-wide in app.js.
      extraKeys: {
        'Cmd-Enter': () => this.runSelectionOrLine(),
        'Ctrl-Enter': () => this.runSelectionOrLine(),
        // The box stays open: Enter / Shift+Enter step through matches, Esc closes it.
        'Cmd-F': 'findPersistent',
        'Ctrl-F': 'findPersistent',
        Tab: () => this.tabKey(),
        'Ctrl-Space': () => this.requestCompletion(),
      },
    });

    this.cm.on('change', () => {
      const entry = this.tabs.get(this.active);
      if (entry?.doc) {
        entry.clean = false;
        this.renderTabs();
      }
    });

    this.complete = complete;
    // A completion request in flight is dropped once this moves on.
    this.completionSeq = 0;
    // { line, start, all } while the list is open: candidates replace [start, cursor).
    this.completion = null;
    this.popup = new CompletionPopup({ onPick: (c) => this.applyCompletion(c) });
    // Above extraKeys while the list is open.
    this.popupKeys = {
      Up: () => this.popup.move(-1),
      Down: () => this.popup.move(1),
      Enter: () => this.applyCompletion(this.popup.selected),
      Tab: () => this.applyCompletion(this.popup.selected),
      Esc: () => this.closeCompletion(),
    };
    this.cm.on('cursorActivity', () => this.updateCompletion());
    this.cm.on('blur', () => this.closeCompletion());
    this.cm.on('scroll', () => this.positionCompletion());
  }

  /** Tab completes after text and keeps its usual meaning anywhere else. */
  tabKey() {
    const cur = this.cm.getCursor();
    const before = this.cm.getLine(cur.line).slice(0, cur.ch);
    if (this.cm.somethingSelected() || !/\S/.test(before)) return window.CodeMirror.Pass;
    this.requestCompletion();
    return undefined;
  }

  /** A key from the phone key row, by its KeyboardEvent.key name. */
  pressKey(key) {
    if (this.completion && (key === 'ArrowUp' || key === 'ArrowDown')) {
      this.popup.move(key === 'ArrowUp' ? -1 : 1);
      return;
    }
    switch (key) {
      case 'Tab':
        if (this.completion) this.applyCompletion(this.popup.selected);
        else if (this.tabKey() === window.CodeMirror.Pass) this.cm.execCommand('defaultTab');
        return;
      case 'Escape':
        this.closeCompletion();
        return;
      case 'ArrowUp':
        this.cm.execCommand('goLineUp');
        return;
      case 'ArrowDown':
        this.cm.execCommand('goLineDown');
        return;
      case 'ArrowLeft':
        this.cm.execCommand('goCharLeft');
        return;
      case 'ArrowRight':
        this.cm.execCommand('goCharRight');
        return;
      default:
    }
  }

  /** Complete the token before the cursor from R, which knows the live session's objects. */
  async requestCompletion() {
    if (!this.complete || !this.activePath) return;
    const cm = this.cm;
    const doc = cm.getDoc();
    const cur = cm.getCursor();
    const line = cm.getLine(cur.line);
    const seq = ++this.completionSeq;
    let res;
    try {
      res = await this.complete(line, cur.ch);
    } catch {
      return;
    }
    if (!res || seq !== this.completionSeq || cm.getDoc() !== doc) return;
    const now = cm.getCursor();
    if (now.line !== cur.line || now.ch !== cur.ch || cm.getLine(cur.line) !== line) return;
    const { start, candidates } = res;
    this.completion = { line: cur.line, start, all: candidates };
    if (candidates.length === 1) {
      this.applyCompletion(candidates[0]);
      return;
    }
    cm.addKeyMap(this.popupKeys);
    this.popup.setItems(candidates);
    const token = line.slice(start, cur.ch);
    const prefix = commonPrefix(candidates);
    // Moves the cursor, so cursorActivity narrows the list to the new prefix.
    if (prefix.length > token.length && prefix.startsWith(token)) {
      cm.replaceRange(prefix, { line: cur.line, ch: start }, cur, '+complete');
    }
    this.positionCompletion();
  }

  applyCompletion(candidate) {
    if (!this.completion || candidate == null) return;
    const { line, start } = this.completion;
    this.closeCompletion();
    this.cm.replaceRange(insertion(candidate), { line, ch: start }, this.cm.getCursor(), '+complete');
  }

  /** Narrow the open list to what has been typed since, or close it. */
  updateCompletion() {
    if (!this.completion) return;
    const { line, start, all } = this.completion;
    const cur = this.cm.getCursor();
    const token = cur.line === line && cur.ch >= start ? this.cm.getLine(line).slice(start, cur.ch) : null;
    const items = token == null || /[\s(),;]/.test(token) ? [] : all.filter((c) => c.startsWith(token));
    if (!items.length || (items.length === 1 && items[0] === token)) {
      this.closeCompletion();
      return;
    }
    this.popup.setItems(items);
    this.positionCompletion();
  }

  positionCompletion() {
    if (!this.completion) return;
    const { line, start } = this.completion;
    this.popup.show(this.cm.cursorCoords({ line, ch: start }, 'window'));
  }

  closeCompletion() {
    this.completionSeq++;
    if (!this.completion && !this.popup.isOpen) return;
    this.completion = null;
    this.popup.close();
    this.cm.removeKeyMap(this.popupKeys);
  }

  open(path, text) {
    if (!this.tabs.has(path)) {
      this.tabs.set(path, { doc: window.CodeMirror.Doc(text, 'r'), clean: true });
    }
    this.select(path);
  }

  /** Show an arbitrary element as a tab. Re-opening an existing id just selects it. */
  openCustom(id, title, element, onClose) {
    const key = `custom:${id}`;
    if (!this.tabs.has(key)) {
      element.classList.add('custom-tab');
      element.hidden = true;
      this.host.append(element);
      this.tabs.set(key, { title, element, onClose });
    }
    this.select(key);
  }

  setTheme(scheme) {
    this.cm.setOption('theme', CM_THEMES[scheme]);
  }

  select(key) {
    const entry = this.tabs.get(key);
    if (!entry) return;
    this.closeCompletion();
    this.active = key;
    for (const [k, other] of this.tabs) {
      if (other.element) other.element.hidden = k !== key;
    }
    this.cm.getWrapperElement().hidden = Boolean(entry.element);
    if (entry.doc) {
      this.cm.swapDoc(entry.doc);
      this.cm.focus();
      // CodeMirror mis-measures if it was laid out while hidden.
      requestAnimationFrame(() => this.cm.refresh());
    }
    this.renderTabs();
    this.onSelect?.({ custom: Boolean(entry.element) });
  }

  close(key) {
    const entry = this.tabs.get(key);
    this.tabs.delete(key);
    if (entry?.element) {
      entry.element.remove();
      entry.onClose?.();
    }
    if (this.active !== key) {
      this.renderTabs();
      return;
    }
    const next = this.tabs.keys().next();
    this.active = null;
    if (!next.done) {
      this.select(next.value);
      return;
    }
    this.cm.getWrapperElement().hidden = false;
    this.cm.swapDoc(window.CodeMirror.Doc('', 'r'));
    this.renderTabs();
    this.onSelect?.({ custom: false });
  }

  refresh() {
    if (!this.cm.getWrapperElement().hidden) this.cm.refresh();
  }

  isClean(path = this.active) {
    return this.tabs.get(path)?.clean !== false;
  }

  markClean(path = this.active) {
    const entry = this.tabs.get(path);
    if (entry?.doc) {
      entry.clean = true;
      this.renderTabs();
    }
  }

  /** Path of the active file, or null when a custom tab is showing. */
  get activePath() {
    return this.tabs.get(this.active)?.doc ? this.active : null;
  }

  /** Select an open file and put the cursor on a 0-based line, scrolled into view. */
  goToLine(path, line) {
    this.select(path);
    const pos = { line: Math.min(line, this.cm.lastLine()), ch: 0 };
    this.cm.setCursor(pos);
    this.cm.scrollIntoView(pos, 80);
  }

  /** Mark the line the debugger has stopped at; null clears it. */
  setDebugLine(path, line) {
    if (this.debugMark) {
      this.debugMark.doc.removeLineClass(this.debugMark.handle, 'background', 'cm-debug-line');
      this.debugMark = null;
    }
    if (path == null) return;
    this.goToLine(path, line);
    const { doc } = this.tabs.get(path);
    this.debugMark = { doc, handle: doc.addLineClass(this.cm.getCursor().line, 'background', 'cm-debug-line') };
  }

  getValue() {
    return this.cm.getValue();
  }

  runSelectionOrLine() {
    if (!this.activePath) return;
    const selection = this.cm.getSelection();
    if (selection.trim()) {
      this.onRun(selection);
      return;
    }
    const line = this.cm.getCursor().line;
    if (!/\S/.test(this.cm.getLine(line).replace(/^\s*#.*$/, ''))) {
      this.moveToCode(line + 1);
      return;
    }
    const { from, to } = this.statementAt(line);
    this.onRun(this.cm.getRange({ line: from, ch: 0 }, { line: to, ch: this.cm.getLine(to).length }));
    this.moveToCode(to + 1);
  }

  /** Put the cursor on the first non-blank line at or after `line`. */
  moveToCode(line) {
    const last = this.cm.lastLine();
    while (line <= last && !/\S/.test(this.cm.getLine(line))) line++;
    if (line <= last) this.cm.setCursor({ line, ch: 0 });
  }

  /**
   * The lines of the top-level statement that contains `line`, from the R mode's own
   * parse state, so brackets and operators inside strings and comments do not count.
   * An unclosed bracket makes everything after it one statement, and R reports it.
   */
  statementAt(line) {
    let from = line;
    while (from > 0 && this.continues(from - 1)) from--;
    let to = line;
    while (to < this.cm.lastLine() && this.continues(to)) to++;
    return { from, to };
  }

  /** Whether the statement on `line` carries on past the end of it. */
  continues(line) {
    const state = this.cm.getStateAfter(line, true);
    if (state.tokenize !== this.cm.getMode().startState().tokenize) return true;
    let ctx = state.ctx;
    // A braceless if/for/function body that already has its statement is complete.
    while (ctx.type === 'block' && ctx.flags & 4) ctx = ctx.prev;
    if (ctx.type !== 'top') return true;
    const tokens = this.cm.getLineTokens(line, true).filter((t) => t.type !== 'comment' && t.string.trim());
    const last = tokens[tokens.length - 1];
    return Boolean(last && (/\boperator\b|\barg-is\b/.test(last.type ?? '') || last.string === ','));
  }

  runAll() {
    if (!this.activePath) return;
    this.onRun(this.cm.getValue());
  }

  renderTabs() {
    this.tabsHost.replaceChildren();
    let activeTab = null;
    for (const [key, entry] of this.tabs) {
      const tab = document.createElement('button');
      tab.className = `etab${key === this.active ? ' active' : ''}`;
      tab.title = entry.element ? entry.title : key;

      const label = document.createElement('span');
      label.textContent = entry.element ? entry.title : key.split('/').pop();
      tab.append(label);

      if (entry.doc && !entry.clean) {
        const dot = document.createElement('span');
        dot.className = 'dirty';
        dot.textContent = '●';
        tab.append(dot);
      }

      const close = document.createElement('span');
      close.className = 'close';
      close.textContent = '×';
      close.addEventListener('click', (e) => {
        e.stopPropagation();
        this.close(key);
      });
      tab.append(close);

      tab.addEventListener('click', () => this.select(key));
      this.tabsHost.append(tab);
      if (key === this.active) activeTab = tab;
    }
    activeTab?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }
}
