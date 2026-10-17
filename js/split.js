/**
 * Drag-to-resize for the grid gutters. Sizes live in CSS custom properties on #app so
 * the grid stays the single source of truth for layout.
 */
function drag(splitter, onMove) {
  splitter.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    splitter.setPointerCapture(e.pointerId);
    splitter.classList.add('dragging');

    const move = (ev) => onMove(ev);
    const up = (ev) => {
      splitter.releasePointerCapture(ev.pointerId);
      splitter.classList.remove('dragging');
      splitter.removeEventListener('pointermove', move);
      splitter.removeEventListener('pointerup', up);
    };
    splitter.addEventListener('pointermove', move);
    splitter.addEventListener('pointerup', up);
  });
}

const clamp = (value, min, max) => Math.min(Math.max(value, min), max);

export function installSplitters(app, { onResize } = {}) {
  const notify = () => onResize?.();
  const $ = (id) => document.getElementById(id);

  drag($('split-cols'), (e) => {
    const width = clamp(e.clientX - app.getBoundingClientRect().left, 240, window.innerWidth - 280);
    app.style.setProperty('--left-w', `${width}px`);
    notify();
  });

  for (const [splitter, column, variable] of [
    ['split-left', 'col-left', '--left-top-h'],
    ['split-right', 'col-right', '--right-top-h'],
  ]) {
    drag($(splitter), (e) => {
      const box = $(column).getBoundingClientRect();
      const height = clamp(e.clientY - box.top, 80, box.height - 80);
      app.style.setProperty(variable, `${height}px`);
      notify();
    });
  }
}
