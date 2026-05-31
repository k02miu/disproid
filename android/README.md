# Disproid Receiver (Android) — 開発者向け

Android タブレットを Mac の拡張ディスプレイにするための受信アプリ。3 つの経路で受信できる:

1. **AirPlay（ワイヤレス）**: 自分を **Apple TV として mDNS 公開**し、macOS の画面ミラーリング一覧に出現。
   **UxPlay 由来のネイティブ AirPlay コア**が RTSP/ペアリング/FairPlay を処理（`AdvertiseService`→ネイティブ→`MirrorActivity`）。
2. **USB / adb（有線）**: Mac ヘルパーが `adb reverse` で張ったトンネルへ接続（`UsbVideoReceiver`、localabstract `disproid`）。
3. **USB / AOA（有線・実験的）**: accessory モードで起動し accessory FD を直接読む（`AoaVideoReceiver`）。USB デバッグ不要。

いずれの経路も受信した H.264 / H.265 を **`H264Decoder`（MediaCodec → Surface）** に集約して全画面表示する。

> 利用者向けの使い方（Mac 側前準備・インストール・操作）は、リポジトリ直下の [`../README.md`](../README.md) を参照。

## ⚠️ ライセンス注意

ネイティブコアは **UxPlay**（リポジトリ全体は **GPL-3.0**、`lib/` ヘッダは LGPL-2.1）を vendoring・移植している。
このコードをリンクするため、**本アプリの配布物は GPL-3.0 の制約**（ソース公開義務等）を受ける。
組み込み OSS の一覧は [`../THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) を参照。

## アーキテクチャ

```
Kotlin (アプリシェル)                      Native (libdisproid.so)
─────────────────────────                ──────────────────────────────
MainActivity ── 開始/停止 UI・解像度選択
AdvertiseService (FGS)
  ├ NativeAirPlay.nativeStart() ──JNI──▶ jni_bridge.c
  │     └ port / pk を取得                    ├ raop_init / raop_init2(ed25519生成)
  ├ NsdManager で _airplay._tcp 公開          ├ raop_set_plist(maxFPS=60, width/height)
  │   (TXT の pk/features を /info と一致)     ├ raop_start_httpd → listen port
  │                                           ├ dnssd_android.c (TXT/識別子保持)
MirrorActivity ◀─ VideoSink(JNI) ◀────────── └ UxPlay airplay コア (RTSP/ペアリング/FairPlay/RTP)
  └ H264Decoder (MediaCodec→Surface)              └ 依存: libplist(同梱ビルド) / libcrypto(prebuilt)
```

- **mDNS 登録**は Kotlin(`NsdManager`)。ネイティブの `dnssd.c`(mDNSResponder 依存)は使わず、
  データ保持＋TXT 生成だけの `dnssd_android.c` に差し替えている。
- **映像表示部**(`renderers/`, GStreamer)は移植せず、`video_process` コールバックで受け取った
  Annex-B フレームを JNI 経由で Kotlin の MediaCodec に流す。
- **コーデック**: features bit42(SupportsScreenMultiCodec) を立て、macOS が解像度に応じて送る
  H.264 / H.265 を `video_set_codec` 通知で判別し MediaCodec の MIME を自動切替する。
- **解像度**: タブレットのアスペクト比を保ち width=1920 基準に正規化して `/info` で報告（UI で選択も可能）。
  `maxFPS=60` を報告して 60fps を許可。

### USB 受信（adb / AOA）

- プロトコル共通: 送信 `DPRQ`(画面解像度通知) → 受信ヘッダ `DPRD`(ver/codec/width/height) → `length(4,BE)+Annex-B` 繰り返し。
- `UsbVideoReceiver`(adb): localabstract socket `disproid` に接続。
- `AoaVideoReceiver`(AOA): `UsbManager.openAccessory()` の FD を直接読み書き。
  - **USB バルクは転送境界単位**で read されるため、小さい read を繰り返すと取りこぼしてフレーミングがズレる。
    常に大きいバッファで read し蓄積バッファから必要分を切り出す。
  - accessory FD は `available()` 非対応(EINVAL)なので `BufferedInputStream` は使わない。
  - 起動経路: `AndroidManifest` の `USB_ACCESSORY_ATTACHED` intent-filter + `res/xml/accessory_filter.xml`
    (manufacturer=`Disproid` / model=`Disproid Display`) で `MirrorActivity` を AOA モードで自動起動。
- **画面の向き**: USB モードは `SCREEN_ORIENTATION_FULL_USER` でシステムの向きに追従。`MirrorActivity` が
  ルートのレイアウト変化を監視して実解像度の変化を検知し、Mac へ再通知（縦↔横の仮想ディスプレイ追従。adb 経路）。

## ビルド環境

- JDK 17（Android Studio 同梱 JBR でよい）
- Android SDK（compileSdk/targetSdk 34）
- **NDK 27.2.12479018 + CMake 3.22.1**（`sdkmanager` で導入）
- Gradle 8.10（Wrapper 同梱）/ AGP 8.6.1 / Kotlin 1.9.25
- 対象 ABI は **arm64-v8a**
- UI ライブラリ: AndroidX AppCompat / Material 3 / SplashScreen（コア機能はフレームワーク API のみ）

`local.properties` に SDK パスが必要（git 管理外。CI では `ANDROID_HOME` で代替）:

```properties
sdk.dir=/Users/<you>/Library/Android/sdk
```

### 前提 1: NDK / CMake の導入

```bash
SDKM=~/Library/Android/sdk/cmdline-tools/latest/bin/sdkmanager
yes | "$SDKM" --install "ndk;27.2.12479018" "cmake;3.22.1"
```

### 前提 2: OpenSSL(libcrypto) のクロスコンパイル（初回のみ）

OpenSSL の prebuilt は容量が大きいため git 管理外。初回ビルド前に 1 度だけ生成する
（OpenSSL ソースが無ければ自動取得、macOS / Linux 両対応）:

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

CI（GitHub Actions）では `v*` タグ push でビルドし、APK を Release に添付する（[`../.github/workflows/release.yml`](../.github/workflows/release.yml)）。

## 動作確認（ログ）

```bash
adb logcat -s DisproidNative DisproidReceiver
# 例: "video_set_codec=2", "MediaCodec 構成: video/hevc 1920x1200", "mirror_video_running=1"
```

## ネイティブ構成

```
app/src/main/cpp/
  CMakeLists.txt              # libplist + airplay + JNI を libdisproid.so にリンク
  jni_bridge.c                # JNI: raop 起動/停止、映像 sink 転送、pk 取り出し
  airplay/                    # UxPlay lib/ を vendoring(renderers除外)
    dnssd_android.c           #   mDNSResponder 依存の dnssd.c を Android 用に差し替え
    llhttp/  playfair/        #   HTTP パーサ / FairPlay
  third_party/libplist/       # libplist(依存ゼロ, CMake 直ビルド) + 手書き config.h
  prebuilt/openssl/           # libcrypto.a + headers(スクリプトで生成, git管理外)
native-deps/
  build-openssl-android.sh    # OpenSSL クロスコンパイル(自己完結・OS自動判定)
  src/                        # openssl の clone(git管理外)
```

## 今後の課題 / TODO

- 音声対応（`audio_process` → AudioTrack）
- 遅延の追い込み、再接続時の堅牢性
- H.265 高解像度（4K）時のデコード負荷検証
- release ビルド＋署名（現状は debug 署名の APK を配布）
- バックグラウンド起動制限下での MirrorActivity 自動前面化の確実性
- AOA: 配信中の回転リビルド（再ハンドシェイク。現状は起動時の向きで固定）
  ※ 切断時の自動再接続は対応済み（onNewIntent 再 attach + リトライ）
