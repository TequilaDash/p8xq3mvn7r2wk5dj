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
#import <mach-o/loader.h>
#import <mach-o/getsect.h>

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

static void fishhook_one(const char *name, void *hook) {
    struct rebinding rb = { (char *)name, hook, NULL };
    rebind_symbols(&rb, 1);
}

/// dlopen 访客**之后**调用: fishhook 补访客镜像的延迟绑定.
///
/// 注意：这里必须用 fishhook 的**结构体数组** API。之前写成
/// `rebind_symbols((char*)"connect", hook_connect)` 没有原型（隐式声明），
/// 实际把字符串指针当成 `struct rebinding[]`、把 hook 当成个数传进去，
/// 等于什么都没做 —— 真机日志 `[NetBlock] 自检 rc=0` 即由此而来.
void NetBlockApplyAfterGuestLoad(void) {
    fishhook_one("connect", (void *)hook_connect);
    fishhook_one("sendto", (void *)hook_sendto);
    fishhook_one("sendmsg", (void *)hook_sendmsg);
    fishhook_one("getaddrinfo", (void *)hook_getaddrinfo);
    fishhook_one("connectx", (void *)hook_connectx);
}

/// 访客镜像 dlopen 完成后调用：按**该镜像**的加载地址重绑.
///
/// 为什么不用 fishhook：iOS 26+ 的新二进制多是 chained fixups，fishhook 依赖
/// `__la_symbol_ptr` 改写，对这类镜像不生效 —— 表现就是「禁止联网开了但完全没用」。
/// litehook 直接在镜像里按导入表地址替换，能覆盖 chained fixups.
static int count_pointers_equal(const struct mach_header_64 *header, void *value) {
    if (!header) return 0;
    int found = 0;
    struct load_command *lcp = (void *)((uintptr_t)header + sizeof(struct mach_header_64));
    for (int i = 0; i < header->ncmds; i++) {
        if (lcp->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)lcp;
            if (!strncmp(seg->segname, "__DATA_CONST", 16) || !strncmp(seg->segname, "__DATA", 16) ||
                !strncmp(seg->segname, "__AUTH_CONST", 16)) {
                struct section_64 *sect = (struct section_64 *)((uintptr_t)lcp + sizeof(struct segment_command_64));
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    uint32_t type = sect[j].flags & 0xff;
                    if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
                    unsigned long size = 0;
                    uint8_t *start = getsectiondata(header, seg->segname, sect[j].sectname, &size);
                    if (!start) continue;
                    void **ptrs = (void **)start;
                    for (unsigned long k = 0; k < size / sizeof(void *); k++) {
                        if (ptrs[k] == value) found++;
                    }
                }
            }
        }
        lcp = (struct load_command *)((uintptr_t)lcp + lcp->cmdsize);
    }
    return found;
}

void NetBlockApplyAfterGuestLoadWithImage(const struct mach_header_64 *header) {
    if (!header) return;
    litehook_rebind_symbol((const mach_header_u *)header, connect, hook_connect, nil);
    litehook_rebind_symbol((const mach_header_u *)header, sendto, hook_sendto, nil);
    litehook_rebind_symbol((const mach_header_u *)header, sendmsg, hook_sendmsg, nil);
    litehook_rebind_symbol((const mach_header_u *)header, getaddrinfo, hook_getaddrinfo, nil);
    void *connectxSym = dlsym(RTLD_DEFAULT, "connectx");
    if (connectxSym) {
        litehook_rebind_symbol((const mach_header_u *)header, connectxSym, (void *)hook_connectx, nil);
    }
    int cConnect = count_pointers_equal(header, (void *)hook_connect);
    int cDNS = count_pointers_equal(header, (void *)hook_getaddrinfo);
    NSLog(@"[NetBlock] 已按访客镜像重绑 connect/connectx/sendto/sendmsg/getaddrinfo（校验 connect=%d dns=%d）",
          cConnect, cDNS);
}
