# The R side of tools/test-packages.mjs, sourced into each webR session it starts.
#
# A package's tests run the way its framework runs them, and are reported one test at
# a time so that lib/TEST-SKIPS.tsv can name exactly what is accepted to fail:
#
#   testthat  tests/testthat, through testthat::test_dir() on the installed package;
#   tinytest  inst/tinytest, one file at a time;
#   scripts   every other tests/*.R, as R CMD check runs them: each in a fresh R (the
#             runner starts one per file), failing if it signals an error. .Rout.save
#             transcripts are not compared: webR formats some numbers differently.
#
# A tests/*.R file that only drives testthat or tinytest is not run as a script.
#
# Results are a data frame of package, file, test, status (pass, fail, error, skip)
# and message, written as JSON for the runner.

webrtest <- new.env()

webrtest$record <- function(file, test, status, message = "") {
  data.frame(
    file = file, test = test, status = status,
    message = substr(gsub("[\t\r\n]+", " ", message), 1L, 2000L),
    stringsAsFactors = FALSE
  )
}

webrtest$empty <- function() webrtest$record(character(), character(), character(), character())

webrtest$is_driver <- function(path) {
  text <- paste(readLines(path, warn = FALSE), collapse = "\n")
  grepl("test_check\\s*\\(|test_dir\\s*\\(|tinytest::|test_package\\s*\\(|run_test_dir\\s*\\(", text)
}

# What there is to run, for the runner to plan the sessions.
webrtest$discover <- function(dir) {
  tests <- file.path(dir, "tests")
  scripts <- if (dir.exists(tests)) {
    files <- list.files(tests, pattern = "\\.[rR]$", full.names = TRUE)
    basename(files[!vapply(files, webrtest$is_driver, logical(1))])
  } else {
    character()
  }
  list(
    testthat = dir.exists(file.path(tests, "testthat")),
    tinytest = dir.exists(file.path(dir, "inst", "tinytest")),
    scripts = I(scripts)
  )
}

# Into memory, so a run never writes into build/test-sources (snapshots, scratch files).
webrtest$stage <- function(dir, work) {
  unlink(work, recursive = TRUE)
  dir.create(work, recursive = TRUE)
  for (d in list.files(dir, full.names = TRUE)) file.copy(d, work, recursive = TRUE)
  work
}

webrtest$testthat_status <- function(results) {
  classes <- unlist(lapply(results, class))
  if ("expectation_error" %in% classes) return("error")
  if ("expectation_failure" %in% classes) return("fail")
  if (length(results) && all(vapply(results, inherits, logical(1), "expectation_skip"))) return("skip")
  "pass"
}

webrtest$testthat_message <- function(results) {
  bad <- Filter(function(r) inherits(r, c("expectation_error", "expectation_failure", "expectation_skip")), results)
  if (!length(bad)) return("")
  conditionMessage(bad[[1]])
}

webrtest$testthat_files <- function(dir) {
  sort(list.files(file.path(dir, "tests", "testthat"), pattern = "^test.*\\.[rR]$"))
}

# The packages a testthat driver (tests/testthat.R) attaches with library() or
# require() before test_check(), such as bit64's patrick. The runner calls test_dir()
# rather than the driver, so it attaches them itself, as R CMD check would have.
webrtest$driver_packages <- function(dir) {
  driver <- file.path(dir, "tests", "testthat.R")
  if (!file.exists(driver)) return(character())
  exprs <- tryCatch(parse(driver, keep.source = FALSE), error = function(e) expression())
  found <- character()
  walk <- function(e) {
    if (!is.call(e)) return(invisible())
    head <- e[[1]]
    fn <- if (is.call(head) && identical(head[[1]], as.name("::"))) {
      as.character(head[[3]])
    } else {
      as.character(head)[1]
    }
    if (fn %in% c("library", "require") && length(e) >= 2L &&
        (is.name(e[[2]]) || is.character(e[[2]]))) {
      found <<- c(found, as.character(e[[2]]))
    }
    for (a in as.list(e)[-1]) walk(a)
  }
  for (e in exprs) walk(e)
  # A name that is not an installed package is a variable (library(x, character.only
  # = TRUE)) or a package the test library lacks; the tests report the latter.
  Filter(function(p) nzchar(system.file(package = p)), unique(found))
}

