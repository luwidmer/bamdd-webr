# Helpers behind the Environment, Packages, data viewer and Help panes, and completion.
#
# js/session.js sources this into an environment attached as "tools:webrapp", the same
# trick RStudio uses, so rm(list = ls()) in the user's session cannot remove it. The
# page calls these only while R is idle, through as.environment("tools:webrapp").
# Results go back as JSON strings.

json <- function(x) {
  as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", na = "null", digits = NA))
}

clip <- function(s, n = 120L) {
  s <- paste(s, collapse = " ")
  if (nchar(s) > n) paste0(substr(s, 1L, n - 1L), "\u2026") else s
}

# ---------------------------------------------------------------- environment

# str()'s first line is what RStudio shows as the value, e.g. "num [1:3] 1 2 3".
preview <- function(x) {
  if (is.data.frame(x)) {
    return(sprintf("%d obs. of %d variable%s", nrow(x), ncol(x), if (ncol(x) == 1L) "" else "s"))
  }
  if (is.environment(x)) return(format(x))
  line <- utils::capture.output(
    utils::str(x, max.level = 0L, give.attr = FALSE, vec.len = 3L, nchar.max = 80L)
  )
  clip(trimws(line[1L]))
}

describe <- function(name, x) {
  d <- dim(x)
  list(
    name = name,
    class = paste(class(x), collapse = ", "),
    dims = if (is.null(d)) as.character(length(x)) else paste(d, collapse = " \u00d7 "),
    size = format(utils::object.size(x), units = "auto", standard = "SI"),
    preview = preview(x),
    expandable = is.list(x) && !is.data.frame(x) && length(x) > 0L ||
      is.data.frame(x) && ncol(x) > 0L,
    viewable = is.data.frame(x) || is.matrix(x)
  )
}

# One broken object (a failing str() method, say) must not blank the whole pane, so it
# gets a row of its own that says what went wrong.
describe_safely <- function(name, get_value) {
  tryCatch(describe(name, get_value()), error = function(e) {
    list(name = name, class = "?", dims = "", size = "",
         preview = paste("<error:", conditionMessage(e), ">"),
         expandable = FALSE, viewable = FALSE)
  })
}

# Package and namespace environments hold hundreds to thousands of lazily loaded
# objects; describing each would load them all, so those list names only.
env_summary <- function(frame = 0L, depth = 0L) {
  env <- target_env(frame, depth)
  names <- sort(ls(env))
  if (env_kind(env) %in% c("package", "namespace")) return(json(list(lite = TRUE, names = I(names))))
  rows <- lapply(names, function(n) {
    # Reading an active binding runs arbitrary code; RStudio does not either.
    if (bindingIsActive(n, env)) {
      return(list(name = n, class = "active binding", dims = "", size = "",
                  preview = "<active binding>", expandable = FALSE, viewable = FALSE))
    }
    describe_safely(n, function() get(n, envir = env, inherits = FALSE))
  })
  json(list(lite = FALSE, rows = rows))
}

env_describe <- function(name, frame = 0L, depth = 0L) {
  env <- target_env(frame, depth)
  json(describe_safely(name, function() get(name, envir = env, inherits = FALSE)))
}

env_children <- function(name, frame = 0L, depth = 0L, limit = 200L) {
  x <- get(name, envir = target_env(frame, depth), inherits = FALSE)
  n <- min(length(x), limit)
  labels <- names(x)
  if (is.null(labels)) labels <- rep("", length(x))
  rows <- lapply(seq_len(n), function(i) {
    label <- if (nzchar(labels[i])) labels[i] else sprintf("[[%d]]", i)
    describe_safely(label, function() x[[i]])
  })
  json(list(rows = rows, more = length(x) - n))
}

# ---------------------------------------------------------------- debugging

# At a Browse[n]> prompt the page's queries run nested inside the code being debugged,
# below webR's own evaluator: the user's frames are those before the first webr one.
user_frames <- function() {
  k <- 0L
  for (i in seq_len(sys.nframe())) {
    env <- environment(sys.function(i))
    if (!is.null(env) && identical(environmentName(topenv(env)), "webr")) break
    k <- i
  }
  k
}

