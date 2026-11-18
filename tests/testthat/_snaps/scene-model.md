# incompatible label/x/y lengths fail with a clear error

    Code
      text_grob(c("a", "b", "c"), x = c(0.1, 0.2))
    Condition
      Error in `text_grob()`:
      ! `label`, `x`, and `y` must have compatible lengths.
      i Each must be length 1 or a common length.
      x `label`, `x`, and `y` have lengths 3, 2, and 1.

# a key or meta of the wrong length is an error, not truncated

    Code
      rect_grob(y = c(0.2, 0.8), key = letters[1:3])
    Condition
      Error in `rect_grob()`:
      ! `key` must have length 1 or 2 (one per element), not 3.
      i This grob draws 2 elements.

