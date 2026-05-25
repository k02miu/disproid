# Disproid Receiver (Android) — Phase C

Android タブレットを Mac のワイヤレス拡張ディスプレイにするための **AirPlay 受信機アプリ**。
自分を **Apple TV（`AppleTV3,2`）として mDNS 公開**し、macOS の画面ミラーリング一覧に Apple TV 種別で出現する。
接続が来ると **UxPlay 由来のネイティブ AirPlay コア**が RTSP/ペアリングを処理し、受信した H.264 を **MediaCodec → Surface** で全画面表示する。

> **フェーズ全体像**
> - **Phase A（完了）**: プロジェクト骨組み + Apple TV としての mDNS 公開（発見・列挙）。
> - **Phase B（完了）**: ネイティブ AirPlay コアのビルド基盤 + 接続確立（ペアリング/RTSP）。
> - **Phase C（このフェーズ）**: `video_process`(H.264 Annex-B) → MediaCodec → Surface で**画面を全画面表示**。
>   音声は未対応（`audio_process` はログのみ）。
> - **Phase D（次）**: 音声（AudioTrack）、拡張ディスプレイ最適化（解像度ネゴ・回転・遅延・安定化）、H.265。

## ⚠️ ライセンス注意

ネイティブコアは **UxPlay**（リポジトリ全体は **GPLv3**、`lib/` ヘッダは LGPL2.1）を vendoring・移植している。
このコードをリンクするため、**本アプリの配布物は GPLv3 の制約**（ソース公開義務等）を受ける。クローズド配布を予定する場合は要検討。

## アーキテクチャ

```
Kotlin (アプリシェル)                    Native (libdisproid.so)
─────────────────────────              ──────────────────────────────
MainActivity ── 開始/停止 UI
AdvertiseService (FGS)
  ├ NativeAirPlay.nativeStart() ──JNI──▶ jni_bridge.c
  │     └ port / pk を取得                  ├ raop_init / raop_init2(ed25519生成)
  ├ NsdManager で _airplay._tcp 公開         ├ raop_start_httpd → listen port
  │   (TXT の pk/features を /info と一致)    ├ dnssd_android.c (TXT/識別子保持)
  └ video/audio_process (Phase C で描画)◀──── └ UxPlay airplay コア (RTSP/ペアリング/FairPlay/RTP)
                                                  └ 依存: libplist(同梱ビルド) / libcrypto(prebuilt)
```

- **mDNS 登録**は Kotlin(`NsdManager`)。ネイティブの `dnssd.c`(mDNSResponder 依存)は使わず、
  データ保持＋TXT 生成だけの `dnssd_android.c` に差し替えている。
- **映像表示部**(`renderers/`, GStreamer)は移植せず、`video_process`/`audio_process` コールバックで
  受け取ったエンコード済みフレームを Phase C で MediaCodec/AudioTrack に流す。

## ビルド環境

- JDK 17（Android Studio 同梱 JBR でよい）
- Android SDK（compileSdk/targetSdk 34, build-tools 34.0.0）
- **NDK 27.2.12479018 + CMake 3.22.1**（`sdkmanager` で導入）
- Gradle 8.10（Wrapper 同梱）/ AGP 8.6.1 / Kotlin 1.9.25
- 対象 ABI は当面 **arm64-v8a のみ**（Lenovo Yoga Pad Pro）

`local.properties` に SDK パスが必要（git 管理外）:

```properties
sdk.dir=/Users/<you>/Library/Android/sdk
```

### 前提: NDK / CMake の導入

```bash
SDKM=~/Library/Android/sdk/cmdline-tools/latest/bin/sdkmanager
yes | "$SDKM" --install "ndk;27.2.12479018" "cmake;3.22.1"
```

### 前提: OpenSSL(libcrypto) のクロスコンパイル（初回のみ）

OpenSSL の prebuilt は容量が大きいため git 管理外。初回ビルド前に 1 度だけ生成する:

```bash
cd android/native-deps
bash build-openssl-android.sh
# → app/src/main/cpp/prebuilt/openssl/{include, lib/arm64-v8a/libcrypto.a} が生成される
```

> libplist は autotools を使わず、vendoring 済みソースを CMake で直接ビルドするため追加手順は不要。

## ビルド

```bash
cd android
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew :app:assembleDebug
# APK: app/build/outputs/apk/debug/app-debug.apk
# CMake が libplist/airplay/JNI をコンパイルし libdisproid.so にリンクする
```

## 実機インストール

```bash
adb devices
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## 動作確認手順

1. タブレットと Mac を **同じ Wi-Fi（同一サブネット）** に接続。
2. アプリ起動 →「公開を開始」。状態に `公開中: … model=AppleTV3,2` が出る。
3. **Mac 側**:
   - `dns-sd -B _airplay._tcp` に "Disproid Receiver" が出る。
   - コントロールセンター → 画面ミラーリングに **Apple TV 種別**で出現。
4. **接続**: 一覧から選ぶとペアリング→ミラーリングが始まり、**全画面 MirrorActivity に Mac の画面が表示**される。
   - 自動で前面に来ない場合（バックグラウンド起動制限）は、**通知をタップ**して開く。
   - ログ確認:
     ```bash
     adb logcat -s DisproidNative DisproidReceiver
     # 例: "video_set_codec=1", "MediaCodec(video/avc) 構成: 1xxx x ...", "mirror_video_running=1"
     ```
5. 「停止」で raop 停止 + mDNS 公開解除。

> Phase C の到達点は「Mac の画面がタブレットに映る」こと（音声は Phase D）。

## ネイティブ構成

```
app/src/main/cpp/
  CMakeLists.txt              # libplist + airplay + JNI を libdisproid.so にリンク
  jni_bridge.c                # JNI: raop 起動/停止、コールバック(現状ログ)、pk 取り出し
  airplay/                    # UxPlay lib/ を vendoring(renderers除外)
    dnssd_android.c           #   mDNSResponder 依存の dnssd.c を Android 用に差し替え
    llhttp/  playfair/        #   HTTP パーサ / FairPlay
  third_party/libplist/       # libplist(依存ゼロ, CMake 直ビルド) + 手書き config.h
  prebuilt/openssl/           # libcrypto.a + headers(スクリプトで生成, git管理外)
native-deps/
  build-openssl-android.sh    # OpenSSL クロスコンパイル
  src/                        # openssl/libplist の clone(git管理外)
```

## 要検証（実機・次フェーズ）

- ペアリングフロー（`check_register`/`register_client`/`report_client_request`）の正否
- `srcvers=220.68`(legacy) で拡張表示まで到達できるか
- ed25519 鍵の永続化（`filesDir/airplay_ed25519.key`）と再ペアリング挙動
- FGS タイプ `connectedDevice` の妥当性

## スコープ外（Phase C 以降）

- `video_process`/`audio_process` の実描画（MediaCodec + Surface / AudioTrack）
- 拡張ディスプレイの解像度ネゴシエーション・回転・遅延最適化
