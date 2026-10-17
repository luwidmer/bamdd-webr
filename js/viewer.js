const FONT_STYLE = '<style>body{font-family:system-ui,-apple-system,sans-serif;margin:12px;}</style>';

function toBase64(bytes) {
  // Chunked: String.fromCharCode(...bytes) blows the stack on large assets.
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

/**
 * Read an HTML file out of the virtual filesystem and inline the assets it
 * references. The iframe is sandboxed with no filesystem access, so relative
 * <script src> and <link href> would otherwise 404.
 */
async function inlineAssets(webR, path) {
  const dir = path.split('/').slice(0, -1).join('/');
  let html = new TextDecoder('utf8').decode(await webR.FS.readFile(path));

  const readAsDataUrl = async (href, mime) => {
    const bytes = await webR.FS.readFile(`${dir}/${href}`);
    return `data:${mime};base64,${toBase64(bytes)}`;
  };

  const scripts = Array.from(html.matchAll(/<script[^>]*src=["'`]([^"'`]+\.js)["'`][^>]*>\s*<\/script>/g));
  for (const match of scripts) {
    try {
      const url = await readAsDataUrl(match[1], 'text/javascript');
      html = html.replace(match[0], `<script type="text/javascript" src="${url}"></script>`);
    } catch (err) {
      // Leave the tag alone rather than mangling the page, but say what is missing.
      console.warn(`Viewer: could not inline ${dir}/${match[1]}: ${err.message ?? err}`);
    }
  }

  let styled = false;
  const links = Array.from(html.matchAll(/<link[^>]*href=["'`]([^"'`]+\.css)["'`][^>]*>/g));
  for (const match of links) {
    try {
      const url = await readAsDataUrl(match[1], 'text/css');
      let tag = `<link rel="stylesheet" href="${url}"/>`;
      if (!styled) {
        tag = FONT_STYLE + tag;
        styled = true;
      }
      html = html.replace(match[0], tag);
    } catch (err) {
      console.warn(`Viewer: could not inline ${dir}/${match[1]}: ${err.message ?? err}`);
    }
  }

  return styled ? html : FONT_STYLE + html;
}

export class Viewer {
  constructor(host, { onShow }) {
    this.host = host;
    this.onShow = onShow;
    this.showPlaceholder('Nothing to view yet.');
  }

  showPlaceholder(text) {
    const p = document.createElement('p');
    p.className = 'viewer-empty';
    p.textContent = text;
    this.host.replaceChildren(p);
  }

  showHtml(html) {
    const frame = document.createElement('iframe');
    frame.className = 'viewer-frame';
    // Allow scripts (htmlwidgets need them) but keep it a unique opaque origin.
    frame.setAttribute('sandbox', 'allow-scripts');
    frame.srcdoc = html;
    this.host.replaceChildren(frame);
    this.onShow?.();
  }

  async showFile(webR, path) {
    this.showHtml(await inlineAssets(webR, path));
  }

  showText(title, text) {
    this.showHtml(
      `${FONT_STYLE}<h3>${escapeHtml(title)}</h3><pre style="white-space:pre-wrap">${escapeHtml(text)}</pre>`
    );
  }

  /** `view` messages carry columns as { name: { values: [...] } }. */
  showTable(title, data) {
    const cols = Object.keys(data);
    const nrow = cols.length ? (data[cols[0]].values?.length ?? 0) : 0;
    const head = cols.map((c) => `<th>${escapeHtml(c)}</th>`).join('');
    const rows = [];
    for (let i = 0; i < nrow; i++) {
      rows.push(`<tr>${cols.map((c) => `<td>${escapeHtml(data[c].values[i])}</td>`).join('')}</tr>`);
    }
    this.showHtml(
      `${FONT_STYLE}<style>
        table{border-collapse:collapse;font-size:13px}
        th,td{border:1px solid #ccc;padding:2px 8px;text-align:left}
        th{background:#eee;position:sticky;top:0}
      </style>
      <h3>${escapeHtml(title)}</h3>
      <table><thead><tr>${head}</tr></thead><tbody>${rows.join('')}</tbody></table>`
    );
  }
}
