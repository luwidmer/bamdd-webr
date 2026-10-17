/**
 * One environment, one row per object; lists and data frames expand. The selector
 * walks the chain of enclosing environments, as in RStudio. An environment is a frame
 * (0 = global; a sys.frame() number while debugging) plus a number of parent steps.
 */
export class EnvironmentPane {
  constructor(host, { query, onView }) {
    this.host = host;
    this.query = query;
    this.onView = onView;
    this.frame = 0;
    this.depth = 0;
    this.chain = [];
    this.filter = '';
    this.expanded = new Set();
    this.children = new Map();
    // Package environments list names only; these are the ones described on demand.
    this.described = new Map();
  }

  /** Show a frame of the code being debugged (0 = global), from the top of its chain. */
  selectFrame(frame) {
    if (frame === this.frame && this.depth === 0) return;
    this.frame = frame;
    this.depth = 0;
    this.reset();
  }

  get frameSelected() {
    return this.frame;
  }

  reset() {
    this.expanded.clear();
    this.children.clear();
    this.described.clear();
  }

  async refresh() {
    this.chain = await this.query('env_chain', this.frame);
    if (this.depth >= this.chain.length) this.depth = 0;
    const res = await this.query('env_summary', this.frame, this.depth);
    this.lite = res.lite;
    this.names = res.lite ? res.names : res.rows.map((r) => r.name);
    this.rows = res.lite ? null : res.rows;
    this.children.clear();
    for (const name of [...this.expanded]) {
      const row = this.rows?.find((r) => r.name === name);
      if (!row?.expandable) this.expanded.delete(name);
      else this.children.set(name, await this.query('env_children', name, this.frame, this.depth));
    }
    for (const name of [...this.described.keys()]) {
      if (!this.names.includes(name)) this.described.delete(name);
    }
    this.render();
  }

  showError(message) {
    const p = document.createElement('p');
    p.className = 'pane-msg error';
    p.textContent = message;
    this.host.replaceChildren(p);
  }

  render() {
    this.list = document.createElement('div');
    this.list.className = 'env-list';
    this.host.replaceChildren(this.header(), this.list);
    this.renderList();
  }

  header() {
    const bar = document.createElement('div');
    bar.className = 'env-bar';
    const select = document.createElement('select');
    select.title = 'Environment shown, and the environments enclosing it';
    for (const { depth, label, kind } of this.chain) {
      select.append(new Option(`${'\u00a0'.repeat(depth * 2)}${kind === 'frame' ? `${label} (frame)` : label}`, String(depth)));
    }
    select.value = String(this.depth);
    select.addEventListener('change', async () => {
      this.depth = Number(select.value);
      this.reset();
      try {
        await this.refresh();
      } catch (err) {
        this.showError(`Could not read from R: ${err.message}`);
      }
    });
    const filter = document.createElement('input');
    filter.type = 'search';
    filter.className = 'pane-search';
    filter.placeholder = 'Filter';
    filter.value = this.filter;
    filter.addEventListener('input', () => {
      this.filter = filter.value;
      this.renderList();
    });
    bar.append(select, filter);
    return bar;
  }

  renderList() {
    const needle = this.filter.trim().toLowerCase();
    const keep = (name) => !needle || name.toLowerCase().includes(needle);
    const nodes = [];
    if (this.lite) {
      for (const name of this.names.filter(keep)) {
        const row = this.described.get(name);
        nodes.push(row ? this.makeRow(row, 0, () => this.describe(name)) : this.makeNameRow(name));
      }
    } else {
      for (const row of this.rows.filter((r) => keep(r.name))) {
        nodes.push(this.makeRow(row, 0, row.expandable ? () => this.toggle(row.name) : null));
        if (!this.expanded.has(row.name)) continue;
        const kids = this.children.get(row.name);
        for (const child of kids?.rows ?? []) nodes.push(this.makeRow(child, 1, null));
        if (kids?.more > 0) {
          const more = document.createElement('div');
          more.className = 'env-row env-more';
          more.textContent = `\u2026 ${kids.more} more`;
          nodes.push(more);
        }
      }
    }
    if (!nodes.length) {
      const p = document.createElement('p');
      p.className = 'pane-msg';
      p.textContent = needle ? 'Nothing matches the filter.' : this.frame && !this.depth ? 'No variables in this frame.' : 'Environment is empty.';
      nodes.push(p);
    }
    this.list.replaceChildren(...nodes);
  }

  makeNameRow(name) {
    const el = document.createElement('div');
    el.className = 'env-row depth-0 expandable';
    el.title = 'Click to describe';
    const toggle = document.createElement('span');
    toggle.className = 'env-toggle';
    toggle.textContent = '\u25b8';
    const label = document.createElement('span');
    label.className = 'env-name';
    label.textContent = name;
    el.append(toggle, label);
    el.addEventListener('click', () => this.describe(name));
    return el;
  }

  async describe(name) {
    if (this.described.has(name)) {
      this.described.delete(name);
    } else {
      try {
        this.described.set(name, await this.query('env_describe', name, this.frame, this.depth));
      } catch (err) {
        this.showError(`Could not read from R: ${err.message}`);
        return;
      }
    }
    this.renderList();
  }

  makeRow(row, depth, onClick) {
    const el = document.createElement('div');
    el.className = `env-row depth-${depth}`;
    el.title = `${row.name}\nclass: ${row.class}\nlength/dim: ${row.dims}\nsize: ${row.size}`;

    const toggle = document.createElement('span');
    toggle.className = 'env-toggle';
    if (onClick) {
      const open = this.lite ? true : this.expanded.has(row.name);
      toggle.textContent = open ? '\u25be' : '\u25b8';
      el.classList.add('expandable');
      el.addEventListener('click', onClick);
    }
    el.append(toggle);

    const name = document.createElement('span');
    name.className = 'env-name';
    name.textContent = row.name;
    el.append(name);

    const value = document.createElement('span');
    value.className = 'env-value';
    value.textContent = row.preview;
    el.append(value);

    if (depth === 0 && row.viewable && this.depth === 0) {
      const view = document.createElement('button');
      view.className = 'env-view';
      view.title = `View(${row.name})`;
      view.textContent = '\u25a6';
      view.addEventListener('click', (e) => {
        e.stopPropagation();
        this.onView(row.name, this.frame);
      });
      el.append(view);
    }
    return el;
  }

  async toggle(name) {
    if (this.expanded.has(name)) this.expanded.delete(name);
    else this.expanded.add(name);
    try {
      await this.refresh();
    } catch (err) {
      this.showError(`Could not read from R: ${err.message}`);
    }
  }
}