# An environment is addressed as a frame (0 = global) plus a number of parent.env()
# steps, so nothing has to be remembered between queries.
target_env <- function(frame, depth = 0L) {
  frame <- as.integer(frame)
  env <- if (frame < 1L) {
    globalenv()
  } else {
    if (frame > user_frames()) stop("That frame is no longer on the call stack.")
    sys.frame(frame)
  }
  for (i in seq_len(as.integer(depth))) {
    if (identical(env, emptyenv())) stop("No such environment.")
    env <- parent.env(env)
  }
  env
}

env_kind <- function(env) {
  if (identical(env, globalenv())) return("global")
  if (identical(env, baseenv())) return("package")
  if (isNamespace(env)) return("namespace")
  name <- attr(env, "name")
  if (is.null(name)) return("other")
  if (startsWith(name, "imports:")) return("namespace")
  "package"
}

env_label <- function(env) {
  if (identical(env, globalenv())) return("Global Environment")
  if (identical(env, baseenv())) return("package:base")
  if (isNamespace(env)) return(paste0("namespace:", getNamespaceName(env)))
  attr(env, "name") %||% "<environment>"
}

# The selector's entries: the frame (or global) and every enclosing environment.
env_chain <- function(frame = 0L) {
  frame <- as.integer(frame)
  env <- target_env(frame)
  out <- list()
  depth <- 0L
  while (!identical(env, emptyenv())) {
    own <- depth == 0L && frame > 0L
    out[[length(out) + 1L]] <- list(
      depth = depth,
      label = if (own) call_label(sys.call(frame)) else env_label(env),
      kind = if (own) "frame" else env_kind(env)
    )
    env <- parent.env(env)
    depth <- depth + 1L
  }
  json(out)
}

call_label <- function(call) clip(deparse(call, nlines = 1L, width.cutoff = 80L)[1L], 80L)

src_position <- function(ref) {
  if (is.null(ref)) return(list(file = "", line = NA_integer_))
  file <- utils::getSrcFilename(ref, full.names = TRUE)
  list(file = if (length(file) && nzchar(file)) file else "", line = ref[[1L]])
}

# Each frame with the line it is at: where it called the next frame. The innermost
# frame's position is not available here; the page knows it from "debug at".
debug_stack <- function() {
  k <- user_frames()
  json(lapply(seq_len(k), function(i) {
    pos <- if (i < k) src_position(attr(sys.call(i + 1L), "srcref")) else src_position(NULL)
    c(list(frame = i, call = call_label(sys.call(i))), pos)
  }))
}

# The call stack of the last uncaught errors, kept by id so each "Show traceback" link
# in the console shows its own error.
traces <- new.env(parent = emptyenv())
traces$n <- 0L

# options(error = ) runs before the stack unwinds, which is what makes the calls and
# their source positions still available here. Deepest call first, as traceback().
on_error <- function() {
  calls <- sys.calls()
  calls <- calls[-length(calls)]
  rows <- lapply(rev(seq_along(calls)), function(i) {
    c(list(call = call_label(calls[[i]])), src_position(attr(calls[[i]], "srcref")))
  })
  traces$n <- traces$n + 1L
  id <- paste0("e", traces$n)
  traces[[id]] <- list(message = trimws(geterrmessage()), rows = rows)
  stale <- setdiff(ls(traces), c("n", paste0("e", seq(max(1L, traces$n - 19L), traces$n))))
  rm(list = stale, envir = traces)
  utils::View(list(webrapp_error = id), "error")
}

traceback_rows <- function(id) {
  trace <- traces[[id]]
  if (is.null(trace)) stop("This traceback is no longer kept.")
  json(trace)
}

# Rerun with debug: recover() at the error lets the user pick a frame to browse.
rerun_with_debug <- function(expr) {
  op <- options(error = utils::recover)
  on.exit(options(op))
  eval(substitute(expr), globalenv())
}

# ---------------------------------------------------------------- packages

