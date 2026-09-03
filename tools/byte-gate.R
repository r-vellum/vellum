# The byte-identical gate: prove a change did not move the picture.
#
# Renders a set of representative scenes to PNG / SVG / PDF plus a raw raster
# digest, under BOTH the current working tree and a baseline ref (default
# `main`), and compares them byte for byte. Any diff must be intended and
# stated -- most engine work should change nothing, and the one scene that
# does change should be the one you meant.
#
# Usage, from the package root:
#
#   Rscript tools/byte-gate.R              # working tree vs main
#   Rscript tools/byte-gate.R v0.6.9       # working tree vs any ref
#   Rscript tools/byte-gate.R main /tmp/g  # keep the renders for inspection
#
# Exits non-zero if anything differs, so it can gate a commit. Each version is
# compiled and installed into its own temporary library, which means a full
# Rust build per side: budget several minutes on a cold cache.
#
# Reading a failure: the summary names the scene and format that moved. The
# renders are kept under the work directory, so `compare` / an image diff on
# the two PNGs shows you what changed. A PNG diff with an identical raster
# digest would mean an encoder change rather than a geometry change.
#
# Both sides run on this machine, so system fonts are held constant and the
# `text` scene is a fair comparison here -- but it is the one scene that would
# differ across machines, which is why the committed snapshot tests skip text.

args <- commandArgs(trailingOnly = TRUE)
ref <- if (length(args) >= 1) args[[1]] else "main"
work <- if (length(args) >= 2) args[[2]] else tempfile("byte-gate-")

# --- the scenes ---------------------------------------------------------------
#
# One per drawing path worth guarding: batched markers, a stroked polyline, a
# filled polygon, a MULTI-RING path, batched rects, text, a gradient paint,
# batched circles, a sector's arc flattening, the sketch generator, and a
# stroke expanded to an outline. Add to this list rather than replacing it --
# the value of the gate is that the same scenes are compared over time.
gate_scenes <- function() {
  set.seed(42) # the batched marks use random positions; fix them
  list(
    markers = vl_scene(4, 3, dpi = 96, bg = "white") |>
      draw(points_grob(
        runif(40),
        runif(40),
        size = vl_unit(3, "mm"),
        shape = "circle"
      )),
    lines = vl_scene(4, 3, dpi = 96, bg = "white") |>
      draw(lines_grob(
        seq(0, 1, length.out = 20),
        sin(seq(0, 6, length.out = 20)) / 3 + 0.5,
        gp = vl_gpar(col = "steelblue", lwd = 4)
      )),
    polys = vl_scene(4, 3, dpi = 96, bg = "white") |>
      draw(polygon_grob(
        c(0.2, 0.8, 0.5),
        c(0.2, 0.2, 0.8),
        gp = vl_gpar(fill = "tomato", col = "grey20")
      )),
    path = vl_scene(4, 3, dpi = 96, bg = "white") |>
      draw(path_grob(
        x = c(0.1, 0.9, 0.9, 0.1, 0.4, 0.6, 0.6, 0.4),
        y = c(0.1, 0.1, 0.9, 0.9, 0.4, 0.4, 0.6, 0.6),
        id = rep(1:2, each = 4),
        rule = "evenodd",
        gp = vl_gpar(fill = "steelblue")
      )),
    rects = vl_scene(4, 3, dpi = 96, bg = "white") |>
      draw(rect_grob(
        x = c(0.3, 0.7),
        y = 0.5,
        width = 0.2,
        height = 0.4,
        gp = vl_gpar(fill = "seagreen")
      )),
    text = vl_scene(4, 3, dpi = 96, bg = "white") |>
      draw(text_grob(
        "vellum gate",
        x = 0.5,
        y = 0.5,
        gp = vl_gpar(fontsize = 24)
      )),
    grad = vl_scene(4, 3, dpi = 96, bg = "white") |>
      draw(rect_grob(
        x = 0.5,
        y = 0.5,
        width = 0.8,
        height = 0.6,
        gp = vl_gpar(fill = linear_gradient(c("tomato", "gold")))
      )),
    circles = vl_scene(4, 3, dpi = 96, bg = "white") |>
      draw(circle_grob(
        runif(15),
        runif(15),
        r = vl_unit(6, "mm"),
        gp = vl_gpar(fill = "orchid", col = NA)
      )),
    sector = vl_scene(4, 3, dpi = 96, bg = "white") |>
      draw(sector_grob(
        0.5,
        0.5,
        r0 = 0,
        r1 = 0.3,
        theta0 = 0,
        theta1 = 2,
        fill = "goldenrod"
      )),
    sketchy = vl_scene(4, 3, dpi = 96, bg = "white") |>
      draw(rect_grob(
        x = 0.5,
        y = 0.5,
        width = 0.6,
        height = 0.5,
        gp = vl_gpar(fill = "skyblue"),
        sketch = sketch(seed = 7)
      )),
    stroke = vl_scene(4, 3, dpi = 96, bg = "white") |>
      draw(stroke_to_path(
        lines_grob(
          c(0.1, 0.4, 0.7, 0.9),
          c(0.2, 0.8, 0.2, 0.7),
          gp = vl_gpar(col = "navy", lwd = 10)
        ),
        width = 4,
        height = 3
      ))
  )
}

