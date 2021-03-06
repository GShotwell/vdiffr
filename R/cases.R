#' Collect cases
#'
#' These functions are mainly intended for internal use by
#' \code{\link{manage_cases}()}. They are useful to programmatically
#' collect cases.
#'
#' @inheritParams manage_cases
#' @seealso \code{\link{manage_cases}()}
#' @return A \code{cases} object. \code{collect_new_cases()},
#'   \code{collect_mismatched_cases()} and
#'   \code{collect_orphaned_cases()} return a filtered \code{cases}
#'   object.
#' @export
collect_cases <- function(package = ".", filter = NULL) {
  on.exit(set_active_collecter(NULL))

  message("Running testthat to collect visual cases\n\n",
    "  N = New visual case\n  X = Failed doppelganger\n  o = Convincing doppelganger\n")
  package <- devtools::as.package(package)
  reporter <- vdiffrReporter$new(package$path)
  suppressMessages(devtools::test(package, filter = filter, reporter = reporter))

  cases <- active_collecter()$get_cases()

  cases_names <- map_chr(cases, "name")
  is_duplicated <- duplicated(cases_names)
  if (any(is_duplicated)) {
    warning(call. = FALSE,
      "Duplicated expectations: ",
      paste(cases_names[is_duplicated], collapse = ", "))
  }

  c(cases, orphaned_cases(cases))
}

orphaned_cases <- function(cases) {
  pkg_path <- attr(cases, "pkg_path")
  cases_paths <- map_chr(cases, "path")
  cases_paths <- map_chr(cases_paths, adjust_figs_path, pkg_path)
  cases_paths <- map_chr(cases_paths, normalise_path)

  figs_path <- file.path(pkg_path, "tests", "figs")
  figs_files <- dir(figs_path, ".*\\.svg$", full.names = TRUE, recursive = TRUE)
  figs_files <- map_chr(figs_files, normalise_path)

  # Testcases are absolute, paths are relative to 'testthat' folder
  svg_paths <- map_chr(figs_files, function(path) {
    prefix <- paste0(file.path(pkg_path, "tests"))
    rel_path <- substr(path, nchar(prefix) + 1, nchar(path))
    paste0("..", rel_path)
  })

  is_orphan <- !figs_files %in% cases_paths
  orphans_testcases <- figs_files[is_orphan]
  orphans_paths <- svg_paths[is_orphan]
  orphans_names <- map_chr(orphans_paths, ~str_trim_ext(basename(.x)))

  cases <- purrr::transpose(list(
    name = orphans_names,
    path = orphans_paths,
    testcase = orphans_testcases,
    verbose = rep_along(orphans_names, FALSE)
  ))
  orphaned_cases <- purrr::map(cases, orphaned_case)
  cases(orphaned_cases, pkg_path)
}

#' @rdname collect_cases
#' @export
collect_new_cases <- function(package = ".") {
  filter_cases(collect_cases(package), "new_case")
}

#' @rdname collect_cases
#' @export
collect_mismatched_cases <- function(package = ".") {
  filter_cases(collect_cases(package), "mismatch_case")
}

#' @rdname collect_cases
#' @export
collect_orphaned_cases <- function(package = ".") {
  filter_cases(collect_cases(package), "orphaned_case")
}

#' Cases validation
#'
#' These functions are mainly intended for internal use by
#' \code{\link{manage_cases}()}. They are useful to programmatically
#' validate cases or delete orphaned cases.
#'
#' @seealso \code{\link{manage_cases}()}
#' @param cases A \code{cases} object returned by one of the
#'   collecting functions such as \code{\link{collect_cases}()}.
#' @export
validate_cases <- function(cases = collect_new_cases()) {
  stopifnot(is_cases(cases))
  cases <- filter_cases(cases, c("new_case", "mismatch_case"))

  pkg_path <- attr(cases, "pkg_path")
  if (is.null(pkg_path)) {
    stop("Internal error: Package path is missing", call. = FALSE)
  }

  write_deps_note(cases, pkg_path)
  walk(cases, update_case, pkg_path)
}

