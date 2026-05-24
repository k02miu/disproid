package io.disproid.receiver

import android.content.Context
import java.security.SecureRandom
import java.util.UUID

/**
 * AirPlay 広告で使う端末固有の識別子を生成・永続化する。
 *
 * 実際の Wi-Fi MAC アドレスは Android 10+ で取得が制限されているため、
 * deviceid はランダム生成して SharedPreferences に保存し、端末内で安定させる。
 * pi(UUID)・pk(公開鍵プレースホルダ) も同様に一度だけ生成して固定する。
 */
class DeviceIdentity private constructor(
    /** "XX:XX:XX:XX:XX:XX" 形式。AirPlay TXT の deviceid。 */
    val deviceId: String,
    /** AirPlay TXT の pi（デバイス UUID）。 */
    val pi: String,
    /** AirPlay TXT の pk（Ed25519 公開鍵の hex）。要検証: ペアリング前は発見時に検証されない想定のプレースホルダ。 */
    val pk: String,
) {
    companion object {
        private const val PREFS = "disproid_identity"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_PI = "pi"
        private const val KEY_PK = "pk"

        fun load(context: Context): DeviceIdentity {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val rng = SecureRandom()

            var deviceId = prefs.getString(KEY_DEVICE_ID, null)
            if (deviceId == null) {
                deviceId = randomMacFormat(rng)
            }
            var pi = prefs.getString(KEY_PI, null)
            if (pi == null) {
                pi = UUID.randomUUID().toString()
            }
            var pk = prefs.getString(KEY_PK, null)
            if (pk == null) {
                pk = randomHex(rng, 32) // Ed25519 公開鍵は 32 バイト
            }

            prefs.edit()
                .putString(KEY_DEVICE_ID, deviceId)
                .putString(KEY_PI, pi)
                .putString(KEY_PK, pk)
                .apply()

            return DeviceIdentity(deviceId, pi, pk)
        }

        /**
         * ランダムな MAC 形式文字列を生成する。
         * locally-administered ビットを立て、マルチキャストビットは落とす（ユニキャスト扱い）。
         * 要検証: macOS が deviceid の形式・一意性に依存するかは未確認。
         */
        private fun randomMacFormat(rng: SecureRandom): String {
            val bytes = ByteArray(6)
            rng.nextBytes(bytes)
            bytes[0] = ((bytes[0].toInt() and 0xFC) or 0x02).toByte()
            return bytes.joinToString(":") { String.format("%02x", it.toInt() and 0xFF) }
        }

        private fun randomHex(rng: SecureRandom, numBytes: Int): String {
            val bytes = ByteArray(numBytes)
            rng.nextBytes(bytes)
            return bytes.joinToString("") { String.format("%02x", it.toInt() and 0xFF) }
        }
    }
}
