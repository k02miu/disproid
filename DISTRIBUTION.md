# 配布物・ライセンス・対応ソース

この手順は **次回以降にビルドする配布物**に適用します。既存の v1.0.0 の資材は変更していません。
v1.0.0 は AOA 非対応です。以下の同梱通知・ソース資材は後から既存 APK / ZIP に追加されるものではありません。

## 利用者が通知を見る場所

- Android: メイン画面のメニュー「ライセンスとソース」。APK 内の `assets/oss/` に原文を同梱。
- Mac: メニューバーの「ライセンスとソース」。`.app/Contents/Resources/oss/` に原文を同梱。
- いずれも GPLv3、第三者通知、各許諾文をオフラインで閲覧できます。`SOURCES.txt` にビルドのコミットとソース取得先を記録します。

Disproid は無保証で、GPL-3.0 と各第三者ライセンスの条件に従って改変・再配布できます。
LGPL のライブラリを改変して再リンクする場合も、同じ資材の CMake / Gradle 手順で全体を再ビルドできます。

## 対応ソースの内容と再ビルド

同じ Release に `disproid-source-<tag>.tar.gz` をバイナリと一緒に添付します。
これには同じコミットの Kotlin / C / Swift、vendor 一式、ビルド・梱包スクリプト、
実際に使った OpenSSL 3.3.2 のソースと Gradle のランタイム依存のソース JAR（または公式ソースアーカイブ）/ POM / ハッシュ一覧を含めます。
GitHub の自動生成「Source code」だけでは OpenSSL 等が含まれないため、上記資材を使ってください。

展開後、Android は `android/README.md`、Mac は `mac/README.md` の環境・コマンドに従ってビルドしてください。
`dependency-sources/` の JAR は ZIP として展開できます。これらは Gradle が解決したバージョンごとのソースです。
ソースJARのない ConstraintLayout / solver 2.0.1 は、公式タグ `2.0.1` のコミット
`272719edf76066c3bee82987012da9349c760233` のアーカイブを、SHA-256 を固定して収録します。
各取得元とハッシュは `dependencies.json` に記録します。Git 情報のない展開先でも、同梱マニフェストでソースを検証してビルドできます。
SDK / NDK / JDK / Swift / Gradle などの標準ビルドツールは各配布元から別途取得してください。

Android のソース収集は全ランタイム依存を対象にします。対応ソースまたは POM が取得できなければ失敗させます。
依存が変わった場合には、ライセンスと追加 NOTICE を再確認してから配布してください。

## 配布前のローカル検証

```bash
# OpenSSL は既存 checkout のタグ・変更状態も検証する
(cd android/native-deps && bash build-openssl-android.sh)
(cd android && ./gradlew :app:assembleDebug :app:collectRuntimeSources)
(cd mac && bash make-app.sh)
python3 scripts/distribution.py source
```

正式なソース資材の作成は clean な作業ツリーで行います。ローカルの未コミット修正を検証する場合だけ
`python3 scripts/distribution.py source --allow-dirty` を使ってください。これはローカル検証用と明記され、
公開済みソースと同一とは表示しません。ソース資材内の `SOURCE_BUILD.json` にコミット・dirty 状態・OpenSSL のコミットを残します。

## GitHub Actions の配布順序

タグの CI で Android / Mac / 対応ソースをすべてビルドし、通知・資材の検証が成功してから、
最後のジョブで一つの Release にまとめて添付します。途中でソース収集が失敗した場合にバイナリだけ公開しません。
`workflow_dispatch` は検証用 artifact の生成だけを行い、Release を公開しません。
新しいタグ・Release の公開や、既存 Release の修復は別途行う作業です。