packages_list <- function() {
  ip <- utils::installed.packages(fields = "Title")
  libs <- .libPaths()
  json(list(
    packages = data.frame(
      name = ip[, "Package"],
      version = ip[, "Version"],
      lib = ip[, "LibPath"],
      title = ifelse(is.na(ip[, "Title"]), "", gsub("\\s+", " ", ip[, "Title"])),
      row.names = NULL
    ),
    libs = libs,
    attached = I(.packages())
  ))
}

packages_attached <- function() json(I(.packages()))

# ---------------------------------------------------------------- completion

# Package names inside library() and require(), as in RStudio.
utils::rc.settings(ipck = TRUE)

# Tab completion for the console and the editor, from the engine behind R's own
# readline completion. `cursor` counts characters from the start of `line`. Each
# candidate replaces line[start, cursor). An error yields no candidates rather than
# reaching options(error = ), which would offer a traceback for a key press.
complete_line <- function(line, cursor, limit = 500L) {
  res <- tryCatch(suppressWarnings({
    utils:::.assignLinebuffer(line)
    utils:::.assignEnd(cursor)
    token <- utils:::.guessTokenFromLine()
    utils:::.completeToken()
    comps <- unique(utils:::.retrieveCompletions())
    # This file's own helpers are on the search path too; only its masks are public.
    own <- setdiff(ls(environment(complete_line), all.names = TRUE), c("View", "q", "quit"))
    comps <- comps[!comps %in% own]
    start <- utils:::.CompletionEnv[["start"]]
    if (is.null(start)) start <- cursor - nchar(token)
    list(start = start, candidates = I(utils::head(comps, limit)))
  }), error = function(e) NULL)
  if (is.null(res)) res <- list(start = cursor, candidates = I(character()))
  json(res)
}

# ---------------------------------------------------------------- data viewer

views <- new.env(parent = emptyenv())
views$n <- 0L

col_type <- function(v) {
  if (is.factor(v)) return("fct")
  if (inherits(v, "Date")) return("date")
  if (inherits(v, "POSIXt")) return("dttm")
  if (is.list(v)) return("list")
  switch(typeof(v),
    double = "num", integer = "int", character = "chr", logical = "lgl",
    complex = "cplx", class(v)[1L]
  )
}

# Formatted per slice, so numbers share the digits of what is on screen, not of the
# whole column -- as RStudio does.
format_col <- function(v) {
  if (is.list(v)) {
    return(vapply(v, function(e) sprintf("<%s[%d]>", class(e)[1L], length(e)), ""))
  }
  out <- format(v, trim = TRUE, justify = "none")
  out[is.na(v)] <- NA_character_
  out
}

as_viewable <- function(x) {
  if (is.data.frame(x)) return(x)
  if (is.matrix(x) || is.table(x) && length(dim(x)) == 2L) {
    return(as.data.frame(unclass(x), stringsAsFactors = FALSE))
  }
  NULL
}

# Masks utils::View. The object stays in R and the page fetches rows on demand; only an
# id crosses over, through webR's own "view" message, which utils::View triggers.
View <- function(x, title) {
  if (missing(title)) title <- clip(deparse(substitute(x)), 40L)
  views$n <- views$n + 1L
  id <- paste0("v", views$n)
  expr <- substitute(x)
  data <- as_viewable(x)
  views[[id]] <- list(
    title = title,
    data = data,
    text = if (is.null(data)) utils::capture.output(utils::str(x)) else NULL,
    # A plain name can be re-read by the Refresh button; anything else is a snapshot.
    name = if (is.name(expr)) as.character(expr) else NULL,
    key = NULL,
    idx = NULL
  )
  utils::View(list(webrapp_view_id = id), title)
  invisible(NULL)
}

# Masks base::q()/quit(). The page restarts R in a fresh worker instead, so there is no
# workspace to save and `save` is ignored. The request reaches the page the same way
# View() ids do.
q <- function(save = "default", status = 0, runLast = TRUE) {
  utils::View(list(webrapp_restart = TRUE), "restart")
  invokeRestart("abort")
}
quit <- q

