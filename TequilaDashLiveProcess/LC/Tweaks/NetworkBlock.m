//
//  NetworkBlock.m
//  LiveContainer (TequilaDash 适配)
//
//  联网管理 (owner 2026-11-08 需求, LC 没有的功能): 宿主侧按容器记录开关
//  (defaults "TDNetBlock-<bundleId>", 启动时写入 defaults "TDGuestNetBlock",
//  HostGuestEntry.m 转 TD_NET_BLOCK 环境变量), 本文件在访客 hook 顺序块里
//  拦截对外 TCP connect —— 命中即 EPERM.
//
//  覆盖口径 (v0.3.850 扩展): 拦 TCP/UDP 出站与 DNS 解析 ——
//    · connect      → TCP + 已 connect 的 UDP
//    · sendto       → 无 connect 的 UDP（含 QUIC/HTTP3 的多数实现）
//    · sendmsg      → 同上，走 msghdr 的变体
//    · getaddrinfo  → 域名解析直接失败（EAI_AGAIN），避免 App 反复重试
//  仍未覆盖（诚实）：已建立的本地 socketpair、Network.framework 的
//  nw_connection 若走内核通道、以及 UNIX domain（不影响对外联网）。
//  钩子安装分两层: litehook 全局重绑 (已载入镜像) + fishhook 重绑
//  (访客镜像 dlopen 之后的延迟绑定), 调用点在 LCBootstrap.m (dlopen 成功后).
//

#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netdb.h>
#include <dlfcn.h>
#import <errno.h>
#import "litehook.h"
#import "fishhook.h"

static void log_blocked_once(const char *what) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSLog(@"[NetBlock] 已拦截 %s（后续同类调用不再打印）", what);
    });
}
static int hook_connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    log_blocked_once("connect");
    errno = EPERM;
    return -1;
}

// UDP：未 connect 的 socket 走 sendto/sendmsg（QUIC、DNS over UDP 等）。
static ssize_t hook_sendto(int sockfd, const void *buf, size_t len, int flags,
                           const struct sockaddr *dest_addr, socklen_t addrlen) {
    log_blocked_once("sendto");
    errno = EPERM;
    return -1;
}

static ssize_t hook_sendmsg(int sockfd, const struct msghdr *msg, int flags) {
    log_blocked_once("sendmsg");
    errno = EPERM;
    return -1;
}

// DNS：直接失败，避免 App 在 connect 被拦后仍反复解析域名（表现像卡死）。
static int hook_getaddrinfo(const char *node, const char *service,
                            const struct addrinfo *hints, struct addrinfo **res) {
    log_blocked_once("getaddrinfo");
    return EAI_AGAIN;
}

// Network.framework / nw_connection 走 connectx（不是 connect）。只钩 connect 的版本
// 会让这类 App 看起来「禁止联网无效」。签名按 Darwin connectx 原型，返回值只要失败即可。
typedef unsigned int sae_associd_t;
typedef unsigned int sae_connid_t;
static int hook_connectx(int socket, const struct sockaddr *src,
                         const struct sockaddr *dst, uint32_t ifindex,
                         sae_associd_t associd, unsigned int flags,
                         const void *iov, unsigned int iovcnt,
                         unsigned int *len, sae_connid_t *connid) {
    errno = EPERM;
    return -1;
}


/// dlopen 访客**之前**调用: 重绑已载入镜像 (宿主侧) 的 connect.
void NetBlockGuestHooksInit(void) {
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, connect, hook_connect, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, sendto, hook_sendto, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, sendmsg, hook_sendmsg, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, getaddrinfo, hook_getaddrinfo, nil);
    // connectx 不在公开头文件里，按符号名取地址再重绑（直接写标识符会编译不过）.
    void *connectxSym = dlsym(RTLD_DEFAULT, "connectx");
    if (connectxSym) {
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, connectxSym, (void *)hook_connectx, nil);
    }
    NSLog(@"[NetBlock] hooks 已安装 (connect/sendto/sendmsg/getaddrinfo/connectx)");
}

/// dlopen 访客**之后**调用: fishhook 补访客镜像的延迟绑定.
void NetBlockApplyAfterGuestLoad(void) {
    rebind_symbols((char *)"connect", hook_connect);
    rebind_symbols((char *)"sendto", hook_sendto);
    rebind_symbols((char *)"sendmsg", hook_sendmsg);
    rebind_symbols((char *)"getaddrinfo", hook_getaddrinfo);
    rebind_symbols((char *)"connectx", hook_connectx);
}
