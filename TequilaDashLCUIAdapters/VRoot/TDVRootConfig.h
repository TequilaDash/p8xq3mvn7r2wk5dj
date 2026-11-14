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
// M41: dyld 镜像裁剪是否启用 (TD_DYLD_TRIM=1, 由 launcher 按 per-app hideLiveContainer 透传).
bool TDVDyldTrimEnabled(void);

// sysctl 伪值表 (TD_SYSCTL_SPOOF=1, 由 launcher 按 per-app sysctlSpoof 透传):
// 访客 sysctl/sysctlbyname 命中下表键时返回伪值 (检测器读 hw.machine /
// kern.osversion / kern.bootargs 一查一个准 —— libBroadpatch 190 符号审计结论).
// 命中伪值表返回 true 并写 out; 未启用/未命中返回 false (调用方透传真值).
// 伪值来源: TD_SYSCTL_<NAME> env (大写化, '.'->'_'), 未设则用内置默认.
bool TDVSysctlSpoofEnabled(void);
// name = 请求的 sysctl 名 (如 "hw.machine"). out/outSize 为伪值缓冲.
// 返回 true = 已伪值化 (调用方直接返回); false = 透传真 sysctl.
bool TDVSysctlSpoofLookup(const char *name, char *out, size_t outSize);

// SecTask entitlement 隐藏 (TD_SECTASK_SPOOF=1, launcher 按 per-app secTaskSpoof 透传):
// 访客 SecTaskCopyValueForEntitlement 查到宿主私有键时返回 NULL (键不存在语义),
// 防"读宿主 entitlement 看 LC/TD 痕迹"类检测. 合法键 (应用组/团队标识等) 透传真值.
bool TDVSecTaskSpoofEnabled(void);
// entitlement = 请求键名 (CFStringRef). 返回 true = 应答 NULL (调用方返回 NULL);
// false = 透传真实现. 仅对字符串型查询有意义, 数组型键 (application-groups) 永远透传.
bool TDVSecTaskHideEntitlement(const char *entitlement);

// csops 伪 CS flags (TD_CSOPS_SPOOF=1, launcher 按 per-app csopsSpoof 透传):
// 检测器经 csops(CS_OPS_STATUS) 读代码签名 flags: CS_DEBUGGED 0x10000000 =
// "调试器已附加"内核级判据, CS_GET_TASK_ALLOW 0x2000 = "可被调试"(侧载宿主必有
// get-task-allow). 伪表默认清除这两位; TD_CSOPS_KEEP_DEBUGGED=1 时保留
// CS_DEBUGGED (供我们自己的调试器探测链路继续工作).
bool TDVCsopsSpoofEnabled(void);
// 返回 true = *flagsOut 已伪值化 (调用方直接 copyout); false = 透传真 csops.
// flagsIn = 真 flags. 仅处理 CS_OPS_STATUS; 其余 ops 由 shim 层透传.
bool TDVCsopsSpoofLookup(unsigned int flagsIn, unsigned int *flagsOut);

// proc 族伪值 (TD_PROC_SPOOF=1, launcher 按 per-app procSpoof 透传):
// 访客枚举/探测进程信息时隐藏宿主与其它进程 (Reveil "Suspicious PFlag value"
// 的 kern.proc PFLAGS 通道也在内). 自身 pid 永远保留 (kill/wait 自身语义不破坏).
bool TDVProcSpoofEnabled(void);
// proc_listallpids 过滤回调: buffer 内逐 pid 保留判定. 返回保留数量.
int TDVProcFilterPids(pid_t *pids, int count);

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