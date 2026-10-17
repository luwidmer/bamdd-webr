export class Plots {
  constructor(stage, { onCountChange, onRerender }) {
    this.stage = stage;
    this.onCountChange = onCountChange;
    // (page, width, height) -> Promise<ImageBitmap|null>, null when R cannot re-render.
    this.onRerender = onRerender;
    this.pages = [];
    this.index = -1;
    this.pendingNewPage = true;
    // Pages whose bitmap was drawn for a device size that is no longer current.
    this.stale = new Set();
    this.popouts = new Map();
    this.renderEmpty();
  }

  renderEmpty() {
    this.stage.replaceChildren();
    const p = document.createElement('p');
    p.className = 'plot-empty';
    p.textContent = 'No plots yet.';
    this.stage.append(p);
  }

  newPage() {
    // canvasNewPage carries no dimensions, so defer creating the canvas until the
    // first image arrives and we can size it from the bitmap.
    this.pendingNewPage = true;
  }

  addImage(bitmap) {
    if (this.pendingNewPage || !this.pages.length) {
      const canvas = document.createElement('canvas');
      canvas.width = bitmap.width;
      canvas.height = bitmap.height;
      this.pages.push(canvas);
      this.index = this.pages.length - 1;
      this.pendingNewPage = false;
    }
    const canvas = this.pages[this.index];
    canvas.getContext('2d').drawImage(bitmap, 0, 0);
    this.stale.delete(this.index);
    this.show(this.index);
    this.onCountChange?.(this.pages.length, this.index);
  }

  /**
   * Page numbers in R's plot history are 1-based and line up with these indices:
   * both count canvas pages from the same starting point and clear() resets both.
   */
  pageNumber(index = this.index) {
    return index + 1;
  }

  markAllStale() {
    for (let i = 0; i < this.pages.length; i++) this.stale.add(i);
  }

  isStale(index) {
    return this.stale.has(index);
  }

  /** Swap in a bitmap re-rendered at the current device size. */
  replacePage(index, bitmap) {
    const canvas = this.pages[index];
    if (!canvas) return;
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
    canvas.getContext('2d').drawImage(bitmap, 0, 0);
    this.stale.delete(index);
  }

  /** Give up on re-rendering a page: its old bitmap stays on screen, rescaled. */
  markFresh(index) {
    this.stale.delete(index);
  }

  show(index) {
    if (index < 0 || index >= this.pages.length) return;
    this.index = index;
    this.stage.replaceChildren(this.pages[index]);
    this.onCountChange?.(this.pages.length, this.index);
  }

  prev() {
    this.show(this.index - 1);
  }

  next() {
    this.show(this.index + 1);
  }

  get count() {
    return this.pages.length;
  }

  savePNG() {
    const canvas = this.pages[this.index];
    if (!canvas) return;
    canvas.toBlob((blob) => {
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `plot-${this.index + 1}.png`;
      a.click();
      URL.revokeObjectURL(url);
    }, 'image/png');
  }

  clear() {
    this.pages = [];
    this.index = -1;
    this.pendingNewPage = true;
    this.stale.clear();
    this.renderEmpty();
    this.onCountChange?.(0, -1);
  }

  /**
   * Show the current page in its own browser window, re-rendered from R's plot
   * history whenever that window is resized. One window per page, reused if it is
   * still open.
   */
  popOut() {
    const index = this.index;
    const source = this.pages[index];
    if (!source) return;
    const page = this.pageNumber(index);

    const open = this.popouts.get(page);
    if (open && !open.closed) {
      open.focus();
      return;
    }

    const width = Math.max(320, Math.round(source.width / 2));
    const height = Math.max(240, Math.round(source.height / 2));
    const win = window.open('', `webr-plot-${page}`, `popup=yes,width=${width},height=${height}`);
    if (!win) {
      throw new Error('The browser blocked the plot window. Allow pop-ups for this page and try again.');
    }

    win.document.open();
    win.document.write(
      `<!DOCTYPE html><title>Plot ${page}</title>` +
      '<body style="margin:0;display:grid;place-items:center;background:#fff;height:100vh;overflow:hidden">' +
      '<canvas id="plot" style="max-width:100%;max-height:100%"></canvas>'
    );
    win.document.close();

    const target = win.document.getElementById('plot');
    // Some embedded browsers hand back a window they never render, so writing the
    // document silently does nothing; say so rather than leave a blank window around.
    if (!target) {
      throw new Error('The plot window could not be opened. This browser may not support separate windows.');
    }
    this.popouts.set(page, win);

    const draw = (image) => {
      target.width = image.width;
      target.height = image.height;
      target.getContext('2d').drawImage(image, 0, 0);
    };
    // Show the bitmap we already have, then replace it with one drawn for this window.
    draw(source);

    let pending = false;
    const rerender = async () => {
      if (pending || win.closed) return;
      pending = true;
      try {
        const image = await this.onRerender?.(page, win.innerWidth, win.innerHeight);
        if (image && !win.closed) draw(image);
      } finally {
        pending = false;
      }
    };

    let timer;
    win.addEventListener('resize', () => {
      win.clearTimeout(timer);
      timer = win.setTimeout(rerender, 250);
    });
    win.addEventListener('pagehide', () => this.popouts.delete(page));
    rerender();
  }
}
