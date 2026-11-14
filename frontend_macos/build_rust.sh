#!/bin/bash
# Builds libsnow_ffi.a for the architectures Xcode is building and puts it in
# $BUILT_PRODUCTS_DIR, where the app target links it from. Then regenerates the
# UniFFI Swift bindings in Snow/Generated.
#
# Run by the "Build Rust core" phase of Snow.xcodeproj. Can also be run by hand
# with BUILT_PRODUCTS_DIR and ARCHS set.
#
# The core is built optimized even for Debug builds of the app, as an unoptimized
# emulator is too slow to use. Set SNOW_RUST_PROFILE=dev to build it unoptimized.

set -euo pipefail

# Xcode runs build phases without the user's shell profile
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v cargo >/dev/null; then
    echo "error: cargo not found. Install Rust from https://rustup.rs" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE="${SNOW_RUST_PROFILE:-release}"
OUT_DIR="${BUILT_PRODUCTS_DIR:?BUILT_PRODUCTS_DIR must be set}"
# Keep Rust's build output out of the workspace's target/ so building the egui
# frontend and the Xcode project don't invalidate each other's caches.
export CARGO_TARGET_DIR="${SNOW_CARGO_TARGET_DIR:-$WORKSPACE_DIR/target/xcode}"

# Xcode exports MACOSX_DEPLOYMENT_TARGET and SDKROOT, which rustc and the C
# compilers of build scripts use as well. Keep SDKROOT: Xcode's clang finds the
# macOS headers through it.

case "$PROFILE" in
    dev) PROFILE_DIR=debug ;;
    *) PROFILE_DIR="$PROFILE" ;;
esac

LIBS=()
for ARCH in ${ARCHS:-$(uname -m)}; do
    case "$ARCH" in
        arm64) TRIPLE=aarch64-apple-darwin ;;
        x86_64) TRIPLE=x86_64-apple-darwin ;;
        *)
            echo "error: unsupported architecture $ARCH" >&2
            exit 1
            ;;
    esac

    if command -v rustup >/dev/null; then
        (cd "$WORKSPACE_DIR" && rustup target add "$TRIPLE" >/dev/null)
    fi

    (cd "$WORKSPACE_DIR" && cargo build -p snow_ffi --profile "$PROFILE" --target "$TRIPLE")
    LIBS+=("$CARGO_TARGET_DIR/$TRIPLE/$PROFILE_DIR/libsnow_ffi.a")
done

mkdir -p "$OUT_DIR"
if [ "${#LIBS[@]}" -eq 1 ]; then
    cp -f "${LIBS[0]}" "$OUT_DIR/libsnow_ffi.a"
else
    lipo -create "${LIBS[@]}" -output "$OUT_DIR/libsnow_ffi.a"
fi

# Generate the Swift bindings from the library. They are the same for every
# architecture. Files are only replaced when they change, so Swift isn't recompiled
# needlessly.
GENERATED_DIR="$SCRIPT_DIR/Snow/Generated"
GEN_TMP="$(mktemp -d)"
trap 'rm -rf "$GEN_TMP"' EXIT
(cd "$WORKSPACE_DIR" && cargo run -q -p uniffi-bindgen --profile "$PROFILE" -- \
    generate --library "${LIBS[0]}" --language swift --out-dir "$GEN_TMP")
mkdir -p "$GENERATED_DIR"
# The header is used as the bridging header, so the module map isn't needed
for FILE in snow_ffi.swift snow_ffiFFI.h; do
    if ! cmp -s "$GEN_TMP/$FILE" "$GENERATED_DIR/$FILE"; then
        cp -f "$GEN_TMP/$FILE" "$GENERATED_DIR/$FILE"
    fi
done