view_meta <- function(id) {
  v <- views[[id]]
  if (is.null(v)) stop("This view has been closed.")
  if (is.null(v$data)) return(json(list(kind = "text", title = v$title, text = I(v$text))))
  x <- v$data
  rn <- attr(x, "row.names")
  json(list(
    kind = "grid",
    title = v$title,
    nrow = nrow(x),
    ncol = ncol(x),
    refreshable = !is.null(v$name),
    rownames = !is.integer(rn),
    columns = lapply(seq_along(x), function(j) list(name = names(x)[j], type = col_type(x[[j]])))
  ))
}

view_refresh <- function(id) {
  v <- views[[id]]
  if (is.null(v$name)) stop("This view is a snapshot and cannot be refreshed.")
  data <- as_viewable(get(v$name, envir = globalenv()))
  if (is.null(data)) stop(sprintf("'%s' is no longer a data frame or matrix.", v$name))
  v$data <- data
  v$key <- NULL
  v$idx <- NULL
  views[[id]] <- v
  view_meta(id)
}

view_release <- function(id) {
  if (exists(id, envir = views, inherits = FALSE)) rm(list = id, envir = views)
  json(TRUE)
}

# ">5", "<=2", "1..10", "=3" or a bare number on numeric columns; otherwise a
# case-insensitive substring match against the formatted value.
match_filter <- function(v, f) {
  f <- trimws(f)
  if (is.numeric(v) && !is.factor(v)) {
    num <- function(s) suppressWarnings(as.numeric(s))
    if (grepl("^-?[0-9.eE+-]+\\s*\\.\\.\\s*-?[0-9.eE+-]+$", f)) {
      lim <- num(strsplit(f, "\\.\\.")[[1L]])
      return(!is.na(v) & v >= lim[1L] & v <= lim[2L])
    }
    m <- regmatches(f, regexec("^(<=|>=|<|>|=|==)?\\s*(-?[0-9.eE+-]+)$", f))[[1L]]
    if (length(m) && !is.na(num(m[3L]))) {
      b <- num(m[3L])
      ok <- switch(m[2L], "<" = v < b, ">" = v > b, "<=" = v <= b, ">=" = v >= b, v == b)
      return(!is.na(ok) & ok)
    }
  }
  s <- format_col(v)
  !is.na(s) & grepl(tolower(f), tolower(s), fixed = TRUE)
}

view_order <- function(v, q) {
  key <- paste(deparse(q[c("sort", "desc", "search", "filters")]), collapse = "")
  if (identical(v$key, key)) return(v$idx)
  x <- v$data
  keep <- rep(TRUE, nrow(x))
  for (col in names(q$filters)) {
    f <- q$filters[[col]]
    if (nzchar(trimws(f)) && col %in% names(x)) keep <- keep & match_filter(x[[col]], f)
  }
  if (nzchar(q$search)) {
    needle <- tolower(q$search)
    hit <- rep(FALSE, nrow(x))
    for (col in x) {
      s <- format_col(col)
      hit <- hit | (!is.na(s) & grepl(needle, tolower(s), fixed = TRUE))
    }
    keep <- keep & hit
  }
  idx <- which(keep)
  if (!is.null(q$sort) && q$sort %in% names(x) && !is.list(x[[q$sort]])) {
    idx <- idx[order(x[[q$sort]][idx], decreasing = isTRUE(q$desc), na.last = TRUE, method = "radix")]
  }
  v$key <- key
  v$idx <- idx
  views[[q$id]] <- v
  idx
}

# q: id, start (0-based), n, colStart (0-based), colN, sort, desc, search, filters.
view_rows <- function(query) {
  q <- jsonlite::fromJSON(query, simplifyVector = FALSE)
  if (is.null(q$search)) q$search <- ""
  if (is.null(q$filters)) q$filters <- list()
  v <- views[[q$id]]
  if (is.null(v)) stop("This view has been closed.")
  idx <- view_order(v, q)
  x <- v$data
  sel <- idx[seq.int(q$start + 1L, length.out = max(0L, min(q$n, length(idx) - q$start)))]
  cols <- seq.int(q$colStart + 1L, length.out = max(0L, min(q$colN, ncol(x) - q$colStart)))
  cells <- vapply(cols, function(j) format_col(x[[j]][sel]), character(length(sel)))
  if (!is.matrix(cells)) cells <- matrix(cells, nrow = length(sel))
  json(list(
    total = length(idx),
    rownames = I(as.character(row.names(x)[sel])),
    rows = cells
  ))
}

