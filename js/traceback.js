/**
 * The Traceback tab: while debugging, the live call stack (innermost first); after an
 * uncaught error, that error's calls. Rows with a source position open it.
 */
export class TracebackPane {
  constructor(host, { onSelectFrame, onOpen }) {
    this.host = host;
    this.onSelectFrame = onSelectFrame;
    this.onOpen = onOpen;
    this.showMessage('Nothing to show. The call stack appears here while debugging, and an error\u2019s calls after \u201cShow traceback\u201d.');
  }

  showMessage(text) {
    const p = document.createElement('p');
    p.className = 'pane-msg';
    p.textContent = text;
    this.host.replaceChildren(p);
  }

  /** `stack` is outermost first, as sys.calls(); frames are sys.frame() numbers. */
  showStack(stack, selected) {
    this.mode = 'stack';
    this.render('Call stack', [...stack].reverse().map((f) => ({ ...f, label: `${f.frame}: ${f.call}` })), selected);
  }

  setSelected(frame) {
    for (const row of this.host.querySelectorAll('.tb-row')) {
      row.classList.toggle('selected', Number(row.dataset.frame) === frame);
    }
  }

  /** Debugging ended: keep the last stack, but its frames are gone. */
  finish() {
    if (this.mode !== 'stack') return;
    this.mode = 'finished';
    this.host.querySelector('.tb-title').textContent = 'Call stack (finished)';
    for (const row of this.host.querySelectorAll('.tb-row')) row.classList.remove('selected');
  }

  /** `rows` are innermost first, as traceback(). */
  showError(message, rows) {
    this.mode = 'error';
    this.render(message, rows.map((r, i) => ({ ...r, label: `${rows.length - i}: ${r.call}` })), null);
  }

  render(title, rows, selected) {
    const head = document.createElement('div');
    head.className = 'tb-title';
    head.textContent = title;
    const list = document.createElement('div');
    list.className = 'tb-list';
    for (const row of rows) {
      const el = document.createElement('div');
      el.className = 'tb-row';
      if (row.frame) el.dataset.frame = row.frame;
      el.classList.toggle('selected', row.frame === selected);
      const call = document.createElement('span');
      call.className = 'tb-call';
      call.textContent = row.label;
      el.append(call);
      if (row.file) {
        const pos = document.createElement('span');
        pos.className = 'tb-pos';
        pos.textContent = `${row.file.split('/').pop()}#${row.line}`;
        pos.title = `${row.file}#${row.line}`;
        el.append(pos);
      }
      if (row.file || (row.frame && this.mode === 'stack')) {
        el.classList.add('clickable');
        el.addEventListener('click', () => {
          if (row.frame && this.mode === 'stack') {
            this.setSelected(row.frame);
            this.onSelectFrame(row.frame);
          }
          if (row.file) this.onOpen(row.file, row.line);
        });
      }
      list.append(el);
    }
    this.host.replaceChildren(head, list);
  }
}
