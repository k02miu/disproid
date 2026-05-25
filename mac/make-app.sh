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

echo "==> release ビルド"
swift build -c release

echo "==> .app 梱包"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
cp "Info.plist" "$APP/Contents/Info.plist"

# ad-hoc 署名（TCC 許可の安定化のため）
echo "==> ad-hoc 署名"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "(署名スキップ)"

echo "==> 完成: $HERE/$APP"
echo "起動: open \"$HERE/$APP\"  （メニューバーにアイコンが出ます）"
echo "初回は システム設定 > プライバシーとセキュリティ > 画面収録 で Disproid Helper を許可してください。"
