package io.disproid.receiver

import android.content.Context

/**
 * Mac に報告する解像度のプリセット。
 *
 * width=0 は「自動」（タブレットの実アスペクト比から width=1920 基準で算出）。
 * 16:9(1080p 以下)は概ね H.264、16:10 や高解像度は macOS が H.265 を送る（自動でデコーダ切替）。
 */
object ResolutionOptions {

    data class Opt(val label: String, val width: Int, val height: Int)

    val list = listOf(
        Opt("自動（タブレットに最適）", 0, 0),
        Opt("1280×720（軽量・低遅延）", 1280, 720),
        Opt("1920×1080（FHD 16:9）", 1920, 1080),
        Opt("1920×1200（16:10）", 1920, 1200),
        Opt("2560×1600（高精細・負荷大）", 2560, 1600),
    )

    private const val PREFS = "disproid_settings"
    private const val KEY = "resolution_index"

    fun savedIndex(ctx: Context): Int {
        val i = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt(KEY, 0)
        return i.coerceIn(0, list.size - 1)
    }

    fun save(ctx: Context, index: Int) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putInt(KEY, index.coerceIn(0, list.size - 1)).apply()
    }

    fun saved(ctx: Context): Opt = list[savedIndex(ctx)]
}
