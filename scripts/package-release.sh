#!/usr/bin/env bash
# Build and package cc + cursor-sdk-bridge for one Zig target.
# Usage: package-release.sh <zig-target> <asset-stem> <tar.gz|zip>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:?zig target}"
ASSET="${2:?asset stem, e.g. cc-linux-x64}"
ARCHIVE="${3:?tar.gz or zip}"
BRIDGE_VERSION="${BRIDGE_VERSION:-1.0.30}"
ZIG="${ZIG:-zig}"

case "$TARGET" in
  x86_64-linux*) BRIDGE_OS=linux; BRIDGE_ARCH=x64 ;;
  aarch64-linux*) BRIDGE_OS=linux; BRIDGE_ARCH=arm64 ;;
  x86_64-macos*) BRIDGE_OS=darwin; BRIDGE_ARCH=x64 ;;
  aarch64-macos*) BRIDGE_OS=darwin; BRIDGE_ARCH=arm64 ;;
  x86_64-windows*) BRIDGE_OS=win32; BRIDGE_ARCH=x64 ;;
  aarch64-windows*) BRIDGE_OS=win32; BRIDGE_ARCH=arm64 ;;
  *)
    echo "unsupported zig target: $TARGET" >&2
    exit 1
    ;;
esac

cd "$ROOT"
"$ZIG" build -Doptimize=ReleaseSafe -Dtarget="$TARGET" -Dcpu=baseline

bin=""
for candidate in zig-out/bin/cc zig-out/bin/cc.exe; do
  if [[ -f "$candidate" ]]; then
    bin="$candidate"
    break
  fi
done
[[ -n "$bin" ]] || { echo "cc binary missing after build" >&2; exit 1; }

bridge_asset="cursor-sdk-bridge-standalone-${BRIDGE_OS}-${BRIDGE_ARCH}.tar.gz"
bridge_url="https://github.com/cursor/sdk-bridge/releases/download/v${BRIDGE_VERSION#v}/${bridge_asset}"
bridge_tar="$(mktemp)"
echo "Downloading ${bridge_url}"
curl -fSL --retry 3 --retry-delay 1 -o "$bridge_tar" "$bridge_url"
bridge_dir="$(mktemp -d)"
tar -xzf "$bridge_tar" -C "$bridge_dir"
rm -f "$bridge_tar"

bridge_bin=""
for candidate in \
  "$bridge_dir/bin/cursor-sdk-bridge" \
  "$bridge_dir/bin/cursor-sdk-bridge.exe" \
  "$bridge_dir/cursor-sdk-bridge/bin/cursor-sdk-bridge" \
  "$bridge_dir/cursor-sdk-bridge/bin/cursor-sdk-bridge.exe"
do
  if [[ -f "$candidate" ]]; then
    bridge_bin="$candidate"
    break
  fi
done
if [[ -z "$bridge_bin" ]]; then
  bridge_bin="$(find "$bridge_dir" -type f \( -name cursor-sdk-bridge -o -name cursor-sdk-bridge.exe \) | head -n 1 || true)"
fi
[[ -n "$bridge_bin" ]] || { echo "bridge binary missing from $bridge_asset" >&2; exit 1; }

pkg="$ROOT/dist/$ASSET"
rm -rf "$pkg"
mkdir -p "$pkg"
cp "$bin" "$pkg/"
cp "$bridge_bin" "$pkg/"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$ROOT/THIRD_PARTY_NOTICES.md" "$pkg/"
rm -rf "$bridge_dir"

mkdir -p "$ROOT/dist"
out="$ROOT/dist/${ASSET}.${ARCHIVE}"
rm -f "$out"
case "$ARCHIVE" in
  tar.gz)
    tar -czf "$out" -C "$pkg" .
    ;;
  zip)
    (cd "$pkg" && zip -qr "$out" .)
    ;;
  *)
    echo "unknown archive type: $ARCHIVE" >&2
    exit 1
    ;;
esac

(cd "$ROOT/dist" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256")
echo "Wrote $out"
