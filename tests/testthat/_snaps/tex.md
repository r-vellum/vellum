# parse errors name the problem and its position

    Code
      tex("a + \\foo + b")
    Condition
      Error in `tex()`:
      ! Can't parse the `tex()` formula.
      x Unknown command `\foo` at position 5.
      i In `a + \foo + b`.
    Code
      tex("\\frac{a}")
    Condition
      Error in `tex()`:
      ! Can't parse the `tex()` formula.
      x Missing argument for `\frac` at the end of the formula.
      i In `\frac{a}`.
    Code
      tex("x^")
    Condition
      Error in `tex()`:
      ! Can't parse the `tex()` formula.
      x Missing argument for `^` at the end of the formula.
      i In `x^`.
    Code
      tex("\\left( x")
    Condition
      Error in `tex()`:
      ! Can't parse the `tex()` formula.
      x `\left` without a matching `\right` at the end of the formula.
      i In `\left( x`.
    Code
      tex("{a")
    Condition
      Error in `tex()`:
      ! Can't parse the `tex()` formula.
      x Missing closing brace `}` at the end of the formula.
      i In `{a`.

