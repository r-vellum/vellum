# Backend parity on rasterised ink (R-3): the same scene rendered to PNG, SVG
# and PDF must put ink in the same places, in the same colours. The SVG and PDF
# are rasterised back to pixels (see helper-parity.R) and compared with the
# PNG at a 1-px antialiasing tolerance. Each fixture targets a feature that has
# diverged between backends before.

parity_dpi <- 96
parity_page <- function() vl_scene(3, 2, dpi = parity_dpi, bg = "white")

test_that("plain lines, polygons and rects match across backends", {
  s <- parity_page() |>
    draw(lines_grob(
      c(0.1, 0.4, 0.6, 0.9),
      c(0.2, 0.8, 0.3, 0.7),
      gp = vl_gpar(col = "black", lwd = 3)
    )) |>
    draw(polygon_grob(
      c(0.2, 0.5, 0.35),
      c(0.1, 0.1, 0.45),
      gp = vl_gpar(fill = "steelblue", col = "darkred", lwd = 2)
    )) |>
    draw(rect_grob(
      x = 0.75,
      y = 0.25,
      width = 0.3,
      height = 0.3,
      gp = vl_gpar(fill = "orange", col = NA)
    ))
  expect_backend_parity(s, parity_dpi, label = "lines")
})

test_that("outlined text matches across backends", {
  s <- parity_page() |>
    draw(text_grob(
      "Parity 123",
      x = 0.5,
      y = 0.5,
      gp = vl_gpar(fontsize = 28, col = "black")
    ))
  # glyph antialiasing differs between rasterisers; the shapes must not
  expect_backend_parity(s, parity_dpi, colour = 40, label = "text")
})

test_that("even and odd dash patterns match across backends", {
  s <- parity_page() |>
    draw(lines_grob(
      c(0.05, 0.95),
      c(0.3, 0.3),
      gp = vl_gpar(col = "black", lwd = 3, lty = c(4, 2, 1), lineend = "butt")
    )) |>
    draw(lines_grob(
      c(0.05, 0.95),
      c(0.7, 0.7),
      gp = vl_gpar(col = "black", lwd = 3, lty = "dashed", lineend = "butt")
    ))
  expect_backend_parity(s, parity_dpi, label = "dashes")
})

test_that("gradient fills and strokes match across backends", {
  s <- parity_page() |>
    draw(rect_grob(
      width = 0.8,
      height = 0.6,
      gp = vl_gpar(col = NA, fill = linear_gradient(c("#F97316", "#22C55E")))
    )) |>
    draw(circle_grob(
      x = 0.85,
      y = 0.8,
      r = 0.12,
      gp = vl_gpar(col = NA, fill = radial_gradient(c("white", "#1D4ED8")))
    )) |>
    draw(lines_grob(
      c(0.1, 0.9),
      c(0.1, 0.1),
      gp = vl_gpar(col = linear_gradient(c("#1D4ED8", "#DC2626")), lwd = 10)
    ))
  expect_backend_parity(s, parity_dpi, label = "gradient")
})

test_that("pattern fills, strokes and reflection match across backends", {
  # Cells of a whole number of pixels (24 px), so a rasteriser that snaps a
  # tiling step to the pixel grid does not drift.
  dots <- vl_pattern(
    circle_grob(r = 0.35, gp = vl_gpar(fill = "red", col = NA)),
    width = 1 / 12,
    height = 1 / 8
  )
  solid <- vl_pattern(
    rect_grob(gp = vl_gpar(fill = "red", col = NA)),
    width = 1 / 12,
    height = 1 / 8
  )
  halves <- vl_pattern(
    list(
      rect_grob(x = 0.25, width = 0.5, gp = vl_gpar(fill = "red", col = NA)),
      rect_grob(x = 0.75, width = 0.5, gp = vl_gpar(fill = "blue", col = NA))
    ),
    width = 1 / 12,
    height = 1 / 8,
    extend = "reflect"
  )
  s <- parity_page() |>
    draw(rect_grob(
      x = 0.25,
      y = 0.5,
      width = 0.4,
      height = 0.8,
      gp = vl_gpar(col = NA, fill = dots)
    )) |>
    draw(rect_grob(
      x = 0.75,
      y = 0.7,
      width = 0.4,
      height = 0.4,
      gp = vl_gpar(col = NA, fill = halves)
    )) |>
    draw(lines_grob(
      c(0.55, 0.95),
      c(0.25, 0.25),
      gp = vl_gpar(col = solid, lwd = 20, lineend = "butt")
    ))
  expect_backend_parity(s, parity_dpi, label = "pattern")
})

test_that("viewport clipping matches across backends", {
  s <- parity_page() |>
    push(vl_viewport(width = 0.5, height = 0.5, clip = TRUE)) |>
    draw(circle_grob(r = 0.8, gp = vl_gpar(fill = "purple", col = NA))) |>
    draw(lines_grob(
      c(-0.2, 1.2),
      c(-0.2, 1.2),
      gp = vl_gpar(col = "black", lwd = 6)
    )) |>
    pop()
  expect_backend_parity(s, parity_dpi, label = "clip")
})