# `file` limits the run to one test file, which the runner falls back to when a whole
# run brings R down, so that one file's crash does not lose every other test.
webrtest$run_testthat <- function(package, dir, file = NULL) {
  Sys.setenv(TESTTHAT_PARALLEL = "false")
  for (p in webrtest$driver_packages(dir)) {
    suppressPackageStartupMessages(library(p, character.only = TRUE))
  }
  # test_dir() passes perl = TRUE on to grepl(), so \Q...\E matches the name literally.
  filter <- if (!is.null(file)) {
    paste0("^\\Q", sub("\\.[rR]$", "", sub("^test[-_]?", "", file)), "\\E$")
  }
  res <- testthat::test_dir(
    file.path(dir, "tests", "testthat"),
    package = package,
    load_package = "installed",
    reporter = "silent",
    stop_on_failure = FALSE,
    stop_on_warning = FALSE,
    filter = filter,
    perl = TRUE
  )
  if (!length(res)) return(webrtest$empty())
  do.call(rbind, lapply(res, function(t) {
    webrtest$record(
      file = t$file,
      # An error outside any test_that() belongs to the file.
      test = if (length(t$test) == 1L && !is.na(t$test) && nzchar(t$test)) t$test else "(file)",
      status = webrtest$testthat_status(t$results),
      message = webrtest$testthat_message(t$results)
    )
  }))
}

webrtest$run_tinytest <- function(package, dir, at_home) {
  suppressPackageStartupMessages(library(package, character.only = TRUE))
  files <- sort(list.files(file.path(dir, "inst", "tinytest"), pattern = "^test.*\\.[rR]$", full.names = TRUE))
  out <- lapply(files, function(f) {
    r <- tryCatch(
      tinytest::run_test_file(f, at_home = at_home, verbose = 0, color = FALSE),
      error = function(e) e
    )
    if (inherits(r, "error")) {
      return(webrtest$record(basename(f), "(file)", "error", conditionMessage(r)))
    }
    df <- as.data.frame(r)
    if (!nrow(df)) return(webrtest$record(basename(f), "(file)", "pass"))
    webrtest$record(
      file = basename(f),
      test = paste0("L", df$first, ": ", substr(gsub("\\s+", " ", df$call), 1L, 120L)),
      status = ifelse(df$result, "pass", "fail"),
      message = ifelse(df$result, "", paste(df$short, df$diff))
    )
  })
  do.call(rbind, c(list(webrtest$empty()), out))
}

webrtest$run_script <- function(dir, script) {
  owd <- setwd(file.path(dir, "tests"))
  on.exit(setwd(owd))
  # As R runs a script non-interactively: expression by expression, stopping at the
  # first error unless options(error = ) is set, in which case R calls the handler
  # and carries on -- several packages' scripts rely on that to show expected errors.
  exprs <- tryCatch(parse(script, keep.source = FALSE), error = function(e) e)
  if (inherits(exprs, "error")) {
    return(webrtest$record(script, "(script)", "error", conditionMessage(exprs)))
  }
  # Scripts end with q() as often as not, which in webR ends webR itself; a mask on
  # the search path, ahead of base and out of reach of rm(list = ls()), ends the
  # script instead, with its status.
  quit_env <- attach(NULL, name = "webrtest:quit", warn.conflicts = FALSE)
  on.exit(detach("webrtest:quit", character.only = TRUE), add = TRUE)
  quit_env$q <- quit_env$quit <- function(save = "default", status = 0, runLast = TRUE) {
    stop(structure(class = c("webrtest_quit", "error", "condition"),
                   list(message = paste("quit with status", status), call = NULL, status = status)))
  }
  # Each script has an R of its own, so it runs in the global environment, as with
  # R CMD check: some look up their objects there from inside functions.
  env <- globalenv()
  for (expr in exprs) {
    cat(">", paste(deparse(expr), collapse = "\n+ "), "\n")
    err <- tryCatch({
      res <- withVisible(eval(expr, env))
      if (res$visible) print(res$value)
      NULL
    }, error = function(e) e)
    if (is.null(err)) next
    if (inherits(err, "webrtest_quit")) {
      if (identical(as.numeric(err$status), 0)) break
      return(webrtest$record(script, "(script)", "error", conditionMessage(err)))
    }
    cat("Error:", conditionMessage(err), "\n")
    handler <- getOption("error")
    if (is.null(handler)) {
      return(webrtest$record(script, "(script)", "error", conditionMessage(err)))
    }
    if (is.function(handler)) handler() else eval(handler, globalenv())
  }
  webrtest$record(script, "(script)", "pass")
}

webrtest$write <- function(results, path) {
  writeLines(jsonlite::toJSON(results, dataframe = "rows", auto_unbox = TRUE), path)
}
