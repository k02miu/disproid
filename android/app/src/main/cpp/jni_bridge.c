/*
 * JNI ブリッジ: Kotlin <-> UxPlay AirPlay ネイティブコア。
 *
 * Phase B のスコープ:
 *  - raop(HTTP/RTSP サーバ)を起動し、接続を受け付けてペアリング/RTSP のやり取りを行う。
 *  - ログは Android logcat(TAG=DisproidNative)へ流す。
 *  - 映像/音声コールバックはログのみ（実デコード・表示は Phase C）。
 *
 * 設計:
 *  - ed25519 公開鍵(pk)は raop_init2 が生成し raop->pk_str に入る。
 *    raop_set_dnssd 経由で Android 版 dnssd に渡るので、dnssd_get_pk で取り出し、
 *    Kotlin 側 NsdManager 広告の pk と一致させる。
 *  - mDNS 登録自体は Kotlin(NsdManager)が担当。ここでは raop の listen ポートを返すだけ。
 */
#include <jni.h>
#include <android/log.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>

#include "raop.h"
#include "dnssd.h"
#include "logger.h"

#define TAG "DisproidNative"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

/* dnssd_android.c の追加関数（dnssd.h には無い） */
extern const char *dnssd_get_pk(dnssd_t *dnssd);

/* グローバル状態（単一接続前提の Phase B） */
static raop_t *g_raop = NULL;
static dnssd_t *g_dnssd = NULL;

/* ---- Phase C: 映像フレームの Kotlin への受け渡し ---- */
static JavaVM *g_vm = NULL;
static jobject g_video_sink = NULL;       /* VideoSink のグローバル参照 */
static jmethodID g_mid_on_format = NULL;  /* onVideoFormat(II)V */
static jmethodID g_mid_on_frame = NULL;   /* onVideoFrame(Ljava/nio/ByteBuffer;IJ)V */
static jmethodID g_mid_on_mirror = NULL;  /* onMirrorState(Z)V */
static jmethodID g_mid_on_codec = NULL;   /* onVideoCodec(Z)V  (true=H.265) */

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void) reserved;
    g_vm = vm;
    return JNI_VERSION_1_6;
}

/* ネイティブスレッド(mirror RTP)から JNIEnv を得る。必要なら attach（detach はしない）。 */
static JNIEnv *get_env(void) {
    if (!g_vm) return NULL;
    JNIEnv *env = NULL;
    int st = (*g_vm)->GetEnv(g_vm, (void **) &env, JNI_VERSION_1_6);
    if (st == JNI_EDETACHED) {
        if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != 0) {
            return NULL;
        }
    }
    return env;
}

/* ---- ログコールバック: UxPlay -> logcat ---- */
static void log_callback(void *cls, int level, const char *msg) {
    (void) cls;
    int prio = ANDROID_LOG_INFO;
    if (level <= LOGGER_ERR) prio = ANDROID_LOG_ERROR;
    else if (level <= LOGGER_WARNING) prio = ANDROID_LOG_WARN;
    else if (level >= LOGGER_DEBUG) prio = ANDROID_LOG_DEBUG;
    __android_log_print(prio, TAG, "%s", msg ? msg : "");
}

/* ===== raop_callbacks の実装 ===== */
/* Phase B: 接続/ペアリングを通すための最小実装。映像音声はログのみ。 */

static void cb_conn_init(void *cls)    { (void) cls; LOGI("conn_init"); }
static void cb_conn_destroy(void *cls) { (void) cls; LOGI("conn_destroy"); }
static void cb_conn_reset(void *cls, int reason) { (void) cls; LOGW("conn_reset reason=%d", reason); }
static void cb_conn_feedback(void *cls) { (void) cls; }
static void cb_conn_teardown(void *cls, bool *teardown_96, bool *teardown_110) {
    (void) cls; (void) teardown_96; (void) teardown_110; LOGI("conn_teardown");
}

static void cb_audio_process(void *cls, raop_ntp_t *ntp, audio_decode_struct *data) {
    (void) cls; (void) ntp;
    LOGI("audio_process: %d bytes (Phase B: 破棄)", data ? data->data_len : 0);
}
static void cb_video_process(void *cls, raop_ntp_t *ntp, video_decode_struct *data) {
    (void) cls; (void) ntp;
    if (!data || !data->data || data->data_len <= 0) return;
    if (!g_video_sink || !g_mid_on_frame) return; /* sink 未登録なら破棄 */

    JNIEnv *env = get_env();
    if (!env) return;

    /* data->data を direct ByteBuffer でラップ（コールバック中のみ有効）。
     * Kotlin 側は同期的に MediaCodec 入力へコピーする。 */
    jobject buf = (*env)->NewDirectByteBuffer(env, data->data, data->data_len);
    if (buf) {
        /* pts: AirPlay の ntp_time_local(ns) をマイクロ秒に */
        jlong pts_us = (jlong) (data->ntp_time_local / 1000ULL);
        (*env)->CallVoidMethod(env, g_video_sink, g_mid_on_frame, buf, (jint) data->data_len, pts_us);
        (*env)->DeleteLocalRef(env, buf);
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
        }
    }
}
static void cb_video_pause(void *cls)  { (void) cls; }
static void cb_video_resume(void *cls) { (void) cls; }
static void cb_video_reset(void *cls, reset_type_t t) { (void) cls; (void) t; LOGI("video_reset"); }
static void cb_audio_flush(void *cls)  { (void) cls; }
static void cb_video_flush(void *cls)  { (void) cls; }

