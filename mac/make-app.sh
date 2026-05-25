#!/usr/bin/env bash
#
# SwiftPM でビルドした実行ファイルを macOS の .app バンドルに梱包する。
# メニューバー常駐(LSUIElement) + 安定した bundle id で、画面収録(TCC)許可が付くようにする。
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

APP="Disproid Helper.app"
BIN_NAME="disproid-helper"
GLYPH="../disproid.png"   # アプリ/メニューバー共通のグリフ素材

echo "==> release ビルド"
swift build -c release

echo "==> .app 梱包"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
cp "Info.plist" "$APP/Contents/Info.plist"

# SwiftPM のリソースバンドル（メニューバー画像）を Resources へ（Bundle.module が解決可能）
if ls .build/release/*.bundle >/dev/null 2>&1; then
    cp -R .build/release/*.bundle "$APP/Contents/Resources/"
fi

# アプリアイコン(.icns)を glyph から生成
if [ -f "$GLYPH" ]; then
    echo "==> アイコン生成"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for sz in 16 32 128 256 512; do
        sips -z "$sz" "$sz" "$GLYPH" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null 2>&1
        sips -z "$((sz * 2))" "$((sz * 2))" "$GLYPH" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || echo "(icns 生成スキップ)"
fi

# 署名（リソース .bundle はコードでないため --deep は使わない）
# 自己署名証明書(make-cert.sh)があればそれで署名 → 再ビルドしても画面収録の許可が維持される。
# 無ければ ad-hoc（毎回許可リセットされる）。
CERT_NAME="Disproid Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -q "${CERT_NAME}"; then
    echo "==> sign with cert: ${CERT_NAME}"
    codesign --force --sign "${CERT_NAME}" "$APP" >/dev/null 2>&1 || echo "(sign failed)"
else
    echo "==> ad-hoc sign (no self-signed cert; run make-cert.sh)"
    codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "(sign skipped)"
fi

echo "==> 完成: $HERE/$APP"
echo "起動: open \"$HERE/$APP\""
echo "初回は システム設定 > プライバシーとセキュリティ > 画面収録 で Disproid Helper を許可してください。"
