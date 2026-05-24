package io.disproid.receiver

/**
 * `_airplay._tcp` の TXT レコード内容を構築する。
 *
 * 値の手本は UxPlay（lib/dnssd.c の dnssd_register_airplay / lib/dnssdint.h / lib/global.h）。
 * UxPlay はこのプロジェクトと同一ネットワーク上で `AppleTV3,2` として macOS に Apple TV
 * 種別で列挙される実績がある。観測した on-wire 値とも一致する。
 *
 * Phase A の目的は「macOS の画面ミラーリング一覧に Apple TV として出現すること」であり、
 * model と features ビットが macOS の扱いを左右する核となる。
 */
object AirPlayTxtRecord {

    /** AirPlay サービスタイプ。NsdManager にはこの形で渡す。 */
    const val SERVICE_TYPE = "_airplay._tcp"

    /** 核となるモデル文字列。これにより macOS は Apple TV 種別として扱う（UxPlay GLOBAL_MODEL）。 */
    const val MODEL = "AppleTV3,2"

    /**
     * features ビットマスク（lo,hi の 2 ワード）。UxPlay 観測値（legacy pairing bit OFF）。
     * 各ビットが対応機能（音声/映像/画面ミラー等）を表す。要検証: 拡張表示に必須のビット構成。
     */
    const val FEATURES = "0x527FFEE6,0x0"

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
     * 端末固有値（deviceid/pi/pk）は [DeviceIdentity] から渡す。
     */
    fun build(identity: DeviceIdentity): Map<String, String> = linkedMapOf(
        "deviceid" to identity.deviceId,
        "features" to FEATURES,
        "flags" to FLAGS,
        "model" to MODEL,
        "pw" to PW,
        "pi" to identity.pi,
        "pk" to identity.pk,
        "srcvers" to SRCVERS,
        "vv" to VV,
    )
}
