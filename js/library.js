// The package library image, shared by the console's R and every background worker.
//
// webr::mount(url) would have each R download the image, gunzip it into its own
// ArrayBuffer and copy that into a Blob of its own: 280 MB per R, and with four
// workers Chrome's blob storage gives out (reads fail with NotReadableError). So
// the page fetches and unpacks the image once into a single Blob, and each R mounts
// that Blob through a blob: URL, which hands every worker a reference to the same
// data rather than a copy.

let shared = null;

async function unpack(url) {
  const res = await fetch(url);
  if (!res.ok) {
    const remote = new URL(url).origin !== location.origin;
    throw new Error(
      `Package library image not found (HTTP ${res.status}):\n  ${url}\n\n` +
      (remote
        ? 'The image is hosted off-origin; check the upload and its CORS/CORP headers.\n' +
          'See DEPLOY.md.'
        : 'Build it first:\n' +
          '    Rscript tools/build-library.R\n' +
          '    Rscript tools/pack-library.R')
    );
  }
  let blob = await res.blob();
  // A server that sends Content-Encoding: gzip has unpacked it already.
  const magic = new Uint8Array(await blob.slice(0, 2).arrayBuffer());
  if (magic[0] === 0x1f && magic[1] === 0x8b) {
    blob = await new Response(blob.stream().pipeThrough(new DecompressionStream('gzip'))).blob();
  }
  return { src: URL.createObjectURL(blob), size: blob.size };
}

/** The unpacked image as a blob: URL and size, fetched on first use and kept for the page's life. */
export function libraryBlob(url) {
  shared ??= unpack(url).catch((err) => {
    shared = null;
    throw err;
  });
  return shared;
}

/**
 * Mount the image at `mountpoint` in `webR`. Runs inside webR's own worker
 * (webr::eval_js without await), so it can read synchronously.
 *
 * Every R reads from the page's one Blob, through ranged requests on its blob:
 * URL: a worker cannot be handed the Blob itself (webR's own FS.mount copies it),
 * and fetching it whole copies it too. Emscripten's WORKERFS only ever calls
 * `slice()` on a file's contents and passes the result to its reader, so the
 * contents are offsets into the image and the reader fetches them, a megabyte
 * block at a time with a small cache, as R reads small pieces of the same files
 * over and over while loading packages. The index tools/pack-library.R appends is
 * located by the trailer webR itself looks for.
 */
export async function mountLibrary(webR, url, mountpoint) {
  const { src, size } = await libraryBlob(url);
  const js = `(() => {
    const SRC = ${JSON.stringify(src)};
    const SIZE = ${size};
    const BLOCK = 1 << 20;
    const KEEP = 64;
    const cache = new Map();
    const fetchBlock = (i) => {
      const start = i * BLOCK;
      const end = Math.min(SIZE, start + BLOCK);
      const xhr = new XMLHttpRequest();
      xhr.open('GET', SRC, false);
      xhr.responseType = 'arraybuffer';
      xhr.setRequestHeader('Range', 'bytes=' + start + '-' + (end - 1));
      xhr.send();
      const bytes = new Uint8Array(xhr.response);
      if (xhr.status !== 206 || bytes.length !== end - start) {
        throw new Error('reading the package library failed (HTTP ' + xhr.status + ')');
      }
      return bytes;
    };
    const block = (i) => {
      let bytes = cache.get(i);
      if (bytes) {
        cache.delete(i);
      } else {
        bytes = fetchBlock(i);
        if (cache.size >= KEEP) cache.delete(cache.keys().next().value);
      }
      cache.set(i, bytes);
      return bytes;
    };
    const read = (start, end) => {
      const out = new Uint8Array(end - start);
      for (let pos = start; pos < end;) {
        const i = Math.floor(pos / BLOCK);
        const bytes = block(i);
        const from = pos - i * BLOCK;
        const n = Math.min(bytes.length - from, end - pos);
        out.set(bytes.subarray(from, from + n), pos - start);
        pos += n;
      }
      return out.buffer;
    };
    class Range {
      constructor(start, end) { this.start = start; this.end = end; this.size = end - start; }
      slice(from = 0, to = this.size) {
        return new Range(this.start + from, this.start + Math.min(to, this.size));
      }
    }
    const tail = new DataView(read(SIZE - 16, SIZE));
    if (tail.getInt32(0) !== 2003133010) throw new Error('the library image has no webR filesystem index');
    const at = 512 * tail.getInt32(8);
    const metadata = JSON.parse(new TextDecoder().decode(read(at, at + tail.getInt32(12))));
    const FS = globalThis.Module.FS;
    const WORKERFS = FS.filesystems.WORKERFS;
    // The reader is shared with every other WORKERFS mount, webR's own R library
    // among them, so only Ranges are ours.
    const other = WORKERFS.reader ?? new FileReaderSync();
    WORKERFS.reader = {
      readAsArrayBuffer: (r) => (r instanceof Range ? read(r.start, r.end) : other.readAsArrayBuffer(r)),
    };
    FS.mkdirTree(${JSON.stringify(mountpoint)});
    FS._mount(WORKERFS, { packages: [{ blob: new Range(0, SIZE), metadata }] },
      ${JSON.stringify(mountpoint)});
    return metadata.files.length;
  })()`;
  await webR.evalRVoid(`invisible(webr::eval_js(${JSON.stringify(js)}))`);
}
