# How each adjacent keyframe pair will tween, for a caller that wants to warn before rendering. One entry per pair `(i, i + 1)`:

- `paired` – the keyframes can be matched (`FALSE`: they do not share a
  viewport tree, so the frames cut from one to the next at the
  midpoint);

- `nodes_a`, `nodes_b` – the two node counts;

- `snapped` – for a paired segment, how many nodes (or node pairs) still
  switch whole at the midpoint: a matched pair whose variant or vertex
  count differs, or an unkeyed node with no counterpart; `NA` for an
  unpaired one;

- `exited`, `entered` – keyed elements with no partner, which fade out
  or in; `NA` for an unpaired segment.

## Usage

``` r
tween_pairing(keyframes)
```
