import { isPhone } from './layout.js';

// Rows are a fixed height so the scroll position maps straight to a row index.
const ROW_H = 24;
const BLOCK = 200;
const COL_PAGE = 100;
const OVERSCAN = 20;

const TYPE_TITLES = {
  num: 'double', int: 'integer', chr: 'character', fct: 'factor', lgl: 'logical',
  date: 'Date', dttm: 'date-time', list: 'list', cplx: 'complex',
};

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

/**
 * RStudio-style data viewer. The data frame stays in R (see View() in r/webrapp.R);
 * rows arrive in blocks as they scroll into view, already sorted and filtered in R.
 */
export class DataGrid {
  constructor(id, { query, isBusy }) {
    this.id = id;
    this.query = query;
    this.isBusy = isBusy;
    this.element = el('div', 'dg');
    this.sort = null;
    this.desc = false;
    this.search = '';
    this.filters = {};
    this.colStart = 0;
    this.showFilters = !isPhone();
    this.resetData();
  }

  resetData() {
    this.generation = (this.generation ?? 0) + 1;
    this.blocks = new Map();
    this.loading = new Set();
    this.total = null;
    this.waiting = false;
  }

  /** Load the column layout. Resolves to the tab title. */
  async init() {
    this.meta = await this.query('view_meta', this.id);
    if (this.meta.kind === 'text') {
      this.element.replaceChildren(el('pre', 'dg-text', this.meta.text.join('\n')));
    } else {
      this.build();
    }
    return this.meta.title;
  }

  get pageColumns() {
    return this.meta.columns.slice(this.colStart, this.colStart + COL_PAGE);
  }

  build() {
    const bar = el('div', 'dg-bar');

    const search = el('input', 'pane-search');
    search.type = 'search';
    search.placeholder = 'Search all columns';
    search.value = this.search;
    search.addEventListener('input', this.debounce(() => {
      this.search = search.value;
      this.requery();
    }));

    const filterToggle = el('button', '', 'Filters');
    filterToggle.classList.toggle('active', this.showFilters);
    filterToggle.addEventListener('click', () => {
      this.showFilters = !this.showFilters;
      filterToggle.classList.toggle('active', this.showFilters);
      this.filterRow.hidden = !this.showFilters;
    });

    this.status = el('span', 'dg-status');
    bar.append(search, filterToggle);

    if (this.meta.ncol > COL_PAGE) {
      const prev = el('button', 'glyph', '‹');
      const next = el('button', 'glyph', '›');
      const label = el('span', 'dg-cols');
      const update = () => {
        const last = Math.min(this.colStart + COL_PAGE, this.meta.ncol);
        label.textContent = `columns ${this.colStart + 1}–${last} of ${this.meta.ncol}`;
        prev.disabled = this.colStart === 0;
        next.disabled = last >= this.meta.ncol;
      };
      prev.title = 'Previous columns';
      next.title = 'Next columns';
      prev.addEventListener('click', () => this.pageColumnsBy(-COL_PAGE, update));
      next.addEventListener('click', () => this.pageColumnsBy(COL_PAGE, update));
      update();
      bar.append(prev, label, next);
    }

    if (this.meta.refreshable) {
      const refresh = el('button', 'glyph', '⟳');
      refresh.title = 'Re-read the object from the global environment';
      refresh.addEventListener('click', () => this.reload());
      bar.append(refresh);
    }
    bar.append(this.status);

    this.scroller = el('div', 'dg-scroll');
    this.table = el('table', 'dg-table');
    this.thead = el('thead');
    this.tbody = el('tbody');
    this.table.append(this.thead, this.tbody);
    this.scroller.append(this.table);
    this.scroller.addEventListener('scroll', () => this.scheduleRender());
    new ResizeObserver(() => this.scheduleRender()).observe(this.scroller);

    this.element.replaceChildren(bar, this.scroller);
    this.buildHeader();
    this.render();
  }

  buildHeader() {
    const head = el('tr', 'dg-head');
    const filters = el('tr', 'dg-filter');
    head.append(el('th', 'dg-rn'));
    filters.append(el('th', 'dg-rn'));

    for (const col of this.pageColumns) {
      const th = el('th');
      th.style.width = `${Math.min(240, Math.max(80, col.name.length * 8 + 40))}px`;
      th.title = `${col.name} (${TYPE_TITLES[col.type] ?? col.type})${col.type === 'list' ? '' : ' — click to sort'}`;
      const name = el('span', 'dg-name', col.name);
      const type = el('span', 'dg-type', col.type);
      const arrow = el('span', 'dg-sort', this.sort === col.name ? (this.desc ? '▼' : '▲') : '');
      th.append(name, type, arrow);
      if (col.type !== 'list') th.addEventListener('click', () => this.cycleSort(col.name));
      head.append(th);

      const fth = el('th');
      const input = el('input', 'dg-filter-input');
      const numeric = ['num', 'int'].includes(col.type);
      input.placeholder = 'filter';
      input.title = numeric ? 'e.g. >1, <5, 2..5 or an exact value' : 'Contains (case-insensitive)';
      input.value = this.filters[col.name] ?? '';
      input.addEventListener('input', this.debounce(() => {
        this.filters[col.name] = input.value;
        this.requery();
      }));
      fth.append(input);
      filters.append(fth);
    }
    filters.hidden = !this.showFilters;
    this.filterRow = filters;
    this.thead.replaceChildren(head, filters);
  }

