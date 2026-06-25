.onLoad <- function(libname, pkgname) {
  # Register the vctrs double-dispatch coercion methods. A static NAMESPACE
  # `S3method()` directive can't name the intermediate generic
  # (`vec_ptype2.vellum_unit`), so use vctrs's registrar. (It emits a dev-only
  # "can't find generic" message under devtools; harmless for installed users.)
  vctrs::s3_register("vctrs::vec_ptype2.vellum_unit", "vellum_unit")
  vctrs::s3_register("vctrs::vec_cast.vellum_unit", "vellum_unit")
  # Register S7 methods (compile generic etc.) so dispatch works once installed.
  S7::methods_register()
}