static double cb_audio_set_client_volume(void *cls) { (void) cls; return 0.0; }
static void cb_audio_set_volume(void *cls, float v) { (void) cls; (void) v; }
static void cb_audio_set_metadata(void *cls, const void *b, int l) { (void) cls; (void) b; (void) l; }
static void cb_audio_set_coverart(void *cls, const void *b, int l) { (void) cls; (void) b; (void) l; }
static void cb_audio_stop_coverart(void *cls) { (void) cls; }
static void cb_audio_remote_control_id(void *cls, const char *d, const char *a) { (void) cls; (void) d; (void) a; }
static void cb_audio_set_progress(void *cls, uint32_t *s, uint32_t *c, uint32_t *e) { (void) cls; (void) s; (void) c; (void) e; }
static void cb_audio_get_format(void *cls, unsigned char *ct, unsigned short *spf, bool *usingScreen, bool *isMedia, uint64_t *audioFormat) {
    (void) cls; (void) ct; (void) spf; (void) usingScreen; (void) isMedia; (void) audioFormat;
}
static void cb_video_report_size(void *cls, float *ws, float *hs, float *w, float *h) {
    (void) cls;
    if (!(ws && hs && w && h)) return;
    LOGI("video_report_size: src=%.0fx%.0f disp=%.0fx%.0f", *ws, *hs, *w, *h);
    if (g_video_sink && g_mid_on_format) {
        JNIEnv *env = get_env();
        if (env) {
            (*env)->CallVoidMethod(env, g_video_sink, g_mid_on_format, (jint) *ws, (jint) *hs);
            if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        }
    }
}
static void cb_mirror_video_running(void *cls, bool running) {
    (void) cls;
    LOGI("mirror_video_running=%d", running);
    if (g_video_sink && g_mid_on_mirror) {
        JNIEnv *env = get_env();
        if (env) {
            (*env)->CallVoidMethod(env, g_video_sink, g_mid_on_mirror, (jboolean) running);
            if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        }
    }
}

static void cb_report_client_request(void *cls, char *deviceid, char *model, char *name, bool *admit) {
    (void) cls;
    LOGI("接続要求: deviceid=%s model=%s name=%s -> 受理", deviceid ? deviceid : "?", model ? model : "?", name ? name : "?");
    if (admit) *admit = true; /* Phase B: 常に受理 */
}
static void cb_display_pin(void *cls, char *pin) { (void) cls; LOGI("display_pin=%s", pin ? pin : "?"); }
static void cb_register_client(void *cls, const char *device_id, const char *pk_str, const char *name) {
    (void) cls;
    LOGI("register_client: device_id=%s name=%s", device_id ? device_id : "?", name ? name : "?");
}
static bool cb_check_register(void *cls, const char *pk_str) {
    (void) cls; (void) pk_str;
    return false; /* Phase B: 未登録扱い -> ペアリングフローへ */
}
static const char *cb_passwd(void *cls, int *len) { (void) cls; if (len) *len = 0; return NULL; }
static void cb_export_dacp(void *cls, const char *ar, const char *id) { (void) cls; (void) ar; (void) id; }
static int cb_video_set_codec(void *cls, video_codec_t codec) {
    (void) cls;
    LOGI("video_set_codec=%d (0=unknown,1=h264,2=h265)", codec);
    if (g_video_sink && g_mid_on_codec) {
        JNIEnv *env = get_env();
        if (env) {
            (*env)->CallVoidMethod(env, g_video_sink, g_mid_on_codec,
                                   (jboolean) (codec == VIDEO_CODEC_H265));
            if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        }
    }
    return 0;
}
/* HLS 動画プレイヤ制御（拡張ディスプレイ用途では未使用） */
static void cb_on_video_play(void *cls, const char *loc, const float pos) { (void) cls; (void) loc; (void) pos; }
static void cb_on_video_scrub(void *cls, const float pos) { (void) cls; (void) pos; }
static void cb_on_video_rate(void *cls, const float rate) { (void) cls; (void) rate; }
static void cb_on_video_stop(void *cls) { (void) cls; }
static void cb_on_video_acquire_playback_info(void *cls, playback_info_t *info) { (void) cls; (void) info; }
static float cb_on_video_playlist_remove(void *cls) { (void) cls; return 0.0f; }

