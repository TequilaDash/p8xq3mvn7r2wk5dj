//
//  TDVRootConfig.h
//  TequilaDashLCUIAdapters
//
//  vroot (Tier A) 纯用户态路径前缀重定向配置. 默认关, 由 per-app
//  LCAppInfo.plist 的 TDVRoot 开关经 LiveProcessDebugLauncher -> LiveProcess/main.m
//  -> 环境变量 TD_VROOT / TD_VROOT_MODE 打开 (mode: off | path | full).
//
//  语义 (与 roothide/libvroot 同范式, 但不碰 dyld / 签名 / mount):
//    · TD_VROOT 是绝对路径的 vroot 根 ($JBROOT 语义, 无尾斜杠).
//    · 内置前缀表把 /usr /bin /sbin /etc /opt /var/jb 下的绝对路径映射到根内;
//      /System /Library /dev /private/var/mobile/... 保持真路径.
//    · LC 自身 dylib / app group / Documents/Applications 访客包一律不映射.
//    · mode=full 时 getuid/geteuid/getgid/getegid 返回 0, HOME/CFFIXED_USER_HOME
//      指向 vroot 根; mode=path 只做路径映射并前置 PATH.
//

#ifndef TDVRootConfig_h
#define TDVRootConfig_h

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    TDVRootModeOff = 0,
    TDVRootModePath = 1,
    TDVRootModeFull = 2,
} TDVRootMode;

/// 环境变量是否已打开 vroot (TD_VROOT 为绝对路径且 mode != off).
bool TDVRootIsEnabled(void);

/// 当前模式; 未启用返回 TDVRootModeOff.
TDVRootMode TDVRootCurrentMode(void);

/// vroot 根 (绝对路径, 无尾斜杠); 未启用返回 NULL.
const char *TDVRootRootPath(void);

/// 把绝对路径映射进 vroot. 命中内置前缀时写 out 并返回 true;
/// 未启用 / 不是绝对路径 / 命中排除表 / outSize 不足 -> false (调用方用原路径).
/// 不改变 errno.
bool TDVRootMapPath(const char *path, char *out, size_t outSize);

/// 该路径是否必须保持真实路径 (LC 自身镜像 / app group / 访客包 / 已在 vroot 内).
bool TDVRootShouldSkipPath(const char *path);

/// 从环境重读配置 (幂等). 由 LCBootstrap 在 DyldHooksInit 之前调用:
/// 进程早期的 interpose 调用可能在 main.m 落环境变量之前就把配置读成 off,
/// 这里是唯一的强制重新求值点.
void TDVRootInstallIfRequested(void);

/// mode=full: 覆盖 HOME/CFFIXED_USER_HOME 为 vroot 根;
/// path/full: 把 vroot 的 bin 目录前置到 PATH.
/// 必须由 LCBootstrap 在既有 HOME/CFFIXED_USER_HOME 覆盖之后调用.
void TDVRootApplyEnvironmentOverrides(void);

#ifdef __cplusplus
}
#endif

#endif /* TDVRootConfig_h */