# PowerPoint (DrawingML) output: the scene as editable Office shapes.

# The DrawingML fragment for a scene: one `<p:grpSp>` whose child coordinates
# are absolute slide EMU, offset by `left`/`top` (inches). Rasters are written
# as PNG files into `media_dir` and referenced by path, which is what officer
# expects of `ph_with(<xml_document>)` (it copies them into the package when the
# deck is saved). `media_dir = ""` leaves placeholder names instead, for tests.
# Returns `list(xml, files, warnings)`; warnings are not emitted here.
.dml_fragment <- function(
  scene,
  left = 0,
  top = 0,
  text = c("native", "outline"),
  media_dir = ""
) {
  text <- match.arg(text)
  scene <- as_vellum_scene(scene)
  s <- .scene_to_backend(scene)
  s$render_dml(
    as.numeric(left) * 914400,
    as.numeric(top) * 914400,
    identical(text, "outline"),
    media_dir
  )
}
