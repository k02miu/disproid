/*
 * dnssd.c の Android 置き換え実装。
 *
 * オリジナルの dnssd.c は mDNSResponder の C API(dns_sd.h)を dlopen して
 * 実際の mDNS 登録を行うが、Android では mDNS 登録は Kotlin 側(NsdManager)が担う。
 * ここではネイティブ raop ハンドラ(raop_handlers.h)が必要とする
 * 「データ保持＋ゲッター」だけを提供し、登録系は no-op とする。
 *
 * TXT レコード(raop/airplay)は GET /info 応答に data ノードとして埋め込まれるため、
 * オリジナルと同じキー/値を自前の TXT エンコーダ(長さ前置のkey=value列)で生成する。
 * 値の定義は dnssdint.h / global.h（UxPlay オリジナル）に従う。
 */
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <assert.h>

#include "dnssd.h"
#include "dnssdint.h"
#include "global.h"
#include "utils.h"

struct dnssd_s {
    char *name;
    int name_len;

    char *hw_addr;
    int hw_addr_len;

    char *pk; /* raop_set_dnssd 経由で設定される(所有しない) */

    uint32_t features1;
    uint32_t features2;

    unsigned char pin_pw;

    char *raop_txt;
    int raop_txt_len;
    char *airplay_txt;
    int airplay_txt_len;
};

/* "key=value" を長さ前置で TXT バッファへ追記する（DNS-SD TXT ワイヤ形式）。 */
static int txt_append(char **buf, int *len, const char *key, const char *val) {
    size_t klen = strlen(key);
    size_t vlen = val ? strlen(val) : 0;
    size_t entry = klen + 1 + vlen; /* key '=' value */
    if (entry > 255) {
        return -1; /* 1 エントリは 255 バイトまで */
    }
    char *nb = (char *) realloc(*buf, (size_t) *len + 1 + entry);
    if (!nb) {
        return -1;
    }
    unsigned char *p = (unsigned char *) nb + *len;
    p[0] = (unsigned char) entry;
    memcpy(p + 1, key, klen);
    p[1 + klen] = '=';
    if (vlen) {
        memcpy(p + 1 + klen + 1, val, vlen);
    }
    *buf = nb;
    *len += (int) (1 + entry);
    return 0;
}

dnssd_t *
dnssd_init(const char *name, int name_len, const char *hw_addr, int hw_addr_len, int *error, unsigned char pin_pw) {
    if (error) {
        *error = DNSSD_ERROR_NOERROR;
    }
    dnssd_t *dnssd = (dnssd_t *) calloc(1, sizeof(dnssd_t));
    if (!dnssd) {
        if (error) *error = DNSSD_ERROR_OUTOFMEM;
        return NULL;
    }

    dnssd->name = (char *) calloc(1, (size_t) name_len + 1);
    dnssd->hw_addr = (char *) calloc(1, (size_t) hw_addr_len);
    if (!dnssd->name || !dnssd->hw_addr) {
        free(dnssd->name);
        free(dnssd->hw_addr);
        free(dnssd);
        if (error) *error = DNSSD_ERROR_OUTOFMEM;
        return NULL;
    }
    memcpy(dnssd->name, name, name_len);
    dnssd->name_len = name_len;
    memcpy(dnssd->hw_addr, hw_addr, hw_addr_len);
    dnssd->hw_addr_len = hw_addr_len;
    dnssd->pin_pw = pin_pw;

    /* features 既定値（dnssdint.h）をパース */
    char *end = NULL;
    dnssd->features1 = (uint32_t) strtoul(FEATURES_1, &end, 16);
    dnssd->features2 = (uint32_t) strtoul(FEATURES_2, &end, 16);

    return dnssd;
}

/* 登録は Kotlin(NsdManager)側。ここでは TXT バッファだけ構築する。 */
int
dnssd_register_raop(dnssd_t *dnssd, unsigned short port) {
    assert(dnssd);
    (void) port;
    char features[24] = {0};
    snprintf(features, sizeof(features), "0x%X,0x%X", dnssd->features1, dnssd->features2);

    free(dnssd->raop_txt);
    dnssd->raop_txt = NULL;
    dnssd->raop_txt_len = 0;

    char **b = &dnssd->raop_txt;
    int *l = &dnssd->raop_txt_len;
    txt_append(b, l, "ch", RAOP_CH);
    txt_append(b, l, "cn", RAOP_CN);
    txt_append(b, l, "da", RAOP_DA);
    txt_append(b, l, "et", RAOP_ET);
    txt_append(b, l, "vv", RAOP_VV);
    txt_append(b, l, "ft", features);
    txt_append(b, l, "am", GLOBAL_MODEL);
    txt_append(b, l, "md", RAOP_MD);
    txt_append(b, l, "rhd", RAOP_RHD);
    txt_append(b, l, "pw", dnssd->pin_pw ? "true" : "false");
    txt_append(b, l, "sf", RAOP_SF);
    txt_append(b, l, "sr", RAOP_SR);
    txt_append(b, l, "ss", RAOP_SS);
    txt_append(b, l, "sv", RAOP_SV);
    txt_append(b, l, "tp", RAOP_TP);
    txt_append(b, l, "txtvers", RAOP_TXTVERS);
    txt_append(b, l, "vs", RAOP_VS);
    txt_append(b, l, "vn", RAOP_VN);
    if (dnssd->pk) {
        txt_append(b, l, "pk", dnssd->pk);
    }
    return 0;
}

