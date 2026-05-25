cmake_minimum_required(VERSION 3.18.1)
project(disproid_native C)

set(CMAKE_C_STANDARD 11)

set(CPP_ROOT ${CMAKE_CURRENT_SOURCE_DIR})
set(LIBPLIST ${CPP_ROOT}/third_party/libplist)
set(OPENSSL ${CPP_ROOT}/prebuilt/openssl)
set(AIRPLAY ${CPP_ROOT}/airplay)

# ---- prebuilt OpenSSL(libcrypto) を IMPORTED で取り込む ----
# native-deps/build-openssl-android.sh で ABI ごとに生成済みの .a を使う。
add_library(crypto STATIC IMPORTED)
set_target_properties(crypto PROPERTIES
    IMPORTED_LOCATION ${OPENSSL}/lib/${ANDROID_ABI}/libcrypto.a
    INTERFACE_INCLUDE_DIRECTORIES ${OPENSSL}/include)

# ---- libplist (autotools を回避し src を直接ビルド) ----
file(GLOB LIBPLIST_SRC
    ${LIBPLIST}/src/*.c
    ${LIBPLIST}/libcnary/*.c)
add_library(plist STATIC ${LIBPLIST_SRC})
target_compile_definitions(plist PRIVATE HAVE_CONFIG_H)
target_include_directories(plist PUBLIC
    ${LIBPLIST}            # 手書き config.h
    ${LIBPLIST}/include
    ${LIBPLIST}/src
    ${LIBPLIST}/libcnary/include)
# libplist 由来の警告は抑制（vendored 第三者コード）
target_compile_options(plist PRIVATE -w)

# ---- UxPlay AirPlay コア(airplay) ----
# dnssd.c はオリジナルを除外し、dnssd_android.c に差し替え済み。
# renderers(GStreamer) は移植しない（Android は MediaCodec/Surface を Kotlin 側で使用）。
file(GLOB AIRPLAY_SRC
    ${AIRPLAY}/*.c
    ${AIRPLAY}/llhttp/*.c
    ${AIRPLAY}/playfair/*.c)
add_library(airplay STATIC ${AIRPLAY_SRC})
# libplist のバージョン分岐（2.1+/2.3+ のモダン API パスを選択）
target_compile_definitions(airplay PRIVATE PLIST_210 PLIST_230)
target_include_directories(airplay PUBLIC
    ${AIRPLAY}
    ${AIRPLAY}/llhttp)
target_link_libraries(airplay PUBLIC plist crypto)
target_compile_options(airplay PRIVATE -w)

# ---- JNI 共有ライブラリ ----
add_library(disproid SHARED ${CPP_ROOT}/jni_bridge.c)
find_library(log-lib log)
target_link_libraries(disproid airplay ${log-lib})