  cycleSort(name) {
    if (this.sort !== name) {
      this.sort = name;
      this.desc = false;
    } else if (!this.desc) {
      this.desc = true;
    } else {
      this.sort = null;
      this.desc = false;
    }
    this.buildHeader();
    this.requery();
  }

  pageColumnsBy(delta, update) {
    this.colStart = Math.max(0, this.colStart + delta);
    update();
    this.buildHeader();
    this.requery();
  }

  requery() {
    this.resetData();
    this.scroller.scrollTop = 0;
    this.render();
  }

  async reload() {
    if (this.isBusy()) {
      this.setStatus('R is busy; try again when it finishes.');
      return;
    }
    try {
      this.meta = await this.query('view_refresh', this.id);
    } catch (err) {
      this.setStatus(err.message, true);
      return;
    }
    this.colStart = Math.min(this.colStart, Math.max(0, this.meta.ncol - 1));
    const names = new Set(this.meta.columns.map((c) => c.name));
    if (this.sort && !names.has(this.sort)) this.sort = null;
    for (const key of Object.keys(this.filters)) if (!names.has(key)) delete this.filters[key];
    this.build();
    this.requery();
  }

  /** R went idle: fetch whatever was skipped while it was busy. */
  retry() {
    if (this.waiting) {
      this.waiting = false;
      this.render();
    }
  }

  setStatus(text, error = false) {
    this.status.textContent = text;
    this.status.classList.toggle('error', error);
  }

  scheduleRender() {
    if (this.frame) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = null;
      this.render();
    });
  }

  render() {
    if (!this.tbody) return;
    if (this.total === null) {
      this.tbody.replaceChildren();
      this.fetchBlock(0);
      return;
    }
    const headH = this.thead.offsetHeight;
    const first = Math.max(0, Math.floor((this.scroller.scrollTop - headH) / ROW_H) - OVERSCAN);
    const visible = Math.ceil(this.scroller.clientHeight / ROW_H) + 2 * OVERSCAN;
    const last = Math.min(this.total, first + visible);
    const ncol = this.pageColumns.length;

    const rows = [this.padRow(first * ROW_H, ncol)];
    for (let i = first; i < last; i++) {
      const b = Math.floor(i / BLOCK);
      const block = this.blocks.get(b);
      if (!block) this.fetchBlock(b);
      const tr = el('tr');
      tr.style.height = `${ROW_H}px`;
      const k = i - b * BLOCK;
      tr.append(el('td', 'dg-rn', block ? block.rownames[k] : ''));
      for (let j = 0; j < ncol; j++) {
        const value = block ? block.rows[k]?.[j] : '';
        const td = el('td');
        if (value === null) {
          td.className = 'na';
          td.textContent = 'NA';
        } else {
          td.textContent = value ?? '';
          if (value && value.length > 24) td.title = value;
        }
        tr.append(td);
      }
      rows.push(tr);
    }
    rows.push(this.padRow((this.total - last) * ROW_H, ncol));
    this.tbody.replaceChildren(...rows);
  }

  padRow(height, ncol) {
    const tr = el('tr', 'dg-pad');
    const td = el('td');
    td.colSpan = ncol + 1;
    td.style.height = `${height}px`;
    tr.append(td);
    return tr;
  }

  async fetchBlock(b) {
    const key = `${this.generation}:${b}`;
    if (this.loading.has(key)) return;
    if (this.isBusy()) {
      this.waiting = true;
      this.setStatus('R is busy; rows load when it finishes.');
      return;
    }
    this.loading.add(key);
    const generation = this.generation;
    let data;
    try {
      data = await this.query('view_rows', JSON.stringify({
        id: this.id,
        start: b * BLOCK,
        n: BLOCK,
        colStart: this.colStart,
        colN: COL_PAGE,
        sort: this.sort,
        desc: this.desc,
        search: this.search,
        filters: this.filters,
      }));
    } catch (err) {
      this.loading.delete(key);
      this.setStatus(err.message, true);
      return;
    }
    if (generation !== this.generation) return;
    this.blocks.set(b, data);
    this.total = data.total;
    const filtered = data.total !== this.meta.nrow;
    this.setStatus(`${data.total.toLocaleString()}${filtered ? ` of ${this.meta.nrow.toLocaleString()}` : ''} rows, ${this.meta.ncol} columns`);
    this.render();
  }

  debounce(fn, ms = 300) {
    let timer;
    return () => {
      clearTimeout(timer);
      timer = setTimeout(fn, ms);
    };
  }
}
