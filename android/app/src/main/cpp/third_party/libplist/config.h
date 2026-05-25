/*
 * libplist 用の手書き config.h（Android NDK / bionic, API>=26 向け）。
 * autotools(configure) を回避して CMake で直接ビルドするため、
 * configure が生成する config.h をここで代替する。
 *
 * bionic(API 26) は以下をすべて提供する。
 */
#ifndef CONFIG_H
#define CONFIG_H

#define PACKAGE_VERSION "2.6.0"
#define VERSION "2.6.0"

#define HAVE_GMTIME_R 1
#define HAVE_LOCALTIME_R 1
#define HAVE_MEMMEM 1
#define HAVE_STRNDUP 1
#define HAVE_STRPTIME 1
#define HAVE_TM_TM_GMTOFF 1
#define HAVE_TM_TM_ZONE 1

#endif /* CONFIG_H */
