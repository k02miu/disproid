# Third-Party Notices / 組み込み OSS のライセンス表記

本プロジェクト（Disproid）は以下のサードパーティ・ソフトウェアを利用・移植・同梱しています。
各コンポーネントのライセンス条件に従ってください。

> **重要**: 本プロジェクトはネイティブ AirPlay コアとして **UxPlay（GPLv3）** を移植・静的リンクしています。
> そのため、**本プロジェクトの配布物全体が GPL-3.0** の条件下に置かれます（リポジトリ直下の [`LICENSE`](LICENSE) 参照）。

---

## UxPlay

- 用途: AirPlay 受信プロトコルのネイティブコア（RTSP / ペアリング / FairPlay / RTP / H.264・H.265 取り出し）
- 取り込み: ソースを `android/app/src/main/cpp/airplay/` に vendoring（`renderers/` は除外、`dnssd.c` は Android 版 `dnssd_android.c` に差し替え）
- 配布元: https://github.com/FDH2/UxPlay
- ライセンス: **GPL-3.0**（プロジェクト全体）。`lib/`（移植した airplay コア）の各ヘッダは **LGPL-2.1** 表記を保持。
  - 各ソースファイル冒頭のライセンスヘッダを参照。

## libplist

- 用途: バイナリ plist のパース/生成（AirPlay の各種メッセージ）
- 取り込み: ソースを `android/app/src/main/cpp/third_party/libplist/` に vendoring し、CMake で直接ビルド
- 配布元: https://github.com/libimobiledevice/libplist
- ライセンス: **LGPL-2.1-or-later**
- ライセンス全文: `android/app/src/main/cpp/third_party/libplist/COPYING`

## llhttp

- 用途: HTTP/RTSP リクエストのパース
- 取り込み: UxPlay 同梱分を `android/app/src/main/cpp/airplay/llhttp/` に vendoring
- 配布元: https://github.com/nodejs/llhttp
- ライセンス: **MIT**
- ライセンス全文: `android/app/src/main/cpp/airplay/llhttp/LICENSE-MIT`

## playfair (FairPlay)

- 用途: FairPlay ハンドシェイク
- 取り込み: UxPlay 同梱分を `android/app/src/main/cpp/airplay/playfair/` に vendoring
- ライセンス全文: `android/app/src/main/cpp/airplay/playfair/LICENSE.md`

## OpenSSL (libcrypto)

- 用途: 暗号処理（AES / Ed25519 / SHA / SRP 等）
- 取り込み: ソースは同梱せず、ビルド時に upstream からクロスコンパイルして静的リンク
  （`android/native-deps/build-openssl-android.sh`、対象 OpenSSL 3.3.2）
- 配布元: https://github.com/openssl/openssl
- ライセンス: **Apache-2.0**（OpenSSL 3.x）

## AndroidX / Material Components

- 用途: アプリ UI（Material 3、AppCompat、SplashScreen）
- 取り込み: Gradle 依存（同梱なし、ビルド時に取得）
- ライセンス: **Apache-2.0**

---

## 早見表

| コンポーネント | ライセンス | 取り込み形態 |
|---|---|---|
| UxPlay | GPL-3.0（lib は LGPL-2.1 表記） | ソース vendoring |
| libplist | LGPL-2.1-or-later | ソース vendoring |
| llhttp | MIT | ソース vendoring |
| playfair | （`playfair/LICENSE.md` 参照） | ソース vendoring |
| OpenSSL (libcrypto) | Apache-2.0 | ビルド時クロスコンパイル・静的リンク |
| AndroidX / Material | Apache-2.0 | Gradle 依存 |
