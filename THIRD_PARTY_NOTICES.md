# Third-Party Notices / 組み込み OSS のライセンス表記

Disproid 本体は [GPL-3.0](LICENSE) で公開しています。以下は各第三者コードの元の条件です。
Android は CMake で airplay / libplist / libcrypto を `libdisproid.so` に静的リンクします。
Mac Helper はこれら Android 用ライブラリをリンクせず、自前の Swift / Objective-C コードと Apple のシステム framework を使います。

## Android ネイティブコード

| コンポーネント | 用途・取得元 | 元のライセンスと原文 |
|---|---|---|
| UxPlay AirPlay コア | `android/app/src/main/cpp/airplay/`。https://github.com/FDH2/UxPlay のコアを移植、dnssd を Android 用に置換 | GPL-3.0-or-later のファイル（例: `crypto.c`）と LGPL-2.1-or-later のファイル（例: `pairing.c`）が混在。各ファイルのヘッダ、[GPLv3](LICENSE)、[LGPL2.1](licenses/LGPL-2.1.txt) を参照 |
| playfair | `airplay/playfair/`、FairPlay ハンドシェイク | [同梱の GPLv3 原文](android/app/src/main/cpp/airplay/playfair/LICENSE.md) |
| libplist / libcnary | `android/app/src/main/cpp/third_party/libplist/`、plist パース/生成。https://github.com/libimobiledevice/libplist | ライブラリのヘッダは LGPL-2.1-or-later。[LGPL2.1 原文](licenses/LGPL-2.1.txt)（同梱 `libcnary/COPYING` と同じ）。既存の `libplist/COPYING` は GPLv2 全文であり、LGPL 全文ではありません。元ファイルは保持しています |
| llhttp | `airplay/llhttp/`、HTTP/RTSP パース。https://github.com/nodejs/llhttp | MIT、Copyright Fedor Indutny, 2018。[原文](android/app/src/main/cpp/airplay/llhttp/LICENSE-MIT) |
| SRP (csrp) | `airplay/srp.c`。https://github.com/cocagne/csrp | MIT、Copyright (c) 2010 / 2013 Tom Cocagne。原文と UxPlay 側の改変表示は同ファイル冒頭 |
| jsmn | `third_party/libplist/src/jsmn.c` | MIT、Copyright (c) 2010 Serge A. Zaitsev。原文・改変表示は同ファイル冒頭 |
| time64 | `third_party/libplist/src/time64.c` | MIT、Copyright (c) 2007-2010 Michael G Schwern。原文は同ファイル冒頭 |
| OpenSSL libcrypto 3.3.2 | `android/native-deps/build-openssl-android.sh` で `openssl-3.3.2` をビルド。https://github.com/openssl/openssl | [Apache-2.0 原文](licenses/Apache-2.0.txt)。著作権・追加通知は実際の OpenSSL ソースに保持 |

libplist の手書き `config.h` のバージョン文字列だけで vendor 一式が upstream の特定リリースと同一とは保証しません。
対応ソースには、このリポジトリに収録した実際の vendor 一式を含めます。

## Android の Gradle 依存

直接依存は AndroidX AppCompat 1.7.0 / Core SplashScreen 1.0.1 と Material Components 1.12.0（Apache-2.0）です。
これらと推移的依存は、ビルド時に取得して **APK に組み込まれます**。
[Apache-2.0 全文](licenses/Apache-2.0.txt) に加え、実際に解決した AAR / JAR 内の LICENSE / NOTICE と依存一覧を
ビルド時に `runtime-notices/` と `runtime-dependencies.json` に収集します。
直接依存3件だけを配布対象の全依存とは扱いません。

## 配布物に含める原文と対応ソース

`scripts/distribution.py notices` は本通知、GPLv3 / LGPL2.1 / Apache2.0、llhttp / playfair の原文、
vendor ソース先頭の著作権・許諾文（SRP / jsmn / time64 を含む）を改変せず収集します。
Android ではさらに実際の Gradle ランタイム依存の通知を収集します。
収集先、利用者の閲覧方法、ソースアーカイブの作成手順は [DISTRIBUTION.md](DISTRIBUTION.md) を参照してください。

各ファイルの著作権表示・許諾文を保持してください。本通知は各ライセンス原文に代わるものではありません。
