package io.disproid.receiver

/**
 * 診断ログのスイッチ。true にすると毎秒の受信/デコード統計などの詳細ログを出す。
 * 通常配布では false（重要イベント・エラーログは常に出力）。
 */
object Diag {
    const val VERBOSE = false
}
