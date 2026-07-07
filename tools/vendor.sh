#!/usr/bin/env sh
# Regenerate the vendored Rust crate tree and repack the committed tarball in one
# step, so `src/rust/vendor.tar.xz` can never drift from `src/rust/Cargo.lock` by
# hand. Run from anywhere after changing `src/rust/Cargo.toml` / `Cargo.lock`.
#
# It vendors against the EXISTING Cargo.lock (it does not update dependencies).
# To upgrade a crate first bump `Cargo.toml` and run `cargo update` yourself, then
# run this. See tools/UPGRADING-crates.md.
set -eu

PKG_ROOT=$(cd "$(dirname "$0")/.." && pwd)
RUST_DIR="$PKG_ROOT/src/rust"

command -v cargo >/dev/null 2>&1 || { echo "error: cargo not found on PATH" >&2; exit 1; }
command -v xz    >/dev/null 2>&1 || { echo "error: xz not found on PATH (needed to pack vendor.tar.xz)" >&2; exit 1; }
[ -f "$RUST_DIR/Cargo.lock" ] || { echo "error: $RUST_DIR/Cargo.lock missing; run 'cargo generate-lockfile' first" >&2; exit 1; }

echo "== vendoring crates into src/rust/vendor (from the committed Cargo.lock) =="
rm -rf "$RUST_DIR/vendor"
# No --versioned-dirs: keep cargo's default layout (only duplicate majors get a
# version suffix), matching the committed tarball.
cargo vendor --locked --manifest-path "$RUST_DIR/Cargo.toml" "$RUST_DIR/vendor" >/dev/null

echo "== packing src/rust/vendor.tar.xz (top-level 'vendor/') =="
tar cJf "$RUST_DIR/vendor.tar.xz" -C "$RUST_DIR" vendor

echo "== removing the working vendor dir (git-ignored; rebuilt on demand) =="
rm -rf "$RUST_DIR/vendor"

echo
echo "done. Sanity-check the source config still matches vendor-config.toml, then"
echo "commit src/rust/Cargo.lock and src/rust/vendor.tar.xz together."
