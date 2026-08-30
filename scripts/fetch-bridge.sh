#!/usr/bin/env bash
# Download the standalone cursor-sdk-bridge for this machine.
# Pins to the sdk.v1 release vendored under vendor/sdk-bridge.
set -euo pipefail

VERSION="${1:-1.0.30}"

case "$(uname -s)" in
  Linux) OS=linux ;;
  Darwin) OS=darwin ;;
  MINGW* | MSYS* | CYGWIN*) OS=win32 ;;
  *)
    echo "unsupported OS: $(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64 | amd64) ARCH=x64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *)
    echo "unsupported arch: $(uname -m)" >&2
    exit 1
    ;;
esac

ASSET="cursor-sdk-bridge-standalone-${OS}-${ARCH}.tar.gz"
URL="https://github.com/cursor/sdk-bridge/releases/download/v${VERSION#v}/${ASSET}"

echo "Downloading ${URL}"
if ! curl -fSL -o "$ASSET" "$URL"; then
  if command -v gh > /dev/null 2>&1; then
    echo "curl download failed; retrying with gh" >&2
    gh release download "v${VERSION#v}" \
      --repo cursor/sdk-bridge --pattern "$ASSET" --output "$ASSET" --clobber
  else
    echo "download failed" >&2
    exit 1
  fi
fi

rm -rf cursor-sdk-bridge
mkdir cursor-sdk-bridge
tar -xzf "$ASSET" -C cursor-sdk-bridge
rm "$ASSET"

echo "Bridge unpacked. Manifest:"
cat cursor-sdk-bridge/manifest.json
echo "Executable: ./cursor-sdk-bridge/bin/cursor-sdk-bridge"
