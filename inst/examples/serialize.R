# A worked vellum example: a scene as a value you can store, compare, and compose.
#
#   * `scene_write()` / `scene_read()` -- persist a built scene and rebuild it.
#   * `scene_hash()`                   -- has this scene changed?
#   * `scene_diff()`                   -- what changed, in scene terms.
#   * `scene_inset()`                  -- put one scene inside another.
#
# Run with:  Rscript inst/examples/serialize.R  [output.png]

library(vellum)

out <- commandArgs(trailingOnly = TRUE)
out <- if (length(out)) out[[1]] else "serialize.png"

plot_of <- function(fill = "steelblue", r = 0.3) {
  set.seed(1)
  vl_scene(4, 3, dpi = 130, bg = "white") |>
    push(vl_viewport(name = "panel", xscale = c(0, 1), yscale = c(0, 1))) |>
    draw(rect_grob(gp = vl_gpar(fill = "grey96", col = "grey70"))) |>
    draw(points_grob(runif(60), runif(60), gp = vl_gpar(fill = fill, col = NA))) |>
    draw(circle_grob(x = 0.5, y = 0.5, r = r, name = "marker",
                     gp = vl_gpar(fill = NA, col = "grey20", lwd = 2))) |>
    pop()
}

# --- persist -----------------------------------------------------------------
cat("== scene_write() / scene_read() ==\n")
for (ext in c("rds", "json")) {
  f <- file.path(tempdir(), paste0("scene.", ext))
  ok <- tryCatch({ scene_write(plot_of(), f); TRUE }, error = function(e) FALSE)
  if (!ok) { cat(sprintf("  %-5s skipped (needs jsonlite)\n", ext)); next }
  a <- tempfile(fileext = ".png"); b <- tempfile(fileext = ".png")
  vl_clear_render_cache(); render(plot_of(), a)
  vl_clear_render_cache(); render(scene_read(f), b)
  cat(sprintf("  %-5s %7s bytes, renders identically: %s\n", ext,
              format(file.size(f), big.mark = ","),
              identical(tools::md5sum(a)[[1]], tools::md5sum(b)[[1]])))
}
cat("  A scene is now a value: cache it, send it to a worker, keep it as a\n")
cat("  reproducible intermediate between the code and the pixels.\n\n")

# --- fingerprint -------------------------------------------------------------
cat("== scene_hash() ==\n")
cat(sprintf("  two independent builds of the same plot agree: %s\n",
            scene_hash(plot_of()) == scene_hash(plot_of())))
cat(sprintf("  a changed fill changes the hash:              %s\n",
            scene_hash(plot_of()) != scene_hash(plot_of(fill = "tomato"))))

# --- diff --------------------------------------------------------------------
cat("\n== scene_diff() ==\n")
print(scene_diff(plot_of(), plot_of(fill = "tomato", r = 0.42)))
cat("\n  A structural diff, not a pixel diff -- so it is immune to the font-stack\n")
cat("  differences that make image comparison across machines so noisy.\n")

# --- compose -----------------------------------------------------------------
# A scene has a known resolved size, so nesting one in another is a graft.
overview <- plot_of(fill = "grey65", r = 0.45)
detail <- vl_scene(1, 1) |>
  push(vl_viewport(xscale = c(0, 1), yscale = c(0, 1))) |>
  draw(rect_grob(gp = vl_gpar(fill = "white", col = "grey40"))) |>
  draw(points_grob(runif(30) * 0.4 + 0.3, runif(30) * 0.4 + 0.3,
                   gp = vl_gpar(fill = "tomato", col = NA))) |>
  pop()

composed <- scene_inset(overview, detail, x = 0.78, y = 0.76,
                        width = 0.34, height = 0.4, name = "inset",
                        shadow = vl_shadow(dx = 2, dy = 2, blur = 3))

render(composed, out)
cat(sprintf("\n== scene_inset() ==\n  wrote %s\n", out))
cat(sprintf("  the inset is an ordinary addressable node: %s\n",
            paste(node_names(composed), collapse = ", ")))
cat("  so it can be edited by name, inset again, or serialized like any scene.\n")
