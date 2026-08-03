# Packed `0xRRGGBBAA` colours to Oklab, optionally as a viewer with a colour-vision deficiency would see them.

One call answers both halves of "are these two colours distinct to
everyone": pass `kind = ""` for normal vision and a deficiency name for
the simulated view, then compare distances in the same perceptual space.
It reuses the render path's own matrices, so the linter cannot drift
from what `render(cvd = )` draws.

## Usage

``` r
rs_cvd_oklab(cols, kind)
```

## Arguments

- cols:

  Packed colours as doubles (0xRRGGBBAA).

- kind:

  A deficiency name, or "" for no simulation.

## Value

Flattened `L, a, b` triples, three doubles per colour.
