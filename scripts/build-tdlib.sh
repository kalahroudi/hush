#!/bin/bash
# Builds a self-contained libtdjson.dylib (Telegram's TDLib with OpenSSL linked in) for Apple silicon.
# Hush downloads the result from the `tdlib-*` GitHub release, so users never build it themselves.
# Usage: scripts/build-tdlib.sh [outdir]      Needs: cmake, gperf, openssl (brew install cmake gperf openssl@3)
set -euo pipefail

TD_COMMIT="0e88653dcbf4e44c73cb655a05b58cd749a91169"
TD_VERSION="1.8.69"
OUT="$(cd "${1:-dist}" 2>/dev/null && pwd || (mkdir -p "${1:-dist}" && cd "${1:-dist}" && pwd))"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SSL="$(brew --prefix openssl@3 2>/dev/null || true)"
[ -d "$SSL" ] || SSL="$(brew --prefix openssl)"
[ -d "$SSL" ] || { echo "OpenSSL not found. Run: brew install openssl@3" >&2; exit 1; }

git clone --quiet https://github.com/tdlib/td.git "$WORK/td"
git -C "$WORK/td" checkout --quiet "$TD_COMMIT"
mkdir "$WORK/td/build"
cd "$WORK/td/build"
cmake -DCMAKE_BUILD_TYPE=Release -DOPENSSL_ROOT_DIR="$SSL" -DOPENSSL_USE_STATIC_LIBS=ON \
      -DCMAKE_INSTALL_PREFIX="$WORK/install" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 ..
cmake --build . --target install -j"$(sysctl -n hw.ncpu)"

LIB="$WORK/install/lib/libtdjson.dylib"
install_name_tool -id "@rpath/libtdjson.dylib" "$LIB"
if otool -L "$LIB" | grep -qE "/opt/homebrew|/usr/local"; then
  echo "The library still links against Homebrew paths:" >&2; otool -L "$LIB" >&2; exit 1
fi
strip -x "$LIB"
codesign --force --sign - "$LIB"

NAME="libtdjson-$TD_VERSION-macos-arm64"
mkdir -p "$WORK/$NAME" && cp "$LIB" "$WORK/$NAME/libtdjson.dylib"
tar -C "$WORK" -czf "$OUT/$NAME.tar.gz" "$NAME"
(cd "$OUT" && shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
echo "Built $OUT/$NAME.tar.gz"
