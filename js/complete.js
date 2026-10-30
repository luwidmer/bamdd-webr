// The completion list shared by the console and the editor. Candidates come from R's
// own completion engine (complete_line() in r/webrapp.R); this module only shows them
// and reports a pick.

const MAX_ITEMS = 200;

/** What a candidate inserts: R returns arguments as "name=", RStudio writes "name = ". */
export function insertion(candidate) {
  return /^[^=]+=$/.test(candidate) ? `${candidate.slice(0, -1)} = ` : candidate;
}

/** What the list shows: the part after the last `$`, `@` or `::`, as the rest is typed. */
function label(candidate) {
  const m = /^(?:.*(?:\$|@|:::?))?(.+)$/.exec(candidate);
  return m ? m[1] : candidate;
}

export function commonPrefix(strings) {
  if (!strings.length) return '';
  let prefix = strings[0];
  for (const s of strings) {
    let i = 0;
    while (i < prefix.length && i < s.length && prefix[i] === s[i]) i++;
    prefix = prefix.slice(0, i);
  }
  return prefix;
}

/**
 * R counts characters in code points, JavaScript strings in UTF-16 units; convert so an
 * emoji or other astral character in the line does not shift the completed range.
 */
export function toCodePoints(text, index) {
  return [...text.slice(0, index)].length;
}

export function fromCodePoints(text, points) {
  return [...text].slice(0, points).join('').length;
}

/**
 * Ask R for completions of `line` at `cursor` (UTF-16 offsets). Resolves to
 * { start, candidates } with `start` as a UTF-16 offset, or null when R gave nothing.
 */
export async function requestCompletions(query, line, cursor) {
  const res = await query('complete_line', line, toCodePoints(line, cursor));
  const candidates = res?.candidates ?? [];
  if (!candidates.length) return null;
  const start = Math.min(fromCodePoints(line, res.start), cursor);
  return { start, candidates };
}

export class CompletionPopup {
  /** `onPick(candidate)` runs when a row is clicked or tapped. */
  constructor({ onPick }) {
    this.onPick = onPick;
    this.items = [];
    this.index = 0;
    this.el = document.createElement('div');
    this.el.className = 'completion-popup';
    this.el.setAttribute('role', 'listbox');
    this.el.hidden = true;
    // Keep focus, and with it the phone keyboard, where it is.
    this.el.addEventListener('mousedown', (e) => e.preventDefault());
    this.el.addEventListener('click', (e) => {
      const row = e.target.closest('.completion-item');
      if (row) this.onPick(this.items[Number(row.dataset.index)]);
    });
    document.body.append(this.el);
  }

  get isOpen() {
    return !this.el.hidden;
  }

  get selected() {
    return this.items[this.index];
  }

  /**
   * Show the list next to an anchor in viewport coordinates: { left, top, bottom } of
   * the text the completion replaces. Below it if there is room, otherwise above.
   */
  show(anchor) {
    if (!this.items.length) return;
    this.el.hidden = false;
    this.position(anchor);
    this.highlight();
  }

  /** Replace the candidates, keeping the list shown or hidden as it was. */
  setItems(items) {
    this.items = items.slice(0, MAX_ITEMS);
    this.index = 0;
    this.el.replaceChildren(...this.items.map((item, i) => {
      const row = document.createElement('div');
      row.className = 'completion-item';
      if (/=$/.test(item)) row.classList.add('arg');
      row.dataset.index = i;
      row.setAttribute('role', 'option');
      row.textContent = label(item);
      row.title = item;
      return row;
    }));
    if (!this.items.length) this.close();
    else this.highlight();
  }

  position({ left, top, bottom }) {
    const el = this.el;
    el.style.left = '0px';
    el.style.top = '0px';
    const { width, height } = el.getBoundingClientRect();
    // On a phone the keyboard covers the bottom of the layout viewport.
    const vv = window.visualViewport;
    const viewTop = vv ? vv.offsetTop : 0;
    const viewBottom = vv ? vv.offsetTop + vv.height : window.innerHeight;
    const viewRight = vv ? vv.offsetLeft + vv.width : window.innerWidth;
    const below = bottom + height <= viewBottom || top - height < viewTop;
    el.style.top = `${below ? bottom : top - height}px`;
    el.style.left = `${Math.max(0, Math.min(left, viewRight - width))}px`;
  }

  move(delta) {
    if (!this.items.length) return;
    this.index = (this.index + delta + this.items.length) % this.items.length;
    this.highlight();
  }

  highlight() {
    for (const row of this.el.children) {
      const on = Number(row.dataset.index) === this.index;
      row.classList.toggle('selected', on);
      row.setAttribute('aria-selected', on);
      if (!on) continue;
      // By hand: scrollIntoView() would also scroll the page under the fixed list.
      const el = this.el;
      if (row.offsetTop < el.scrollTop) el.scrollTop = row.offsetTop;
      else if (row.offsetTop + row.offsetHeight > el.scrollTop + el.clientHeight) {
        el.scrollTop = row.offsetTop + row.offsetHeight - el.clientHeight;
      }
    }
  }

  close() {
    this.el.hidden = true;
    this.items = [];
  }
}
