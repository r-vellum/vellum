# Boolean operation over two sets of closed rings.

Boolean operation over two sets of closed rings.

## Usage

``` r
rs_path_op(ax, ay, anper, bx, by, bnper, op, even_odd)
```

## Arguments

- ax, ay, anper, bx, by, bnper:

  Flat ring coordinates and per-ring lengths.

- op:

  0 union, 1 intersect, 2 difference, 3 xor.

- even_odd:

  Interpret the inputs with the even-odd rule.

## Value

List of `x`, `y`, `nper`.
