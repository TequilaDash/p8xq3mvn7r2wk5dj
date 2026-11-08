//
//  NetworkBlock.m
//  LiveContainer (TequilaDash 适配)
//
//  联网管理 (owner 2026-11-08 需求, LC 没有的功能): 宿主侧按容器记录开关
//  (defaults "TDNetBlock-<bundleId>", 启动时写入 defaults "TDGuestNetBlock",
//  HostGuestEntry.m 转 TD_NET_BLOCK 环境变量), 本文件在访客 hook 顺序块里
//  拦截对外 TCP connect —— 命中即 EPERM.
//
//  覆盖口径 (诚实): 拦 BSD connect (TCP 出站); UDP/DNS 与 POSIX spawn 家族未拦,
//  属 v2 范围. 钩子安装分两层: litehook 全局重绑 (已载入镜像) + fishhook 重绑
//  (访客镜像 dlopen 之后的延迟绑定), 调用点在 LCBootstrap.m (dlopen 成功后).
//

#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <errno.h>
#import "litehook.h"
#import "fishhook.h"

static int hook_connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    errno = EPERM;
    return -1;
}

/// dlopen 访客**之前**调用: 重绑已载入镜像 (宿主侧) 的 connect.
void NetBlockGuestHooksInit(void) {
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, connect, hook_connect, nil);
}

/// dlopen 访客**之后**调用: fishhook 补访客镜像的延迟绑定.
void NetBlockApplyAfterGuestLoad(void) {
    rebind_symbols((char *)"connect", hook_connect);
}
