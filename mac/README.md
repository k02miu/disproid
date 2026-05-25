# Disproid Helper (Mac) — 開発者向け

Mac の仮想ディスプレイをキャプチャし、USB(adb) 経由で Android タブレットへ送る **メニューバー常駐アプリ**。
有線（USB）モードの送信側。利用者向けの使い方はリポジトリ直下の [`../README.md`](../README.md) を参照。

## アーキテクチャ

```
仮想ディスプレイ(CGVirtualDisplay)
  → ScreenCaptureKit でキャプチャ
  → VideoToolbox で H.264 エンコード(Annex-B, 低遅延設定)
  → FrameServer(TCP, localhost) でフレーミング送信
  → adb reverse tcp:27184 で USB トンネル
  → Android(UsbVideoReceiver → MediaCodec → Surface)
```

- 送信プロトコル: ヘッダ(`DPRD`+ver+codec+width+height) + 以降 `length(4,BE)+Annex-B` の繰り返し。
- 低遅延化: TCP Nagle 無効 / VideoToolbox 低遅延レート制御・MaxFrameDelayCount=0。
- 輻輳制御: 送信が詰まったら**エンコード前**にキャプチャを間引く（圧縮ストリーム非破壊）。Android 側はドロップしない。

主なソース（`Sources/disproid-helper/`）:
- `App.swift` … SwiftUI `MenuBarExtra` の UI
- `StreamEngine.swift` … パイプライン全体の管理（ObservableObject）
- `VirtualDisplay.swift` / `CGVirtualDisplayInterface` … 非公開 CGVirtualDisplay の宣言と生成
- `ScreenCapturer.swift` / `VideoEncoder.swift` / `FrameServer.swift` / `AdbBridge.swift`

## 必要なもの

- macOS 13+（Apple Silicon で検証）、Swift toolchain（Xcode 同梱でよい）
- `adb`（Android platform-tools）— `ANDROID_HOME` or PATH から自動検出
- 実行時に **画面収録（Screen Recording）の許可**（TCC）が必要

## ビルド & 実行

```bash
cd mac
bash make-app.sh                 # swift build -c release → .app 梱包 → ad-hoc 署名
open "Disproid Helper.app"       # メニューバーに常駐
```

開発中は `swift build` でコンパイル確認のみも可（ただし TCC 許可はバンドル単位なので、
実動作確認は `.app` を起動して行うのが確実）。

初回起動時、**システム設定 → プライバシーとセキュリティ → 画面収録** で「Disproid Helper」を ON にする。

## 署名・公証について

現状は **ad-hoc 署名**（`codesign --sign -`、無料）。自分の Mac で動かす分には十分だが、
配布して他者がダウンロードすると Gatekeeper が「開発元を確認できません」と警告する
（**右クリック → 開く** で起動は可能）。

警告を完全に無くす（=正式配布）には Apple の有料 **Developer Program** が必要:

1. **Developer ID Application 証明書**でアプリ署名（`codesign --sign "Developer ID Application: …" --options runtime`）
2. **公証（notarization）**: `xcrun notarytool submit … --apple-id … --team-id … --password <app固有パスワード>` → `xcrun stapler staple`
3. CI で行う場合は、証明書(.p12) と Apple ID/Team ID/app固有パスワードを **GitHub Secrets** に入れ、
   macOS ジョブで keychain インポート → 署名 → 公証 → staple、というステップを追加する。

> 現時点では個人利用想定のため ad-hoc のまま。配布を本格化する段階で上記を導入する。

## TODO

- 音声送信（Android 側 AudioTrack とセット）
- 実画面ミラー（仮想ディスプレイではなく既存ディスプレイ）モードの選択
- ビットレート/解像度の動的調整、H.265 オプション
