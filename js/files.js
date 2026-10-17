// webR 0.6.0's R.wasm is built with LLVM profiling and drops this into its working dir.
const HIDDEN = new Set(['default.profraw']);

/** The file's text, or null when it is binary: any NUL byte, or not valid UTF-8. */
function decodeText(bytes) {
  if (bytes.includes(0)) return null;
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}

export class FileTree {
  constructor(host, session, { onOpenFile }) {
    this.host = host;
    this.session = session;
    this.onOpenFile = onOpenFile;
    this.expanded = new Set([session.homedir]);
    this.selected = null;
  }

  async refresh() {
    const root = await this.renderDir(this.session.homedir, 0);
    const scroll = this.host.scrollTop;
    this.host.replaceChildren(root);
    this.host.scrollTop = scroll;
  }

  async renderDir(path, depth) {
    const wrapper = document.createElement('div');
    wrapper.className = 'fs-dir';

    const node = this.makeNode({
      name: depth === 0 ? path : path.split('/').pop(),
      isDir: true,
      expanded: this.expanded.has(path),
    });
    node.addEventListener('click', async () => {
      if (this.expanded.has(path)) this.expanded.delete(path);
      else this.expanded.add(path);
      await this.refresh();
    });
    wrapper.append(node);

    if (!this.expanded.has(path)) return wrapper;

    const children = document.createElement('div');
    children.className = 'fs-children';
    let entries;
    try {
      entries = (await this.session.listDir(path)).filter((e) => !HIDDEN.has(e.name));
    } catch (err) {
      const e = document.createElement('div');
      e.className = 'fs-empty';
      e.textContent = `unreadable: ${err.message}`;
      children.append(e);
      wrapper.append(children);
      return wrapper;
    }

    if (!entries.length) {
      const empty = document.createElement('div');
      empty.className = 'fs-empty';
      empty.textContent = 'empty';
      children.append(empty);
    }

    for (const entry of entries) {
      if (entry.isDir) {
        children.append(await this.renderDir(entry.path, depth + 1));
      } else {
        const fileNode = this.makeNode({ name: entry.name, isDir: false, size: entry.size });
        if (this.selected === entry.path) fileNode.classList.add('active');
        fileNode.addEventListener('click', async () => {
          this.selected = entry.path;
          this.onOpenFile(entry.path, decodeText(await this.session.readBytes(entry.path)));
          this.refresh();
        });
        children.append(fileNode);
      }
    }

    wrapper.append(children);
    return wrapper;
  }

  makeNode({ name, isDir, expanded, size }) {
    const node = document.createElement('div');
    node.className = 'fs-node';

    const icon = document.createElement('span');
    icon.className = 'icon';
    icon.textContent = isDir ? (expanded ? '▾' : '▸') : '·';
    node.append(icon);

    const label = document.createElement('span');
    label.textContent = name;
    node.append(label);

    if (!isDir && size) {
      const s = document.createElement('span');
      s.className = 'size';
      s.textContent = size > 1024 ? `${Math.round(size / 1024)}K` : `${size}B`;
      node.append(s);
    }
    return node;
  }
}
