/*
 * libxpc 的最小声明：SDK 里没有 <xpc/xpc.h> 时用它，有的话直接用真头，
 * 避免与真头里的 xpc_object_t（NSObject<OS_xpc_object> *）发生 typedef 冲突。
 */
#ifndef TD_XPC_SHIM_H
#define TD_XPC_SHIM_H

#if __has_include(<xpc/xpc.h>)
#include <xpc/xpc.h>
#else
typedef void *xpc_object_t;

extern xpc_object_t xpc_string_create(const char *string);
extern void xpc_release(xpc_object_t object);
#endif

#endif /* TD_XPC_SHIM_H */
