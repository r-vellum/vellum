# A worked vellum example: the small API additions.
#
#   * `vl_gpar(cex =)`          -- a multiplier on `fontsize`, like grid's.
#   * `vl_convert()`            -- resolve a unit to a number, in a scene's context.
#   * `render(scale =)`         -- more device pixels, same physical size (retina).
#   * `scene_png()`/`scene_pdf()` -- the encoded document as raw bytes, no file.
#   * `raster_grob("x.png")`    -- read an image from a path, no R image package.
#
# Run with:  Rscript inst/examples/api-quickwins.R  [output.png|.svg|.pdf]

library(vellum)

out <- commandArgs(trailingOnly = TRUE)
out <- if (length(out)) out[[1]] else "api-quickwins.png"

# --- cex: relative type sizing ----------------------------------------------
# `cex` multiplies `fontsize`, so a theme can say "20% larger" without knowing
# the base size. These two are exactly equivalent, which the example shows by
# drawing them side by side.
base_gp <- vl_gpar(fontfamily = "", fontsize = 10)

# --- an image from a file ----------------------------------------------------
# `raster_grob()` takes a PNG path directly (decoded in the Rust backend), or an
# in-memory array. Here we make a small gradient tile, write it, and read it back
# to show the path form working.
tile <- array(0, dim = c(32, 32, 3))
tile[, , 1] <- rep(seq(0, 1, length.out = 32), each = 32)  # red ramps down rows
tile[, , 3] <- rep(seq(1, 0, length.out = 32), times = 32) # blue ramps across
tile_png <- file.path(tempdir(), "vellum-example-tile.png")
# Write it with vellum itself, so the example needs no image package at all.
render(vl_scene(1, 1, dpi = 32, bg = "white") |> draw(raster_grob(tile)), tile_png)

scene <- vl_scene(6, 3.2, dpi = 150, bg = "grey97") |>
  push(vl_viewport(name = "page", x = 0.5, y = 0.5, width = 0.92, height = 0.86)) |>
  draw(text_grob("Phase 2 additions", x = 0, y = 1, just = c("left", "top"),
                 gp = vl_gpar(fontsize = 13, fontface = "bold"))) |>
  # cex vs the equivalent absolute fontsize -- identical glyphs.
  draw(text_grob("fontsize = 10, cex = 1.6", x = 0, y = 0.78, just = c("left", "top"),
                 gp = vl_gpar(fontsize = 10, cex = 1.6, col = "steelblue4"))) |>
  draw(text_grob("fontsize = 16", x = 0, y = 0.62, just = c("left", "top"),
                 gp = vl_gpar(fontsize = 16, col = "grey55"))) |>
  # The image read back from a file path.
  draw(raster_grob(tile_png, x = 0.86, y = 0.68, width = 0.2, height = 0.42)) |>
  draw(text_grob("raster_grob(<path>)", x = 0.86, y = 0.42, just = c("centre", "top"),
                 gp = base_gp))

# --- vl_convert: how big is that, really? -----------------------------------
# A panel with a native scale, so the length-vs-position distinction is visible.
scene <- scene |>
  push(vl_viewport(name = "panel", x = 0.28, y = 0.18, width = 0.5, height = 0.3,
                   xscale = c(10, 20), yscale = c(0, 1))) |>
  draw(rect_grob(gp = vl_gpar(fill = "white", col = "grey70"))) |>
  pop()

panel_w <- vl_convert(vl_unit(1, "npc"), "mm", scene, name = "panel")
len12 <- vl_convert(vl_unit(12, "native"), "mm", scene, name = "panel")
pos12 <- vl_convert(vl_unit(12, "native"), "mm", scene, name = "panel",
                    what = "position")

cat(sprintf("panel width            : %.2f mm\n", panel_w))
cat(sprintf("12 native as a LENGTH  : %.2f mm  (12/10 of the scale span)\n", len12))
cat(sprintf("12 native as a POSITION: %.2f mm  ((12-10)/10 -- scale starts at 10)\n", pos12))
cat(sprintf("1 inch                 : %.2f mm  (absolute: no scene needed)\n",
            vl_convert(vl_unit(1, "in"), "mm")))

scene <- scene |>
  draw(text_grob(sprintf("panel is %.0f mm wide (vl_convert)", panel_w),
                 x = 0.28, y = 0.10, just = c("centre", "top"), gp = base_gp)) |>
  pop()

# --- render(scale =): same size, more pixels --------------------------------
render(scene, out)
if (identical(tolower(tools::file_ext(out)), "png")) {
  out2x <- sub("\\.png$", "@2x.png", out)
  render(scene, out2x, scale = 2)
  cat(sprintf("\nwrote %s\n      %s  (scale = 2: 2x the pixels, same %s)\n",
              out, out2x, "physical size"))
} else {
  cat(sprintf("\nwrote %s\n", out))
}

# --- scene_png() / scene_pdf(): bytes, not files -----------------------------
# What a widget or web handler wants: the encoded document in memory.
png_bytes <- scene_png(scene)
pdf_bytes <- scene_pdf(scene)
cat(sprintf("scene_png(): %s raw bytes, signature %s\n",
            format(length(png_bytes), big.mark = ","), rawToChar(png_bytes[2:4])))
cat(sprintf("scene_pdf(): %s raw bytes, header %s\n",
            format(length(pdf_bytes), big.mark = ","), rawToChar(pdf_bytes[1:5])))
cat(sprintf("scene_png(scale = 2) is larger: %s bytes\n",
            format(length(scene_png(scene, scale = 2)), big.mark = ",")))
