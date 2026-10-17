import { rString } from './session.js';

/**
 * Installed packages with an attach checkbox. Attaching, detaching and installing run
 * as visible console commands, as in RStudio, so the transcript shows what happened.
 */
export class PackagesPane {
  constructor(host, { query, run, onHelp }) {
    this.host = host;
    this.query = query;
    this.run = run;
    this.onHelp = onHelp;
    this.packages = null;
    this.attached = new Set();

    this.search = document.createElement('input');
    this.search.type = 'search';
    this.search.placeholder = 'Filter packages';
    this.search.className = 'pane-search';
    this.search.addEventListener('input', () => this.render());

    this.list = document.createElement('div');
    this.list.className = 'pkg-list';
    this.host.replaceChildren(this.search, this.list);
  }

  get loaded() {
    return this.packages !== null;
  }

  async refresh() {
    const { packages, libs, attached } = await this.query('packages_list');
    this.libs = libs;
    this.packages = packages;
    this.attached = new Set(attached);
    this.render();
  }

  async refreshAttached() {
    if (!this.loaded) return;
    this.attached = new Set(await this.query('packages_attached'));
    for (const box of this.list.querySelectorAll('input[type="checkbox"]')) {
      box.checked = this.attached.has(box.dataset.pkg);
    }
  }

  install() {
    const name = prompt('Install package (from repo.r-wasm.org)');
    if (!name?.trim()) return;
    this.run(`install.packages(${rString(name.trim())})`);
    this.packages = null;
  }

  libLabel(lib) {
    const i = this.libs.indexOf(lib);
    return ['user', 'image'][i] ?? 'base';
  }

  showError(message) {
    const p = document.createElement('p');
    p.className = 'pane-msg error';
    p.textContent = message;
    this.list.replaceChildren(p);
  }

  render() {
    if (!this.packages) return;
    const needle = this.search.value.trim().toLowerCase();
    const rows = this.packages
      .filter((p) => !needle || p.name.toLowerCase().includes(needle) || p.title.toLowerCase().includes(needle))
      .sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }));

    const frag = document.createDocumentFragment();
    for (const pkg of rows) {
      const row = document.createElement('div');
      row.className = 'pkg-row';
      row.title = pkg.title;

      const box = document.createElement('input');
      box.type = 'checkbox';
      box.dataset.pkg = pkg.name;
      box.checked = this.attached.has(pkg.name);
      box.title = box.checked ? `detach("package:${pkg.name}")` : `library(${pkg.name})`;
      box.addEventListener('change', () => {
        this.run(box.checked
          ? `library(${pkg.name})`
          : `detach("package:${pkg.name}", unload = FALSE, character.only = TRUE)`);
      });

      const name = document.createElement('button');
      name.className = 'pkg-name';
      name.textContent = pkg.name;
      name.title = `Help index for ${pkg.name}`;
      name.addEventListener('click', () => this.onHelp(pkg.name));

      const title = document.createElement('span');
      title.className = 'pkg-title';
      title.textContent = pkg.title;

      const version = document.createElement('span');
      version.className = 'pkg-version';
      version.textContent = pkg.version;

      const lib = document.createElement('span');
      lib.className = 'pkg-lib';
      lib.textContent = this.libLabel(pkg.lib);

      row.append(box, name, title, version, lib);
      frag.append(row);
    }
    this.list.replaceChildren(frag);
  }
}