# --- render mode --------------------------------------------------------------
#
# Called back into by the driver, once per side, because only one build of the
# package can be loaded per process.
if (identical(ref, "--render")) {
  lib <- args[[2]]
  out <- args[[3]]
  library(vellum, lib.loc = lib)
  dir.create(out, recursive = TRUE, showWarnings = FALSE)
  scenes <- gate_scenes()
  for (nm in names(scenes)) {
    s <- scenes[[nm]]
    for (ext in c("png", "svg", "pdf")) {
      render(s, file.path(out, paste0(nm, ".", ext)))
    }
    # The raster separately from the PNG: this is the geometry the rasterizer
    # produced, with no encoder in the way, so a diff here is unambiguous.
    r <- scene_raster(s)
    con <- file(file.path(out, paste0(nm, ".raster")), "wb")
    writeBin(c(dim(r), as.integer(r)), con)
    close(con)
  }
  cat("rendered", length(scenes), "scenes\n")
  quit(status = 0)
}

# --- driver -------------------------------------------------------------------

say <- function(...) cat(..., "\n", sep = "")

# The baseline worktree must go even on a failure path. `on.exit()` is no help
# here: at top level in a script it is not reliably run, and `quit()` skips it
# outright -- so every exit goes through `done()`.
base_src <- NULL
cleanup <- function() {
  if (!is.null(base_src) && dir.exists(base_src)) {
    system2(
      "git",
      c("worktree", "remove", base_src, "--force"),
      stdout = FALSE,
      stderr = FALSE
    )
  }
}
done <- function(status) {
  cleanup()
  quit(status = status)
}
fail <- function(...) {
  say("ERROR: ", ...)
  done(2)
}

if (!file.exists("DESCRIPTION")) {
  fail("run this from the package root")
}
rscript <- file.path(R.home("bin"), "Rscript")
here <- normalizePath(".")
dir.create(work, recursive = TRUE, showWarnings = FALSE)
work <- normalizePath(work)
say("byte gate: working tree vs '", ref, "'")
say("work dir: ", work)

base_src <- file.path(work, "baseline")
libs <- c(
  head = file.path(work, "lib-head"),
  base = file.path(work, "lib-base")
)
for (d in libs) {
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
}

# The baseline is a detached worktree of `ref`, so an uncommitted working tree
# is compared against a clean checkout rather than against itself.
if (
  system2(
    "git",
    c("worktree", "add", "--detach", base_src, ref),
    stdout = FALSE,
    stderr = FALSE
  ) !=
    0L
) {
  fail("could not create a worktree for '", ref, "'")
}

install <- function(src, lib, label) {
  say("installing ", label, " (compiles Rust, this is the slow part)")
  log <- file.path(work, paste0("install-", label, ".log"))
  ok <- system2(
    file.path(R.home("bin"), "R"),
    c("CMD", "INSTALL", paste0("--library=", lib), src),
    stdout = log,
    stderr = log
  )
  if (ok != 0L) fail("install of ", label, " failed; see ", log)
}
install(here, libs[["head"]], "head")
install(base_src, libs[["base"]], "base")

render_side <- function(lib, out, label) {
  say("rendering ", label)
  log <- file.path(work, paste0("render-", label, ".log"))
  ok <- system2(
    rscript,
    c(file.path(here, "tools/byte-gate.R"), "--render", lib, out),
    stdout = log,
    stderr = log
  )
  if (ok != 0L) fail("render of ", label, " failed; see ", log)
}
out <- c(head = file.path(work, "out-head"), base = file.path(work, "out-base"))
render_side(libs[["head"]], out[["head"]], "head")
render_side(libs[["base"]], out[["base"]], "base")

files <- sort(basename(list.files(out[["base"]])))
if (!length(files)) {
  fail("the baseline rendered nothing")
}
diffs <- character()
for (f in files) {
  a <- file.path(out[["base"]], f)
  b <- file.path(out[["head"]], f)
  same <- file.exists(b) &&
    identical(tools::md5sum(a)[[1]], tools::md5sum(b)[[1]])
  if (!same) diffs <- c(diffs, f)
}

say("")
say(
  "compared ",
  length(files),
  " artifacts (",
  length(files) / 4,
  " scenes x png/svg/pdf/raster)"
)
if (!length(diffs)) {
  say("PASS - byte-for-byte identical to '", ref, "'")
  done(0)
}
say("DIFF in ", length(diffs), ":")
for (d in diffs) {
  say("  ", d)
}
say("")
say("Renders kept for inspection:")
say("  baseline: ", out[["base"]])
say("  head:     ", out[["head"]])
say("")
say("A diff is not automatically a bug -- but it must be intended and stated.")
done(1)
