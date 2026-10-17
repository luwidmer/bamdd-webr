#!/usr/bin/env Rscript
#
# Pack build/library into the VFS filesystem image the browser mounts at /library.
#
#   Rscript tools/pack-library.R
#
# Produces lib/library.tar.gz with webR filesystem metadata appended by
# rwasm::add_tar_index(). This is pure R -- no Emscripten or Docker toolchain is
# needed, because we are only repackaging already-built wasm binaries.

options(warn = 1)

die <- function(...) stop("\n[pack-library] ", ..., call. = FALSE)
say <- function(...) cat("[pack-library]", ..., "\n", sep = " ")

if (!requireNamespace("rwasm", quietly = TRUE)) {
  die(
    "The 'rwasm' package is required to append filesystem metadata.\n",
    "  remotes::install_github('r-wasm/rwasm')\n",
    "Only add_tar_index() is used, which is pure R; no Emscripten toolchain needed."
  )
}

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
root <- if (length(script_arg) == 1L) {
  dirname(dirname(normalizePath(sub("^--file=", "", script_arg))))
} else {
  normalizePath(getwd())
}

lib_dir <- file.path(root, "build", "library")
out_dir <- file.path(root, "lib")
image <- file.path(out_dir, "library.tar.gz")

if (!dir.exists(lib_dir)) {
  die("No build/library found. Run:  Rscript tools/build-library.R")
}

pkgs <- list.dirs(lib_dir, recursive = FALSE, full.names = FALSE)
if (!length(pkgs)) die("build/library is empty.")

missing <- setdiff(c("stanli", "stanliWebR", "miraiWebR", "rstan", "brms", "RBesT"), pkgs)
if (length(missing)) {
  die("build/library is missing target package(s): ", paste(missing, collapse = ", "))
}

# RBesT calls rstan::sampling(), so the pure-R shim this project used to ship is
# no longer sufficient; catch a stale build/library rather than shipping an image
# in which gMAP() cannot run.
rstan_title <- read.dcf(file.path(lib_dir, "rstan", "DESCRIPTION"), fields = "Title")[1, 1]
if (isTRUE(grepl("SHIM", rstan_title, fixed = TRUE))) {
  die(
    "build/library/rstan is the pure-R shim, which has no Stan engine.\n",
    "Rebuild the library so the cross-compiled rstan is installed:\n",
    "  Rscript tools/build-library.R"
  )
}

# Headers and static archives exist for LinkingTo, and nothing compiles in the
# browser. "libs" (the .so files) is emphatically not in this list; neither are
# help/html, which keep ?topic working in the terminal.
STRIP_DIRS <- c("include", "lib")
stripped <- 0
for (pkg in pkgs) {
  for (sub in STRIP_DIRS) {
    path <- file.path(lib_dir, pkg, sub)
    if (dir.exists(path)) {
      stripped <- stripped +
        sum(file.info(list.files(path, recursive = TRUE, full.names = TRUE))$size, na.rm = TRUE)
      unlink(path, recursive = TRUE)
    }
  }
}
if (stripped > 0) say(sprintf("Stripped %s: %.0f MB", paste(STRIP_DIRS, collapse = "/"), stripped / 1e6))

# rstan:::.onLoad() sources this with mustWork = TRUE; it sits beside the stripped
# directories rather than inside them, so a change to STRIP_DIRS must not take it.
stanc <- file.path(lib_dir, "StanHeaders", "stanc.js")
if (!file.exists(stanc)) die("StanHeaders/stanc.js is gone; rstan will fail to load.")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
unlink(image)

say("Packing", length(pkgs), "packages")

# Tar entries must be package directories at the archive root, so that mounting the
# image at /library yields /library/<pkg>. Hence -C build/library with explicit names
# rather than ".", which would prefix every entry with "./".
res <- system2(
  "tar",
  c("-czf", shQuote(image), "-C", shQuote(lib_dir), pkgs),
  stdout = TRUE, stderr = TRUE
)
if (!is.null(attr(res, "status")) && attr(res, "status") != 0) {
  die("tar failed:\n", paste(res, collapse = "\n"))
}
if (!file.exists(image)) die("tar produced no output at ", image)

say(sprintf("Archive: %.0f MB", file.size(image) / 1e6))
say("Appending webR filesystem index (this rereads and recompresses; be patient)")

rwasm::add_tar_index(image)

# add_tar_index appends a JSON block plus a 16-byte trailer starting with the magic
# "webR", then gzips the whole thing -- so the trailer lives INSIDE the gzip stream.
# Stream-decompress and keep only the tail rather than holding ~230 MB in memory.
con <- gzfile(image, open = "rb")
on.exit(close(con), add = TRUE)
tail_bytes <- raw(0)
repeat {
  chunk <- readBin(con, "raw", n = 1048576L)
  if (!length(chunk)) break
  tail_bytes <- utils::tail(c(tail_bytes, chunk), 16L)
}
close(con)
on.exit()

if (length(tail_bytes) < 16L) die("Image is implausibly small after indexing.")
magic <- rawToChar(tail_bytes[1:4])
if (!identical(magic, "webR")) {
  die("Filesystem index trailer missing (found '", magic, "'). add_tar_index() did not apply.")
}
say("Filesystem index verified (webR trailer present)")

say(sprintf("Image: %s (%.0f MB)", image, file.size(image) / 1e6))
say("Mount it from R with: webr::mount('/library', '<origin>/lib/library.tar.gz')")
