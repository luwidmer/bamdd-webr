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
# rather than ".", which would prefix every entry with "./". pax because GNU tar's
# default format makes rwasm index "<pkg>/..." without the leading "/" WORKERFS strips.
res <- system2(
  "tar",
  c("--format=pax", "-czf", shQuote(image), "-C", shQuote(lib_dir), pkgs),
  stdout = TRUE, stderr = TRUE
)
if (!is.null(attr(res, "status")) && attr(res, "status") != 0) {
  die("tar failed:\n", paste(res, collapse = "\n"))
}
if (!file.exists(image)) die("tar produced no output at ", image)

say(sprintf("Archive: %.0f MB", file.size(image) / 1e6))
say("Appending webR filesystem index (this rereads and recompresses; be patient)")

rwasm::add_tar_index(image)

# Read the index back the way js/library.js does: a 16-byte trailer ("webR", reserved,
# block, length) at the end of the gzip stream points at the JSON.
data <- memDecompress(readBin(image, "raw", file.size(image)), "gzip")
trailer <- utils::tail(data, 16L)
if (length(trailer) < 16L || !identical(rawToChar(trailer[1:4]), "webR")) {
  die("Filesystem index trailer missing. add_tar_index() did not apply.")
}
int32 <- function(x) sum(as.integer(x) * 256^(3:0))
at <- 512 * int32(trailer[9:12])
indexed <- jsonlite::fromJSON(rawToChar(data[at + seq_len(int32(trailer[13:16]))]))$files$filename
rm(data)

expected <- unlist(lapply(pkgs, function(p) {
  paste0("/", p, "/", list.files(file.path(lib_dir, p), recursive = TRUE, all.files = TRUE))
}))
missing <- setdiff(expected, indexed)
if (length(missing)) {
  die(
    "The image index lacks ", length(missing), " of ", length(expected),
    " files, so webR would not see them. First few:\n  ",
    paste(utils::head(missing, 5), collapse = "\n  "),
    "\nIndexed as, e.g.: ", paste(utils::head(indexed, 3), collapse = ", ")
  )
}
say("Filesystem index verified:", length(expected), "files")

say(sprintf("Image: %s (%.0f MB)", image, file.size(image) / 1e6))
say("Mount it from R with: webr::mount('/library', '<origin>/lib/library.tar.gz')")
