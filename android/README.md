# Disproid Receiver (Android) — Phase A

Android タブレットを Mac のワイヤレス拡張ディスプレイにするための **AirPlay 受信機アプリ**。
自分を **Apple TV（`AppleTV3,2`）として mDNS 公開**し、macOS の画面ミラーリング一覧に Apple TV 種別のデバイスとして出現させる。

> **Phase A のスコープ**: プロジェクト骨組み + mDNS 公開（発見・列挙されること）まで。
> 接続後の AirPlay プロトコル（ペアリング・FairPlay・暗号・映像デコード）は次フェーズで、本フェーズでは扱わない。
> 接続を試みてもスタブ TCP サーバが何もしないため失敗するのは想定内。

## できること（Phase A）

- フォアグラウンドサービスで mDNS（`NsdManager`）により `_airplay._tcp` を公開（画面オフでも継続）。
- TXT レコードに Apple TV 識別属性（`model=AppleTV3,2` 等）を付与。
- スタブの TCP サーバを listen（接続が来たらログのみ）。

## 公開する TXT レコード

手本は **UxPlay**（`lib/dnssd.c` の `dnssd_register_airplay` / `lib/dnssdint.h` / `lib/global.h`）。
UxPlay は同一 LAN 上で `AppleTV3,2` として macOS に Apple TV 種別で列挙される実績があり、`dns-sd` での on-wire 観測値とも一致する。

| key | 値 | 備考 |
|---|---|---|
| `model` | `AppleTV3,2` | **Apple TV 種別判定の核** |
| `features` | `0x527FFEE6,0x0` | 機能ビットマスク（UxPlay 観測値, legacy pairing OFF） |
| `srcvers` | `220.68` | AirPlay ソースバージョン |
| `flags` | `0x4` | |
| `pw` | `false` | パスワード不要 |
| `vv` | `2` | |
| `deviceid` | ランダム MAC 形式（端末ごとに永続化） | 実 MAC は Android 10+ で取得制限のため生成 |
| `pi` | ランダム UUID（永続化） | デバイス UUID |
| `pk` | ランダム 32byte hex（永続化） | ペアリング前のプレースホルダ |

実装は `AirPlayTxtRecord.kt` / `DeviceIdentity.kt`。`要検証` コメント箇所（features ビット構成、srcvers での拡張可否、deviceid/pk の検証要否、FGS タイプ）は今後の実機検証対象。

## ビルド環境

- JDK 17（Android Studio 同梱 JBR でよい）
- Android SDK（compileSdk/targetSdk 34, build-tools 34.0.0）
- Gradle 8.10（Wrapper 同梱）/ AGP 8.6.1 / Kotlin 1.9.25
- 外部ライブラリ依存ゼロ（AndroidX/Compose 不使用、フレームワーク API のみ）

`local.properties` に SDK パスが必要（git 管理外）:

```properties
sdk.dir=/Users/<you>/Library/Android/sdk
```

## ビルド

```bash
cd android
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew :app:assembleDebug
# APK: app/build/outputs/apk/debug/app-debug.apk
```

## 実機インストール

USB デバッグを有効にしたタブレットを接続:

```bash
adb devices                       # デバイスが見えることを確認
adb install -r app/build/outputs/apk/debug/app-debug.apk
# もしくは
./gradlew :app:installDebug
```

## 動作確認手順

1. タブレットとビルド用 Mac を **同じ Wi-Fi（同一サブネット）** に接続する。
2. アプリを起動し「公開を開始」を押す（通知許可を求められたら許可）。画面に `公開中: …` と表示される。
3. **Mac 側**で確認:
   - `dns-sd` で公開を観測:
     ```bash
     dns-sd -B _airplay._tcp        # 一覧に "Disproid Receiver" が出る
     dns-sd -L "Disproid Receiver" _airplay._tcp local   # TXT に model=AppleTV3,2 を確認
     ```
   - コントロールセンター → 画面ミラーリングに、このタブレットが **Apple TV 種別**で出現する。
4. （想定内）クリックして接続すると、Phase A はスタブのため接続は失敗する。
5. 「停止」またはアプリ終了で公開が消える。

## トラブルシュート

- **一覧に出ない**: タブレットと Mac が同一サブネットか、Wi-Fi の AP 分離（クライアント間通信遮断）が無効か確認。
- **TXT が一部欠ける / サービスタイプが化ける**: `NsdManager` の既知の癖。`AirPlayTxtRecord` はそのままに、登録経路を jmdns へ差し替える（次手・本フェーズの代替案）。
- **FGS が即停止する（API 34+）**: `foregroundServiceType=connectedDevice` と対応権限を確認。

## 構成

```
android/
  settings.gradle.kts / build.gradle.kts / gradle.properties
  app/
    build.gradle.kts
    src/main/AndroidManifest.xml
    src/main/kotlin/io/disproid/receiver/
      MainActivity.kt        # 最小 UI（開始/停止/状態）
      AdvertiseService.kt    # FGS: TCP listen + NsdManager 公開
      AirPlayTxtRecord.kt    # TXT レコード定義（UxPlay 手本）
      DeviceIdentity.kt      # deviceid/pi/pk の生成・永続化
      StatusBus.kt           # サービス→UI の状態通知
    src/main/res/...         # layout / strings
```

## スコープ外（次フェーズ）

- AirPlay プロトコル本体（UxPlay の C/C++ コアを JNI 移植）
- ペアリング / FairPlay / 暗号
- MediaCodec / Surface による映像デコード・表示