update_deps_note <- function(package = ".") {
  cases <- collect_cases(package)
  pkg_path <- attr(cases, "pkg_path")
  if (is.null(pkg_path)) {
    stop("Internal error: Package path is missing", call. = FALSE)
  }

  write_deps_note(cases, pkg_path)
}

write_deps_note <- function(cases, pkg_path) {
  deps <- attr(cases, "deps")
  versions <- map_chr(deps, package_version)
  deps_lines <- map2_chr(deps, versions, paste, sep = ": ")

  engine_dep <- glue("vdiffr-svg-engine: { SVG_ENGINE_VER }")
  deps_lines <- c(deps_lines, engine_dep)

  deps_note_file <- file.path(pkg_path, "tests", "figs", "deps.txt")
  writeLines(deps_lines, deps_note_file)
}

update_case <- function(case, pkg_path) {
  path <- file.path(pkg_path, "tests", "figs", case$path)
  ensure_directories(dirname(path))
  file.copy(case$testcase, path, overwrite = TRUE)
}

#' @rdname validate_cases
#' @export
delete_orphaned_cases <- function(cases = collect_orphaned_cases()) {
  stopifnot(is_cases(cases))
  pkg_path <- attr(cases, "pkg_path")
  if (is.null(pkg_path)) {
    stop("Internal error: Package path is missing", call. = FALSE)
  }

  cases <- filter_cases(cases, "orphaned_case")
  paths <- map_chr(cases, "testcase")
  walk(paths, file.remove)
}

cases <- function(x, pkg_path, deps = NULL) {
  structure(x,
    class = "cases",
    pkg_path = pkg_path,
    deps = deps
  )
}

is_cases <- function(case) inherits(case, "cases")

c.cases <- function(..., recursive = FALSE) {
  cases(NextMethod(), attr(..1, "pkg_path"), attr(..1, "deps"))
}

`[.cases` <- function(x, i) {
  cases(NextMethod(), attr(x, "pkg_path"), attr(x, "deps"))
}

#' @export
print.cases <- function(x, ...) {
  cat(sprintf("<cases>: %s\n", length(x)))

  mismatched <- filter_cases(x, "mismatch_case")
  if (length(mismatched) > 0) {
    cat("\nMismatched:\n")
    print_cases_names(mismatched)
  }

  new <- filter_cases(x, "new_case")
  if (length(new) > 0) {
    cat("\nNew:\n")
    print_cases_names(new)
  }

  orphaned <- filter_cases(x, "orphaned_case")
  if (length(orphaned) > 0) {
    figs_path <- file.path(attr(x, "pkg_path"), "tests")

    cat("\nOrphaned:\n")
    files <- map_chr(orphaned, "path")
    files <- map_chr(files, function(file) {
      file <- sub(paste0("^", figs_path, .Platform$file.sep), "", file)
      paste0(" - ", file)
    })
    cat(paste(files, collapse = "\n"), "\n")
  }

  invisible(cases)
}

print_cases_names <- function(cases) {
  names <- map_chr(names(cases), function(name) paste0(" - ", name))
  cat(paste(names, collapse = "\n"), "\n")
}

filter_cases <- function(cases, type) {
  filtered <- keep(cases, inherits, type)

  # Restore attributes discarded by purrr::keep()
  cases(filtered, attr(cases, "pkg_path"), attr(cases, "deps"))
}

case <- function(case) {
  set_attrs(case, class = "case")
}
mismatch_case <- function(case) {
  set_attrs(case, class = c("mismatch_case", "case"))
}
new_case <- function(case) {
  set_attrs(case, class = c("new_case", "case"))
}
orphaned_case <- function(case) {
  set_attrs(case, class = c("orphaned_case", "case"))
}
success_case <- function(case) {
  set_attrs(case, class = c("success_case", "case"))
}

is_case <- function(case) {
  inherits(case, "case")
}
is_mismatch_case <- function(case) {
  inherits(case, "mismatch_case")
}
is_new_case <- function(case) {
  inherits(case, "new_case")
}
is_orphaned_case <- function(case) {
  inherits(case, "orphaned_case")
}
