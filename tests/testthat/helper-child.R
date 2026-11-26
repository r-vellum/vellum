# Run `lines` of R code in a fresh R process with this vellum loaded, for code
# whose failure mode is a crash of the whole process (a Rust abort, a segfault
# in a font library): a regression then fails the calling test instead of
# killing the test run. Under `load_all()` (devtools::test()) the child loads
# the same source tree without recompiling; under R CMD check it attaches the
# installed package. Returns the exit status and the combined output.
run_vellum_child <- function(lines) {
  path <- getNamespaceInfo("vellum", "path")
  dev <- "pkgload" %in% loadedNamespaces() && pkgload::is_dev_package("vellum")
  head <- if (dev) {
    sprintf(
      "suppressMessages(pkgload::load_all(%s, quiet = TRUE, compile = FALSE))",
      deparse(path)
    )
  } else {
    sprintf("library(vellum, lib.loc = %s)", deparse(dirname(path)))
  }
  script <- withr::local_tempfile(fileext = ".R")
  out <- withr::local_tempfile(fileext = ".txt")
  writeLines(c(head, lines), script)
  status <- suppressWarnings(system2(
    file.path(R.home("bin"), "Rscript"),
    c("--vanilla", shQuote(script)),
    stdout = out,
    stderr = out
  ))
  list(status = status, output = readLines(out, warn = FALSE))
}