static void fill_callbacks(raop_callbacks_t *cb) {
    memset(cb, 0, sizeof(*cb));
    cb->cls = NULL;
    cb->audio_process = cb_audio_process;
    cb->video_process = cb_video_process;
    cb->video_pause = cb_video_pause;
    cb->video_resume = cb_video_resume;
    cb->conn_feedback = cb_conn_feedback;
    cb->conn_reset = cb_conn_reset;
    cb->video_reset = cb_video_reset;
    cb->conn_init = cb_conn_init;
    cb->conn_destroy = cb_conn_destroy;
    cb->conn_teardown = cb_conn_teardown;
    cb->audio_flush = cb_audio_flush;
    cb->video_flush = cb_video_flush;
    cb->audio_set_client_volume = cb_audio_set_client_volume;
    cb->audio_set_volume = cb_audio_set_volume;
    cb->audio_set_metadata = cb_audio_set_metadata;
    cb->audio_set_coverart = cb_audio_set_coverart;
    cb->audio_stop_coverart_rendering = cb_audio_stop_coverart;
    cb->audio_remote_control_id = cb_audio_remote_control_id;
    cb->audio_set_progress = cb_audio_set_progress;
    cb->audio_get_format = cb_audio_get_format;
    cb->video_report_size = cb_video_report_size;
    cb->mirror_video_running = cb_mirror_video_running;
    cb->report_client_request = cb_report_client_request;
    cb->display_pin = cb_display_pin;
    cb->register_client = cb_register_client;
    cb->check_register = cb_check_register;
    cb->passwd = cb_passwd;
    cb->export_dacp = cb_export_dacp;
    cb->video_set_codec = cb_video_set_codec;
    cb->on_video_play = cb_on_video_play;
    cb->on_video_scrub = cb_on_video_scrub;
    cb->on_video_rate = cb_on_video_rate;
    cb->on_video_stop = cb_on_video_stop;
    cb->on_video_acquire_playback_info = cb_on_video_acquire_playback_info;
    cb->on_video_playlist_remove = cb_on_video_playlist_remove;
}

/* "xx:xx:xx:xx:xx:xx" -> 6 バイト。成功時 6 を返す。 */
static int parse_mac(const char *s, unsigned char out[6]) {
    int vals[6];
    if (!s) return -1;
    int n = sscanf(s, "%x:%x:%x:%x:%x:%x", &vals[0], &vals[1], &vals[2], &vals[3], &vals[4], &vals[5]);
    if (n != 6) return -1;
    for (int i = 0; i < 6; i++) out[i] = (unsigned char) (vals[i] & 0xFF);
    return 6;
}

/* ===== JNI エクスポート ===== */

