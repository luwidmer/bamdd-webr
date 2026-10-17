// Auto / Light / Dark. css/app.css resolves Auto on its own through light-dark(), so
// this module exists only for the override and for the two widgets that colour
// themselves in JavaScript rather than through CSS: CodeMirror and xterm.

const STORAGE_KEY = 'webr-theme';
const MODES = ['auto', 'light', 'dark'];

const darkQuery = window.matchMedia('(prefers-color-scheme: dark)');
const listeners = new Set();

const saved = localStorage.getItem(STORAGE_KEY);
let current = MODES.includes(saved) ? saved : 'auto';

/** The stored preference: 'auto', 'light' or 'dark'. */
export function mode() {
  return current;
}

/** What the page is actually showing: 'light' or 'dark'. */
export function resolved() {
  if (current !== 'auto') return current;
  return darkQuery.matches ? 'dark' : 'light';
}

export function setMode(next) {
  if (!MODES.includes(next)) throw new Error(`Unknown theme mode: ${next}`);
  current = next;
  localStorage.setItem(STORAGE_KEY, next);
  apply();
}

export function onChange(fn) {
  listeners.add(fn);
}

function apply() {
  // Auto leaves the attribute off so the CSS decides; the two overrides pin
  // color-scheme, which is what light-dark() and the UA widgets follow.
  if (current === 'auto') delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = current;

  const scheme = resolved();
  for (const fn of listeners) fn(scheme);
}

darkQuery.addEventListener('change', () => {
  if (current === 'auto') apply();
});

apply();