int
dnssd_register_airplay(dnssd_t *dnssd, unsigned short port) {
    assert(dnssd);
    (void) port;
    char features[24] = {0};
    snprintf(features, sizeof(features), "0x%X,0x%X", dnssd->features1, dnssd->features2);

    /* deviceid は hw_addr を "XX:XX:.." 形式に整形（オリジナルと同じ utils 関数）。 */
    char device_id[18] = {0};
    utils_hwaddr_airplay(device_id, sizeof(device_id), dnssd->hw_addr, dnssd->hw_addr_len);

    free(dnssd->airplay_txt);
    dnssd->airplay_txt = NULL;
    dnssd->airplay_txt_len = 0;

    char **b = &dnssd->airplay_txt;
    int *l = &dnssd->airplay_txt_len;
    txt_append(b, l, "deviceid", device_id);
    txt_append(b, l, "features", features);
    txt_append(b, l, "pw", dnssd->pin_pw ? "true" : "false");
    txt_append(b, l, "flags", "0x4");
    txt_append(b, l, "model", GLOBAL_MODEL);
    if (dnssd->pk) {
        txt_append(b, l, "pk", dnssd->pk);
    }
    txt_append(b, l, "pi", AIRPLAY_PI);
    txt_append(b, l, "srcvers", AIRPLAY_SRCVERS);
    txt_append(b, l, "vv", AIRPLAY_VV);
    return 0;
}

void
dnssd_unregister_raop(dnssd_t *dnssd) {
    assert(dnssd);
    free(dnssd->raop_txt);
    dnssd->raop_txt = NULL;
    dnssd->raop_txt_len = 0;
}

void
dnssd_unregister_airplay(dnssd_t *dnssd) {
    assert(dnssd);
    free(dnssd->airplay_txt);
    dnssd->airplay_txt = NULL;
    dnssd->airplay_txt_len = 0;
}

const char *
dnssd_get_raop_txt(dnssd_t *dnssd, int *length) {
    *length = dnssd->raop_txt_len;
    return dnssd->raop_txt;
}

const char *
dnssd_get_airplay_txt(dnssd_t *dnssd, int *length) {
    *length = dnssd->airplay_txt_len;
    return dnssd->airplay_txt;
}

const char *
dnssd_get_name(dnssd_t *dnssd, int *length) {
    *length = dnssd->name_len;
    return dnssd->name;
}

const char *
dnssd_get_hw_addr(dnssd_t *dnssd, int *length) {
    *length = dnssd->hw_addr_len;
    return dnssd->hw_addr;
}

uint64_t
dnssd_get_airplay_features(dnssd_t *dnssd) {
    uint64_t features = ((uint64_t) dnssd->features2) << 32;
    features += (uint64_t) dnssd->features1;
    return features;
}

void
dnssd_set_pk(dnssd_t *dnssd, char *pk_str) {
    dnssd->pk = pk_str;
}

/* Android 追加: raop が生成した公開鍵(pk hex)を取り出す。
 * mDNS 広告(NsdManager)の pk を /info と一致させるために JNI ブリッジが使う。 */
const char *
dnssd_get_pk(dnssd_t *dnssd) {
    return dnssd ? dnssd->pk : NULL;
}

void
dnssd_set_airplay_features(dnssd_t *dnssd, int bit, int val) {
    uint32_t mask = 0;
    uint32_t *features = 0;
    if (bit < 0 || bit > 63) return;
    if (val < 0 || val > 1) return;
    if (bit >= 32) {
        mask = 0x1u << (bit - 32);
        features = &(dnssd->features2);
    } else {
        mask = 0x1u << bit;
        features = &(dnssd->features1);
    }
    if (val) {
        *features = *features | mask;
    } else {
        *features = *features & ~mask;
    }
}

void
dnssd_destroy(dnssd_t *dnssd) {
    if (dnssd) {
        free(dnssd->raop_txt);
        free(dnssd->airplay_txt);
        free(dnssd->name);
        free(dnssd->hw_addr);
        free(dnssd);
    }
}
