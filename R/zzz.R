.onLoad <- function(libname, pkgname) {
  # Register the vctrs double-dispatch coercion methods. A static NAMESPACE
  # `S3method()` directive can't name the intermediate generic
  # (`vec_ptype2.vellum_unit`), so use vctrs's registrar. It warns that it
  # "can't find generic `vec_ptype2.vellum_unit` in package vctrs" because that
  # intermediate generic is created on demand, not exported by vctrs; the method
  # still registers (covered by the unit coercion tests). The warning is a known
  # false positive, so silence it to keep load and `R CMD check` clean.
  suppressWarnings(suppressMessages({
    vctrs::s3_register("vctrs::vec_ptype2.vellum_unit", "vellum_unit")
    vctrs::s3_register("vctrs::vec_cast.vellum_unit", "vellum_unit")
  }))
  # Register S7 methods (compile generic etc.) so dispatch works once installed.
  S7::methods_register()
}
