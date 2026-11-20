# TEMPORARY (VR-15): print raw measurements on the CI runner. Remove before merge.
test_that("VR-15 diagnostic", {
  info <- c(
    machine = Sys.info()[["machine"]],
    sysname = Sys.info()[["sysname"]],
    valid_mm = paste(vl_strwidth(c("p", "q", "k"), "", "plain", 8.8, unit = "mm"), collapse = " "),
    textshaping_NA_pt = textshaping::shape_text("p", size = NA_real_, res = 72)$metrics$width,
    vellum_NA = tryCatch(vl_strwidth("p", fontsize = NA), error = function(e) conditionMessage(e))
  )
  message("VR15-DIAG ", paste(names(info), info, sep = "=", collapse = " | "))
  succeed()
})