# ---------------------------------------------------------------- help

help_state <- new.env(parent = emptyenv())

# alias -> help file, per package. Read once: it is one small file per package, but
# the library is a lazily fetched image, so it is not free either.
alias_index <- function() {
  if (is.null(help_state$aliases)) {
    pkgs <- unique(rownames(utils::installed.packages()))
    out <- list()
    for (p in pkgs) {
      f <- file.path(find.package(p), "help", "aliases.rds")
      if (file.exists(f)) out[[p]] <- readRDS(f)
    }
    help_state$aliases <- out
  }
  help_state$aliases
}

# js/help.js sets color-scheme on :root, so light-dark() follows the app's theme.
HELP_CSS <- "
html{background:light-dark(#ffffff,#1e1e1e)}
body{font:14px/1.5 system-ui,-apple-system,sans-serif;margin:12px 16px;color:light-dark(#1f1f1f,#d4d4d4);max-width:60em}
h2{font-size:1.25em}h3{font-size:1.05em;margin-top:1.4em}
pre,code{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:.92em}
pre{background:light-dark(#f5f5f5,#2a2a2a);padding:8px;overflow-x:auto}
a{color:light-dark(#0066cc,#4fa6ff)}table{border-collapse:collapse}td{vertical-align:top;padding:2px 10px 2px 0}
"

# Clicks are posted to the page, which resolves them; the frame has no origin of its own.
HELP_SCRIPT <- "<script>
document.addEventListener('click', function (e) {
  var a = e.target.closest('a[href]');
  if (!a) return;
  var h = a.getAttribute('href');
  if (h.charAt(0) === '#') return;
  e.preventDefault();
  parent.postMessage({ webrappHelp: h }, '*');
});
</script>"

help_page <- function(html, pkg, topic) {
  html <- paste(html, collapse = "\n")
  # The stylesheet and KaTeX references point at R's dynamic help server, which does
  # not exist here.
  html <- gsub("<link[^>]*>", "", html, perl = TRUE)
  html <- gsub("(?s)<script.*?</script>", "", html, perl = TRUE)
  html <- sub("</head>", paste0("<style>", HELP_CSS, "</style></head>"), html, fixed = TRUE)
  html <- sub("</body>", paste0(HELP_SCRIPT, "</body>"), html, fixed = TRUE)
  list(html = html, pkg = pkg, topic = topic)
}

rd_page <- function(path) {
  pkg <- basename(dirname(dirname(path)))
  rd <- utils:::.getHelpFile(path)
  out <- tempfile(fileext = ".html")
  on.exit(unlink(out))
  tools::Rd2HTML(rd, out = out, package = pkg, dynamic = TRUE, stylesheet = "")
  help_page(readLines(out, encoding = "UTF-8", warn = FALSE), pkg, basename(path))
}

esc <- function(s) {
  s <- gsub("&", "&amp;", s, fixed = TRUE)
  s <- gsub("<", "&lt;", s, fixed = TRUE)
  gsub(">", "&gt;", s, fixed = TRUE)
}

simple_page <- function(title, body, pkg = "", topic = "") {
  help_page(
    c("<!DOCTYPE html><html><head><title>", esc(title), "</title></head><body>",
      "<h2>", esc(title), "</h2>", body, "</body></html>"),
    pkg, topic
  )
}

choose_page <- function(topic, paths) {
  items <- vapply(paths, function(p) {
    pkg <- basename(dirname(dirname(p)))
    sprintf('<li><a href="../../%s/help/%s">%s::%s</a></li>', pkg, basename(p), pkg, esc(topic))
  }, "")
  simple_page(sprintf("Help on topic '%s' was found in several packages", topic),
              c("<ul>", items, "</ul>"), topic = topic)
}

# Topic within pkg when given, else across every installed package. Links from a
# chooser page carry the help file name, which is usually but not always an alias.
help_topic <- function(topic, pkg = "") {
  idx <- alias_index()
  if (nzchar(pkg) && !is.null(idx[[pkg]])) {
    file <- if (topic %in% names(idx[[pkg]])) idx[[pkg]][[topic]] else if (topic %in% idx[[pkg]]) topic
    if (!is.null(file)) return(json(rd_page(file.path(find.package(pkg), "help", file))))
  }
  paths <- unlist(lapply(names(idx), function(p) {
    file <- idx[[p]][topic]
    if (is.na(file)) NULL else file.path(find.package(p), "help", file)
  }))
  if (!length(paths)) {
    return(json(simple_page(sprintf("No documentation for '%s'", topic),
                            "<p>No installed package has a help topic of that name.</p>")))
  }
  json(if (length(paths) == 1L) rd_page(paths) else choose_page(topic, paths))
}

help_index <- function(pkg) {
  dir <- find.package(pkg)
  desc <- utils::packageDescription(pkg)
  rd <- readRDS(file.path(dir, "Meta", "Rd.rds"))
  rd <- rd[order(tolower(rd$Name)), , drop = FALSE]
  rows <- sprintf('<tr><td><a href="../../%s/help/%s">%s</a></td><td>%s</td></tr>',
                  pkg, utils::URLencode(rd$Name, reserved = TRUE), esc(rd$Name), esc(rd$Title))
  json(simple_page(
    sprintf("%s %s: %s", pkg, desc$Version, gsub("\\s+", " ", desc$Title)),
    c("<p>", esc(gsub("\\s+", " ", desc$Description)), "</p><table>", rows, "</table>"),
    pkg = pkg
  ))
}

help_dir <- "/tmp/webrapp-help"
original_print_help <- utils:::print.help_files_with_topic

# ?topic in the console lands here. The page is written to a file and handed to the
# viewer that webr::viewer_install() set up, which sends a "browse" message;
# js/app.js routes anything under help_dir to the Help tab instead of the Viewer.
print_help <- function(x, ...) {
  paths <- as.character(x)
  if (!length(paths)) return(original_print_help(x, ...))
  page <- if (length(paths) == 1L) rd_page(paths) else choose_page(attr(x, "topic"), paths)
  dir.create(help_dir, showWarnings = FALSE, recursive = TRUE)
  file <- file.path(help_dir, "page.html")
  meta <- sprintf("<!-- webrapp-help %s -->", json(page[c("pkg", "topic")]))
  writeLines(c(meta, page$html), file, useBytes = TRUE)
  getOption("viewer")(file)
  invisible(x)
}

registerS3method("print", "help_files_with_topic", print_help, envir = asNamespace("utils"))

# ---------------------------------------------------------------- fork

# webR cannot fork, so mclapply() with mc.cores > 1 fails -- and options(mc.cores = 4),
# set by much brms code for its chains, reaches loo() and others that way. Those run on
# one core instead and say so, once; chains use webR workers (miraiWebR::daemons()).
fork_noted <- FALSE
no_fork_note <- function() {
  if (fork_noted) return(invisible())
  fork_noted <<- TRUE
  message("webR cannot fork, so parallel::mclapply() runs on one core here. ",
          "MCMC chains run in parallel on webR workers: see ?miraiWebR::daemons.")
}

local({
  ns <- asNamespace("parallel")
  for (fn in c("mclapply", "mcmapply", "pvec")) {
    f <- get(fn, envir = ns)
    body(f) <- bquote({
      if (!identical(as.integer(mc.cores), 1L)) as.environment("tools:webrapp")$no_fork_note()
      mc.cores <- 1L
      .(body(f))
    })
    unlockBinding(fn, ns)
    assign(fn, f, envir = ns)
    lockBinding(fn, ns)
  }
  # mclapply() over fewer than two items calls mcaffinity(), whose C code needs
  # sched_getaffinity(); webR's libc lacks it, so the call aborts R whatever mc.cores
  # is. There is no CPU affinity to report or set here.
  mcaffinity <- function(affinity = NULL) NULL
  environment(mcaffinity) <- ns
  unlockBinding("mcaffinity", ns)
  assign("mcaffinity", mcaffinity, envir = ns)
  lockBinding("mcaffinity", ns)
})
