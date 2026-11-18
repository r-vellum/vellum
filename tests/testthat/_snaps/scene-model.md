# incompatible label/x/y lengths fail with a clear error

    Code
      text_grob(c("a", "b", "c"), x = c(0.1, 0.2))
    Condition
      Error in `text_grob()`:
      ! `label`, `x`, and `y` must have compatible lengths.
      i Each must be length 1 or a common length.
      x `label`, `x`, and `y` have lengths 3, 2, and 1.

