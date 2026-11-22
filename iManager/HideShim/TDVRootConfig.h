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
#include <sys/types.h>

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
// 镜像裁剪是否真的生效 (DyldHooksInit 之后恒为 true; 实现见 LiveContainer/Tweaks/Dyld.m).
// task_info(TASK_DYLD_INFO) 副本的门控跟着它走: stable API 视图被裁剪后,
// task_info 侧必须给出同一个可见集合, 否则全能签 (NSKSign) 的
// stable-vs-task 对比 (_AISCollectStableApiVersusTask) 必红.
bool TDVDyldRemapActive(void);

// sysctl 伪值表 (TD_SYSCTL_SPOOF=1, 由 launcher 按 per-app sysctlSpoof 透传):
// 双通道: sysctlbyname 命中名称表返回伪值 (hw.machine / kern.osversion /
// kern.bootargs 一查一个准 —— libBroadpatch 190 符号审计结论); sysctl(3) 裸 MIB
// 只处理 [CTL_KERN, KERN_PROC, KERN_PROC_PID, self] 的 kinfo_proc.p_flag
// (清 P_TRACED/P_SELECT, Reveil 两条 PFlag 检查走这条).
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
// 访客身份替换 (同一 TD_SECTASK_SPOOF 开关): 请求键在访客安装时的原 profile
// (`.td-original.mobileprovision`) 的 entitlements 里有值时, 返回那份原值
// (CFString / CFArray, 已 CFRetain, 调用方负责释放), 让 bundle id / team id /
// keychain groups 不再暴露宿主身份, 也不要在 profile 本来有值时返回 NULL.
// 返回 NULL = 没有替换 (未启用 / 非访客 / 没有原 profile / 解析失败), 调用方保持
// 现有行为. entitlement = 请求键名, callerImage = 调用方镜像路径 (NULL = 未知).
void *TDVSecTaskReplacementForEntitlement(const char *entitlement, const char *callerImage);

// 文件级篡改检测虚拟化: 访客打开自己的主可执行文件或 embedded.mobileprovision 时,
// 换成安装时留下的原件. caller 必须在 LC 的本地或共享 Applications/<bundle>.app
// 目录下, 请求必须是同一 bundle 根的直接子文件; 宿主与未知 caller 始终透传.
// /var 与 /private/var 是同一系统路径的两种拼写, 不扩大到其它安装目录.
// 这里不设 env 开关: 只影响访客对自己包的读.
typedef enum {
    TDVGuestFileMapNone = 0,     // 原样透传
    TDVGuestFileMapTo = 1,       // 已写 out = 原件路径
    TDVGuestFileMapHidden = 2,   // 私有备份路径不可见; 原件缺失时不伪造文件存在性
} TDVGuestFileMapResult;

// imagePath 是否为 LC 本地或共享 Applications/<bundle>.app 内的访客镜像.
bool TDVGuestCallerIsGuestImage(const char *imagePath);
// The frame of the app code behind a file request.
//
// Foundation's NSFileHandle/NSData and libobjc's objc_msgSend sit between an app
// and the bytes it reads, and libc's open() is called by Foundation rather than
// by the app, so the return address inside such a hook is never the app's.
// This walks the stack and returns the first frame that is not one of the
// frameworks in between (and not our own shim), or NULL when there is none.
void *TDVGuestCallerFrame(void);
// caller 所在访客 bundle 目录 (绝对路径, 无尾斜杠). 非访客 / 解析失败 -> false.
bool TDVGuestBundleDirFromCallerImage(const char *callerImage, char *out, size_t outSize);
// path = 请求路径 (绝对), callerImage = 调用方镜像路径 (NULL = 未知).
// 命中时写 out (TDVGuestFileMapTo) 或要求 ENOENT (TDVGuestFileMapHidden).
TDVGuestFileMapResult TDVGuestMapBundleFile(const char *path, const char *callerImage,
                                            char *out, size_t outSize);

// csops 状态兼容视图 (TD_CSOPS_SPOOF=1, per-app csopsSpoof):
// 仅 guest 对自身 CS_OPS_STATUS 的查询补 CS_REQUIRE_LV (0x2000), 并按
// TD_CSOPS_KEEP_DEBUGGED 保留或清 CS_DEBUGGED (0x10000000). 其余 flags
// (包括 CS_GET_TASK_ALLOW 0x4) 保持内核值; 其它操作与非自身任务始终透传.
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

// 在 DyldHooksInit 的镜像裁剪之前安装一次 guest-only 的导入符号重绑.
// 门控仍在每次调用时读取, 不改宿主/其它端口的原生结果.
void TDVInstallGuestHooks(void);

/// task_info(TASK_DYLD_INFO) 副本可见索引上限（对齐 stable API remap 的容量）。
#define TDV_DYLD_INFO_MAX_VISIBLE 4096

/// Install the guest-only task_info(TASK_DYLD_INFO) interpose. Called by
/// TDVInstallGuestHooks once, before any guest can query its image list.
void TDVInstallTaskInfoHook(void);

/// Install the guest-only sigaction query spoof. Callers querying installed
/// handlers (act == NULL) see SIG_DFL; registering calls pass through.
void TDVInstallSigactionHook(void);

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