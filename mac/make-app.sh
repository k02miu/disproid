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

# ad-hoc 署名（TCC 許可の安定化のため。リソース .bundle はコードでないため --deep は使わない）
echo "==> ad-hoc 署名"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "(署名スキップ)"

echo "==> 完成: $HERE/$APP"
echo "起動: open \"$HERE/$APP\""
echo "初回は システム設定 > プライバシーとセキュリティ > 画面収録 で Disproid Helper を許可してください。"
