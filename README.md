# disproid

macOS の非公開 API `CGVirtualDisplay`（CoreGraphics）を使って、**仮想ディスプレイを 1 枚生成する CLI ツール**。

生成された仮想ディスプレイは System Settings > Displays に追加ディスプレイとして現れ、実ディスプレイと同様にウィンドウをドラッグして移動できる。仮想ディスプレイはプロセス生存中のみ存在し、`Ctrl-C` で破棄してクリーンに終了する。

> このリポジトリは「Android タブレットを Mac の拡張ディスプレイにする」構想のうち **macOS 側ヘルパーの仮想ディスプレイ生成部分のみ** を担当する。
> 仮想ディスプレイを macOS 標準の AirPlay ミラーリングで Android 受信機へ送ることで、ユーザー体験上は拡張ディスプレイになる、という設計。
> AirPlay プロトコルやキャプチャ/エンコード/ネットワークはこのリポジトリの範囲外。

## 動作環境

- macOS（Apple Silicon 前提）。**開発・検証は macOS 26.1 / arm64 で実施**。
- Swift 6.x（Swift toolchain は Xcode または Command Line Tools 付属のもの）
- 外部依存ゼロ。システムフレームワーク（CoreGraphics / Foundation）のみ。

> ⚠️ `CGVirtualDisplay` / `CGVirtualDisplayDescriptor` / `CGVirtualDisplayMode` / `CGVirtualDisplaySettings` は
> **公開 SDK に存在しない非公開 API**。本ツールは `Sources/CGVirtualDisplayInterface/include/CGVirtualDisplayInterface.h`
> で Objective-C インターフェースを自前宣言している。これらのシグネチャは実機の Objective-C ランタイムを
> introspection して再現したものだが、macOS のバージョンによっては差異がありうる。ヘッダ内の「要検証」コメントを参照。

## ビルド

```bash
swift build
```

リリースビルド:

```bash
swift build -c release
```

## 実行

```bash
# デフォルト: 1920x1080 @ 60Hz
swift run disproid

# 解像度・リフレッシュレートを指定
swift run disproid --width 1920 --height 1080 --refresh 60

# HiDPI(Retina) として登録（見かけ 1920x1080 / バッキング 3840x2160）
swift run disproid --width 3840 --height 2160 --hidpi

# ビルド済みバイナリを直接実行
.build/debug/disproid --name "My Virtual Display"
```

### オプション

| オプション | 説明 | デフォルト |
| --- | --- | --- |
| `--width W` | モードのピクセル幅 | `1920` |
| `--height H` | モードのピクセル高さ | `1080` |
| `--refresh HZ` | リフレッシュレート (Hz) | `60` |
| `--hidpi` | HiDPI(Retina) として登録。macOS は「見かけ上 幅/2 × 高さ/2」のスケール解像度を提供する | off |
| `--name NAME` | ディスプレイ名 | `Disproid Virtual Display` |
| `-h`, `--help` | ヘルプ表示 | |

> AirPlay 受信は Apple TV 以外だと約 1080p が上限のため、デフォルトを 1920x1080 @ 60Hz にしている。

起動後はプロセスが常駐する。終了するには `Ctrl-C`（SIGINT）を押す。仮想ディスプレイが破棄され、クリーンに終了する。

## 動作確認手順

1. ツールを起動する。
   ```bash
   swift run disproid
   ```
   `displayID` が表示されれば生成成功。

2. **System Settings > Displays** を開く。追加のディスプレイが表示され、配置（Arrangement）でドラッグして位置を変更できることを確認する。

3. 任意のウィンドウを仮想ディスプレイ側へドラッグして移動できることを確認する（実ディスプレイ同様に扱える）。

4. CLI からオンラインディスプレイ一覧でも確認できる。別ターミナルで:
   ```bash
   cat > /tmp/listdisp.swift <<'EOF'
   import CoreGraphics
   var count: UInt32 = 0
   CGGetOnlineDisplayList(0, nil, &count)
   var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
   CGGetOnlineDisplayList(count, &ids, &count)
   for id in ids {
       print("id=\(id) \(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id)) builtin=\(CGDisplayIsBuiltin(id) != 0)")
   }
   EOF
   swift /tmp/listdisp.swift
   ```
   `builtin=false` の新しいディスプレイが一覧に増えていれば成功。

5. `Ctrl-C` で終了し、Displays 設定および上記一覧から仮想ディスプレイが消えることを確認する。

## 構成

```
Package.swift
Sources/
  CGVirtualDisplayInterface/        # 非公開 API の ObjC インターフェース宣言（ヘッダのみ）
    include/
      CGVirtualDisplayInterface.h
      module.modulemap
    shim.m                          # ヘッダが ObjC としてコンパイル可能かの検証用
  disproid/                         # Swift 実行ターゲット
    main.swift                      # エントリ・引数処理・SIGINT・常駐
    Options.swift                   # CLI 引数パーサ
    VirtualDisplay.swift            # CGVirtualDisplay ラッパー
```

## スコープ外

- AirPlay プロトコルの実装
- 画面キャプチャ / エンコード / ネットワーク送信 / ScreenCaptureKit
- Android 受信機アプリ

ミラーリングは macOS 標準の AirPlay 機能に任せる設計のため、本ツールは仮想ディスプレイの生成のみを行う。