JNIEXPORT jint JNICALL
Java_io_disproid_receiver_NativeAirPlay_nativeStart(JNIEnv *env, jobject thiz,
                                                    jstring jDeviceId, jstring jName, jstring jKeyfile,
                                                    jint width, jint height, jint refreshRate) {
    (void) thiz;
    if (g_raop) {
        LOGW("既に起動済み");
        return -2;
    }

    const char *deviceId = (*env)->GetStringUTFChars(env, jDeviceId, NULL);
    const char *name = (*env)->GetStringUTFChars(env, jName, NULL);
    const char *keyfile = jKeyfile ? (*env)->GetStringUTFChars(env, jKeyfile, NULL) : NULL;

    int ret_port = -1;
    unsigned char hw_addr[6];

    if (parse_mac(deviceId, hw_addr) != 6) {
        LOGE("deviceId(MAC形式)のパースに失敗: %s", deviceId);
        goto cleanup_strings;
    }

    raop_callbacks_t callbacks;
    fill_callbacks(&callbacks);

    g_raop = raop_init(&callbacks);
    if (!g_raop) {
        LOGE("raop_init 失敗");
        goto cleanup_strings;
    }
    raop_set_log_callback(g_raop, log_callback, NULL);
    raop_set_log_level(g_raop, LOGGER_DEBUG);

    /* nohold=1, device_id, keyfile(ed25519鍵の永続化先。NULL可) */
    if (raop_init2(g_raop, 1, deviceId, keyfile) < 0) {
        LOGE("raop_init2 失敗");
        raop_destroy(g_raop);
        g_raop = NULL;
        goto cleanup_strings;
    }

    /* 接続先タブレットのアスペクト比に合わせた解像度を /info の displays[] で報告。
     * 注意: 生のパネル解像度(例 2160x1350)は AppleTV5,3 が受け付けず映像が止まるため、
     * Kotlin 側で width=1920 基準の標準的な値に整えて渡す。要検証: 受理される解像度の範囲。 */
    if (width > 0 && height > 0) {
        raop_set_plist(g_raop, "width", width);
        raop_set_plist(g_raop, "height", height);
    }
    if (refreshRate > 0) {
        raop_set_plist(g_raop, "refreshRate", refreshRate);
    }
    /* maxFPS の既定は 30 で macOS の送出上限になるため 60 へ。 */
    raop_set_plist(g_raop, "maxFPS", 60);
    LOGI("display 報告: %dx%d @%dHz maxFPS=60", width, height, refreshRate);

    int err = 0;
    g_dnssd = dnssd_init(name, (int) strlen(name), (const char *) hw_addr, 6, &err, 0);
    if (!g_dnssd || err) {
        LOGE("dnssd_init 失敗 err=%d", err);
        raop_destroy(g_raop);
        g_raop = NULL;
        goto cleanup_strings;
    }
    raop_set_dnssd(g_raop, g_dnssd);          /* dnssd->pk = raop->pk_str */
    /* features bit 42 = SupportsScreenMultiCodec。これを立てると macOS は
     * 非標準解像度(16:10等)で H.265 を送ってくる。立てないと UxPlay が reset する。
     * (UxPlay の -h265 オプション相当) */
    dnssd_set_airplay_features(g_dnssd, 42, 1);
    dnssd_register_raop(g_dnssd, 0);          /* TXT バッファ構築（mDNS自体はKotlin） */
    dnssd_register_airplay(g_dnssd, 0);

    unsigned short port = 0;
    if (raop_start_httpd(g_raop, &port) < 0) {
        LOGE("raop_start_httpd 失敗");
        dnssd_destroy(g_dnssd); g_dnssd = NULL;
        raop_destroy(g_raop); g_raop = NULL;
        goto cleanup_strings;
    }
    LOGI("raop 起動: port=%d pk=%s", port, dnssd_get_pk(g_dnssd));
    ret_port = (int) port;

cleanup_strings:
    (*env)->ReleaseStringUTFChars(env, jDeviceId, deviceId);
    (*env)->ReleaseStringUTFChars(env, jName, name);
    if (keyfile) (*env)->ReleaseStringUTFChars(env, jKeyfile, keyfile);
    return ret_port;
}

JNIEXPORT jstring JNICALL
Java_io_disproid_receiver_NativeAirPlay_nativeGetPublicKey(JNIEnv *env, jobject thiz) {
    (void) thiz;
    const char *pk = g_dnssd ? dnssd_get_pk(g_dnssd) : NULL;
    return (*env)->NewStringUTF(env, pk ? pk : "");
}

/* 映像フレームの受け取り先(VideoSink)を登録/解除する。null で解除。 */
JNIEXPORT void JNICALL
Java_io_disproid_receiver_NativeAirPlay_nativeSetVideoSink(JNIEnv *env, jobject thiz, jobject sink) {
    (void) thiz;
    if (g_video_sink) {
        (*env)->DeleteGlobalRef(env, g_video_sink);
        g_video_sink = NULL;
    }
    g_mid_on_format = NULL;
    g_mid_on_frame = NULL;
    g_mid_on_mirror = NULL;
    g_mid_on_codec = NULL;

    if (sink) {
        g_video_sink = (*env)->NewGlobalRef(env, sink);
        jclass cls = (*env)->GetObjectClass(env, sink);
        g_mid_on_format = (*env)->GetMethodID(env, cls, "onVideoFormat", "(II)V");
        g_mid_on_frame = (*env)->GetMethodID(env, cls, "onVideoFrame", "(Ljava/nio/ByteBuffer;IJ)V");
        g_mid_on_mirror = (*env)->GetMethodID(env, cls, "onMirrorState", "(Z)V");
        g_mid_on_codec = (*env)->GetMethodID(env, cls, "onVideoCodec", "(Z)V");
        (*env)->DeleteLocalRef(env, cls);
        LOGI("VideoSink 登録");
    } else {
        LOGI("VideoSink 解除");
    }
}

JNIEXPORT void JNICALL
Java_io_disproid_receiver_NativeAirPlay_nativeStop(JNIEnv *env, jobject thiz) {
    (void) env; (void) thiz;
    if (g_raop) {
        raop_stop_httpd(g_raop);
        raop_destroy(g_raop);
        g_raop = NULL;
    }
    if (g_dnssd) {
        dnssd_destroy(g_dnssd);
        g_dnssd = NULL;
    }
    LOGI("raop 停止");
}
