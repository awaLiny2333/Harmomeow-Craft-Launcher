/*
 * meowlog.h - hilog helpers for libmeowcraftbridge.so.
 *
 * A tiny wrapper around OH_LOG_Print with a single domain/tag so that native
 * bridge logs are easy to filter. The tag is MeowCraft to keep these messages
 * distinct from other native components in the process.
 */
#ifndef MEOWCRAFTBRIDGE_MEOWLOG_H
#define MEOWCRAFTBRIDGE_MEOWLOG_H

#include "hilog/log.h"

#define MEOW_LOG_DOMAIN 0xD003
#define MEOW_LOG_TAG "MeowCraft"

#define MEOWLOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, MEOW_LOG_DOMAIN, MEOW_LOG_TAG, __VA_ARGS__)
#define MEOWLOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN, MEOW_LOG_DOMAIN, MEOW_LOG_TAG, __VA_ARGS__)
#define MEOWLOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, MEOW_LOG_DOMAIN, MEOW_LOG_TAG, __VA_ARGS__)
#define MEOWLOGD(...) OH_LOG_Print(LOG_APP, LOG_DEBUG, MEOW_LOG_DOMAIN, MEOW_LOG_TAG, __VA_ARGS__)

#endif /* MEOWCRAFTBRIDGE_MEOWLOG_H */
