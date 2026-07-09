# Upgrading the vendored Rust crates

vellum's Rust backend is built from crates **vendored** into the package so the
build is fully offline (a CRAN requirement) and reproducible. The vendored tree
is not in git; only the packed tarball and the lockfile are:

- `src/rust/Cargo.toml` — the direct dependencies and their version constraints.
- `src/rust/Cargo.lock` — the exact resolved versions (committed).
- `src/rust/vendor.tar.xz` — the vendored source of every crate in the lock
  (committed; top-level directory is `vendor/`).
- `src/rust/vendor-config.toml` — the cargo source-replacement config the build
  copies into `CARGO_HOME` so cargo reads from `vendor/` instead of crates.io.
- `src/rust/vendor/` — the unpacked tree; **git-ignored**, produced from the
  tarball at build time or by `tools/vendor.sh` locally.

The build wiring lives in `src/Makevars.in`: if `./vendor` exists it is used
directly, otherwise `rust/vendor.tar.xz` is extracted. So `Cargo.lock` and
`vendor.tar.xz` **must always agree** — that is the one invariant to protect.

## MSRV is a single source of truth

The minimum Rust version is declared once, in `DESCRIPTION`:

```
SystemRequirements: Cargo (Rust's package manager), rustc >= 1.92.0, xz
```

`tools/msrv.R` parses that string at configure time and fails the build if the
installed `rustc` is older. `src/rust/Cargo.toml` also carries `rust-version =
'1.92'`. If an upgraded crate needs a newer compiler, bump **both** and note it
in `NEWS.md` — raising the MSRV is a user-visible change.

## The krilla pin

`krilla` is pinned exactly (`=0.8.2`) because its minor releases have made
breaking changes to the PDF API vellum depends on, and 0.8.2 sets the current
MSRV floor. Treat a krilla bump as a deliberate, tested change, not a routine
refresh; re-check the PDF snapshot tests after any bump.

## Procedure

1. **Bump the constraint** in `src/rust/Cargo.toml` (or change a `=`-pin).
2. **Refresh the lockfile**: `cargo update -p <crate>` (targeted) or
   `cargo update` (everything), run against `src/rust/Cargo.toml`.
3. **Re-vendor and repack** in one step:
   ```sh
   tools/vendor.sh
   ```
   This vendors the current `Cargo.lock` into `src/rust/vendor`, packs
   `src/rust/vendor.tar.xz` (top-level `vendor/`), and removes the working dir.
   It never edits the lockfile — so it can't silently drift the versions.
4. **Check the MSRV**: if the new crate needs a newer `rustc`, bump both the
   `DESCRIPTION` `SystemRequirements` string and `Cargo.toml` `rust-version`.
   Note that duplicate major versions are expected in the vendor tree (e.g.
   `skrifa` + `skrifa-0.31.3`); that is normal, not a problem to resolve.
5. **Verify the offline build and tests** across the CI matrix (a Rust compile on
   every OS): `R CMD check`, and specifically the PDF/SVG/raster snapshot tests.
6. **Commit `src/rust/Cargo.lock` and `src/rust/vendor.tar.xz` together** (plus
   the `Cargo.toml` / `DESCRIPTION` / `NEWS.md` edits).

## Deferred / future work

- No automated dependency updates for the Rust crate yet (Dependabot/renovate
  cover the R side only). A crate-level updater could be added.
- No CI check that `vendor.tar.xz` matches `Cargo.lock`. A cheap guard would run
  `tools/vendor.sh`, then fail if `git status --porcelain src/rust/vendor.tar.xz`
  is dirty — the same pattern the vellumwidget bundle-sync job uses. (Note xz output is
  not guaranteed byte-identical across `xz` versions, so such a check should
  compare the extracted tree, not the tarball bytes.)
