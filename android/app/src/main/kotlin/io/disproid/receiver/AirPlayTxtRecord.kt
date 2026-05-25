package io.disproid.receiver

/**
 * `_airplay._tcp` の TXT レコード内容を構築する。
 *
 * 値の手本は UxPlay（lib/dnssd.c の dnssd_register_airplay / lib/dnssdint.h / lib/global.h）。
 * UxPlay はこのプロジェクトと同一ネットワーク上で `AppleTV3,2` として macOS に Apple TV
 * 種別で列挙される実績がある。観測した on-wire 値とも一致する。
 *
 * 「macOS の画面ミラーリング一覧に Apple TV として出現すること」が目的であり、
 * model と features ビットが macOS の扱いを左右する核となる。
 */
object AirPlayTxtRecord {

    /** AirPlay サービスタイプ。NsdManager にはこの形で渡す。 */
    const val SERVICE_TYPE = "_airplay._tcp"

    /** 核となるモデル文字列。これにより macOS は Apple TV 種別として扱う。
     *  実験: 60fps を狙い AppleTV5,3(第4世代) に昇格（元 AppleTV3,2）。ネイティブ global.h と一致させる。 */
    const val MODEL = "AppleTV5,3"

    /**
     * features ビットマスク（lo,hi の 2 ワード）。
     * ネイティブコアの dnssdint.h FEATURES_1/_2 と一致させる（bit27=legacy pairing ON）。
     * 高位ワードの bit10(=全体の bit42, SupportsScreenMultiCodec)を立てて H.265 受信に対応（0x400）。
     * これにより 16:10 等の非標準解像度で macOS が送る HEVC を受けられる。
     */
    const val FEATURES = "0x5A7FFEE6,0x400"

    /** AirPlay ソースバージョン（UxPlay GLOBAL_VERSION）。要検証: 拡張が legacy srcvers=220.68 で通るか。 */
    const val SRCVERS = "220.68"

    /** AirPlay status flags（UxPlay airplay record と一致）。 */
    const val FLAGS = "0x4"

    /** パスワード不要。 */
    const val PW = "false"

    /** UxPlay AIRPLAY_VV。 */
    const val VV = "2"

    /**
     * TXT レコードのキー/値マップを構築する。
     * 端末固有値（deviceid/pi）は [DeviceIdentity] から、pk はネイティブ raop が生成した
     * 公開鍵を渡す（GET /info の pk と一致させるため）。pkOverride が空なら identity.pk。
     */
    fun build(identity: DeviceIdentity, pkOverride: String? = null): Map<String, String> = linkedMapOf(
        "deviceid" to identity.deviceId,
        "features" to FEATURES,
        "flags" to FLAGS,
        "model" to MODEL,
        "pw" to PW,
        "pi" to identity.pi,
        "pk" to (pkOverride?.takeIf { it.isNotEmpty() } ?: identity.pk),
        "srcvers" to SRCVERS,
        "vv" to VV,
    )
}
