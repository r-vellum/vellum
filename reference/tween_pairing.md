# How each adjacent keyframe pair will tween, for a caller that wants to warn before rendering. One entry per pair `(i, i + 1)`:

- `paired` – the keyframes tween node by node (`FALSE`: the frames cut
  from one keyframe to the next at the midpoint);

- `nodes_a`, `nodes_b` – the two node counts;

- `snapped` – for a paired segment, how many node pairs still switch
  whole at the midpoint (a different variant, vertex count or unkeyed
  element count); `NA` for an unpaired one.

## Usage

``` r
tween_pairing(keyframes)
```
