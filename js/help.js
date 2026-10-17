// ../../pkg/help/topic, ../help/topic, or a bare topic.html (the footer's 00Index.html).
const HELP_LINK = /^(?:\.\.\/\.\.\/([^/]+)\/(?:help|html)\/|\.\.\/(?:help|html)\/)?([^/?#]+?)(?:\.html)?(?:[?#].*)?$/;

/**
 * Rendered R help (tools::Rd2HTML in r/webrapp.R) in a sandboxed frame. Links inside
 * the frame are posted here and resolved to a package and topic.
 */
export class HelpPane {
  constructor(host, { query, isBusy, onShow, scheme }) {
    this.host = host;
    this.query = query;
    this.isBusy = isBusy;
    this.onShow = onShow;
    this.scheme = scheme;
    this.history = [];
    this.index = -1;

    const bar = document.createElement('div');
    bar.className = 'help-bar';
    this.back = this.button('‹', 'Back', () => this.go(-1));
    this.forward = this.button('›', 'Forward', () => this.go(1));
    this.search = document.createElement('input');
    this.search.type = 'search';
    this.search.className = 'pane-search';
    this.search.placeholder = 'Help topic, e.g. brm or stats::lm';
    this.search.addEventListener('keydown', (e) => {
      if (e.key !== 'Enter' || !this.search.value.trim()) return;
      const [pkg, topic] = this.search.value.trim().includes('::')
        ? this.search.value.trim().split(/:::?/)
        : ['', this.search.value.trim()];
      this.open(topic, pkg);
    });
    this.status = document.createElement('span');
    this.status.className = 'help-status';
    bar.append(this.back, this.forward, this.search, this.status);

    this.frameHost = document.createElement('div');
    this.frameHost.className = 'help-frame-host';
    const empty = document.createElement('p');
    empty.className = 'viewer-empty';
    empty.textContent = 'Type ?topic in the console, or a topic above.';
    this.frameHost.append(empty);
    host.replaceChildren(bar, this.frameHost);
    this.updateButtons();

    window.addEventListener('message', (e) => {
      if (!this.frame || e.source !== this.frame.contentWindow) return;
      const href = e.data?.webrappHelp;
      if (typeof href === 'string') this.follow(href);
    });
  }

  button(text, title, onClick) {
    const b = document.createElement('button');
    b.className = 'glyph';
    b.textContent = text;
    b.title = title;
    b.addEventListener('click', onClick);
    return b;
  }

  /** A page from the console's ?topic, written to the VFS by print_help(). */
  showFile(text) {
    const marker = /^<!-- webrapp-help (.*?) -->\n/.exec(text);
    const meta = marker ? JSON.parse(marker[1]) : { pkg: '', topic: '' };
    this.push({ html: marker ? text.slice(marker[0].length) : text, ...meta });
  }

  showText(title, text) {
    const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    this.push({
      html: `<!DOCTYPE html><html><head><style>html{background:light-dark(#fff,#1e1e1e)}</style></head><body style="font:14px system-ui,sans-serif;margin:12px 16px">` +
        `<h3>${esc(title)}</h3><pre style="white-space:pre-wrap">${esc(text)}</pre></body>`,
      pkg: '',
      topic: title,
    });
  }

  async open(topic, pkg = '') {
    await this.fetch(() => this.query('help_topic', topic, pkg));
  }

  async openIndex(pkg) {
    await this.fetch(() => this.query('help_index', pkg));
  }

  async fetch(load) {
    if (this.isBusy()) {
      this.setStatus('R is busy; try again when it finishes.');
      this.onShow?.();
      return;
    }
    this.setStatus('');
    try {
      this.push(await load());
    } catch (err) {
      this.setStatus(err.message);
      this.onShow?.();
    }
  }

  follow(href) {
    if (/^https?:\/\//i.test(href)) {
      window.open(href, '_blank', 'noopener,noreferrer');
      return;
    }
    const current = this.history[this.index] ?? { pkg: '' };
    const m = HELP_LINK.exec(href);
    if (!m) {
      this.setStatus(`Cannot follow link: ${href}`);
      return;
    }
    const pkg = m[1] ?? current.pkg;
    const target = decodeURIComponent(m[2]);
    if (target === '00Index') this.openIndex(pkg);
    else this.open(target, pkg);
  }

  push(page) {
    this.history = this.history.slice(0, this.index + 1);
    this.history.push(page);
    if (this.history.length > 50) this.history.shift();
    this.index = this.history.length - 1;
    this.render();
  }

  go(delta) {
    const next = this.index + delta;
    if (next < 0 || next >= this.history.length) return;
    this.index = next;
    this.render();
  }

  setTheme(scheme) {
    this.scheme = scheme;
    if (this.frame) this.render({ show: false });
  }

  render({ show = true } = {}) {
    const page = this.history[this.index];
    this.frame = document.createElement('iframe');
    this.frame.className = 'viewer-frame';
    // Scripts only for the link catcher; no same-origin, so the page stays opaque.
    this.frame.setAttribute('sandbox', 'allow-scripts');
    // A frame follows the OS colour scheme, not the app's Light/Dark override.
    this.frame.srcdoc = page.html.replace('<head>', `<head><style>:root{color-scheme:${this.scheme}}</style>`);
    this.frameHost.replaceChildren(this.frame);
    this.setStatus(page.pkg ? `{${page.pkg}}` : '');
    this.updateButtons();
    if (show) this.onShow?.();
  }

  updateButtons() {
    this.back.disabled = this.index <= 0;
    this.forward.disabled = this.index >= this.history.length - 1;
  }

  setStatus(text) {
    this.status.textContent = text;
  }
}
