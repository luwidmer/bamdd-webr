// Whether css/app.css is showing the phone layout, and on a phone, which pane.
// The query must match the phone media query there.

const phoneQuery = window.matchMedia('(max-width: 767.98px), (max-height: 499.98px)');

const app = document.getElementById('app');
const nav = document.getElementById('mobile-nav');
const layoutListeners = new Set();
const paneListeners = new Set();

/** 'phone' or 'desktop'. */
export function mode() {
  return phoneQuery.matches ? 'phone' : 'desktop';
}

export function isPhone() {
  return phoneQuery.matches;
}

/** The pane shown on a phone: 'editor', 'console', 'side' or 'output'. */
export function currentPane() {
  return app.dataset.pane;
}

/** Whether a pane is on screen, which on larger layouts is always. */
export function isVisible(pane) {
  return !isPhone() || currentPane() === pane;
}

export function showPane(pane) {
  app.dataset.pane = pane;
  for (const button of nav.querySelectorAll('button')) {
    button.classList.toggle('active', button.dataset.pane === pane);
    if (button.dataset.pane === pane) button.classList.remove('badge');
  }
  for (const fn of paneListeners) fn(pane);
}

/** Flag a pane that has something new, without switching to it. */
export function badge(pane) {
  if (isVisible(pane)) return;
  nav.querySelector(`button[data-pane="${pane}"]`)?.classList.add('badge');
}

export function onLayoutChange(fn) {
  layoutListeners.add(fn);
}

export function onPaneChange(fn) {
  paneListeners.add(fn);
}

for (const button of nav.querySelectorAll('button')) {
  button.addEventListener('click', () => showPane(button.dataset.pane));
}

const notifyLayout = () => {
  for (const fn of layoutListeners) fn(mode());
};
phoneQuery.addEventListener('change', notifyLayout);

// iOS Safari overlays the on-screen keyboard instead of resizing the layout viewport,
// so 100dvh would leave the console prompt underneath it.
if (window.visualViewport) {
  const fitViewport = () => {
    if (isPhone()) app.style.setProperty('--app-h', `${window.visualViewport.height}px`);
    else app.style.removeProperty('--app-h');
  };
  window.visualViewport.addEventListener('resize', fitViewport);
  phoneQuery.addEventListener('change', fitViewport);
  fitViewport();
}

showPane(currentPane() || 'editor');
