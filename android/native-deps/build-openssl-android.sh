#!/usr/bin/env bash
#
# OpenSSL(libcrypto) を Android(arm64-v8a) 向けにクロスコンパイルし、
# app/src/main/cpp/prebuilt/openssl/ に headers と libcrypto.a を配置する。
#
# UxPlay の airplay コア（lib/crypto.c, pairing.c, srp.c, fairplay_playfair.c）が
# libcrypto に依存するため。libssl は不要。
#
set -euo pipefail

NDK="${ANDROID_NDK_ROOT:-$HOME/Library/Android/sdk/ndk/27.2.12479018}"
ABI="arm64-v8a"
API=26

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/openssl"
OUT="$HERE/../app/src/main/cpp/prebuilt/openssl"

export ANDROID_NDK_ROOT="$NDK"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
export PATH="$TOOLCHAIN/bin:$PATH"

cd "$SRC"
make clean >/dev/null 2>&1 || true

# android-arm64 ターゲット。共有ライブラリ・テスト不要。
./Configure android-arm64 -D__ANDROID_API__=$API no-shared no-tests no-asm

make -j"$(sysctl -n hw.ncpu)" build_libs

mkdir -p "$OUT/include" "$OUT/lib/$ABI"
cp libcrypto.a "$OUT/lib/$ABI/"
rm -rf "$OUT/include/openssl"
cp -R include/openssl "$OUT/include/"

echo "=== DONE ==="
ls -lh "$OUT/lib/$ABI/libcrypto.a"
echo "headers: $OUT/include/openssl ($(ls "$OUT/include/openssl" | wc -l | tr -d ' ') files)"
