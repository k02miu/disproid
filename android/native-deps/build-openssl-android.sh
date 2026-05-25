#!/usr/bin/env bash
#
# OpenSSL(libcrypto) を Android(arm64-v8a) 向けにクロスコンパイルし、
# app/src/main/cpp/prebuilt/openssl/ に headers と libcrypto.a を配置する。
#
# UxPlay の airplay コア（lib/crypto.c, pairing.c, srp.c, fairplay_playfair.c）が
# libcrypto に依存するため。libssl は不要。
#
# macOS / Linux(CI) 両対応。OpenSSL ソースが無ければ自動 clone する。
#
set -euo pipefail

NDK="${ANDROID_NDK_ROOT:-$HOME/Library/Android/sdk/ndk/27.2.12479018}"
ABI="arm64-v8a"
API=26
OPENSSL_TAG="openssl-3.3.2"

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/openssl"
OUT="$HERE/../app/src/main/cpp/prebuilt/openssl"

# ホスト OS に応じた NDK ツールチェーンの prebuilt ディレクトリ
case "$(uname -s)" in
    Darwin) HOST_TAG="darwin-x86_64" ;;
    Linux)  HOST_TAG="linux-x86_64" ;;
    *) echo "未対応のホスト OS: $(uname -s)" >&2; exit 1 ;;
esac

# 並列数
if command -v nproc >/dev/null 2>&1; then
    JOBS="$(nproc)"
else
    JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
fi

export ANDROID_NDK_ROOT="$NDK"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
export PATH="$TOOLCHAIN/bin:$PATH"

# OpenSSL ソースが無ければ取得
if [ ! -f "$SRC/Configure" ]; then
    echo "OpenSSL ソースを取得 ($OPENSSL_TAG) ..."
    mkdir -p "$HERE/src"
    git clone --depth 1 --branch "$OPENSSL_TAG" https://github.com/openssl/openssl.git "$SRC"
fi

cd "$SRC"
make clean >/dev/null 2>&1 || true

# android-arm64 ターゲット。共有ライブラリ・テスト不要。
./Configure android-arm64 -D__ANDROID_API__=$API no-shared no-tests no-asm

make -j"$JOBS" build_libs

mkdir -p "$OUT/include" "$OUT/lib/$ABI"
cp libcrypto.a "$OUT/lib/$ABI/"
rm -rf "$OUT/include/openssl"
cp -R include/openssl "$OUT/include/"

echo "=== DONE ==="
ls -lh "$OUT/lib/$ABI/libcrypto.a"
echo "headers: $OUT/include/openssl ($(ls "$OUT/include/openssl" | wc -l | tr -d ' ') files)"
