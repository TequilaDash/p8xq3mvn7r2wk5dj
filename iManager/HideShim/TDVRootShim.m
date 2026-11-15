//
//  TDVRootShim.m
//  TequilaDashLCUIAdapters
//
//  vroot (Tier A) libc 路径拦截层: __DATA,__interpose 表, 纯用户态, 默认关.
//
//  设计要点:
//    · 每个替换函数先 TDVRootMapPath, 命中则用映射后的绝对路径调原实现;
//      未命中 (开关关 / 非系统前缀 / LC 自身路径 / app group / 访客包) 原样透传.
//    · 原实现用显式 __asm 标签绑定裸符号 (_open/_stat/...), 与 Broadpatch
//      的 iOS 实测口径一致; 本镜像对自身 interpose 免疫, 直接调用不会递归.
//    · getuid/geteuid/getgid/getegid 只在 mode=full 返回 0.
//    · getmntinfo/getmntinfo_r_np 在真实挂载表末尾追加一条 vroot 项.
//    · M41: dyld 镜像清单裁剪 (_dyld_image_count/get_image_name/header/vmaddr_slide)
//    · stat64 有意不拦截: 64 位 iOS SDK 不声明 struct stat64, 访客全是 arm64,
//      没有安全的 interpose 拼写 (见交付报告).
//
//  明确不拦截: posix_spawn/exec (Tier B), fopen/NSFileManager (libc 底层已覆盖),
//  readlinkat/renameat/mkdirat 等其余 *at 变体, 以及 stat64 (见上).
//

#import "TDVRootConfig.h"
#import <Foundation/Foundation.h>

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/proc.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/syslimits.h>
#include <unistd.h>

#pragma mark - 原实现 (裸符号)

extern int tdv_real_open(const char *, int, ...) __asm("_open");
extern int tdv_real_openat(int, const char *, int, ...) __asm("_openat");
extern int tdv_real_open_nocancel(const char *, int, ...) __asm("___open_nocancel");
extern int tdv_real_stat(const char *, struct stat *) __asm("_stat");
extern int tdv_real_lstat(const char *, struct stat *) __asm("_lstat");
extern int tdv_real_fstatat(int, const char *, struct stat *, int) __asm("_fstatat");
extern int tdv_real_access(const char *, int) __asm("_access");
extern int tdv_real_faccessat(int, const char *, int, int) __asm("_faccessat");
extern char *tdv_real_realpath(const char *, char *) __asm("_realpath");
extern ssize_t tdv_real_readlink(const char *, char *, size_t) __asm("_readlink");
extern DIR *tdv_real_opendir(const char *) __asm("_opendir");
extern int tdv_real_mkdir(const char *, mode_t) __asm("_mkdir");
extern int tdv_real_rename(const char *, const char *) __asm("_rename");
extern int tdv_real_unlink(const char *) __asm("_unlink");
extern int tdv_real_getattrlist(const char *, void *, void *, size_t, unsigned long)
    __asm("_getattrlist");
extern int tdv_real_getmntinfo(struct statfs **, int) __asm("_getmntinfo");
extern int tdv_real_getmntinfo_r_np(struct statfs **, int) __asm("_getmntinfo_r_np");
extern uid_t tdv_real_getuid(void) __asm("_getuid");
extern uid_t tdv_real_geteuid(void) __asm("_geteuid");
extern gid_t tdv_real_getgid(void) __asm("_getgid");
extern gid_t tdv_real_getegid(void) __asm("_getegid");

#pragma mark - 访客可见性裁剪 (M37b: 隐藏 Tweaks 目录)

// LC 的 TweakLoader 在宿主/LC 核心镜像里运行, 必须能读 Tweaks;
// 只有**访客镜像** (dlopen 进来的 guest 二进制/动态库) 一律 ENOENT.
// 判据: __builtin_return_address(0) -> dladdr -> 镜像路径含 /Documents/Applications/.
static bool tdv_guest_caller_image(void *caller) {
    // 审计 §3.2.2: fail-closed —— caller 不可判定时按访客处理 (隐藏语义);
    // TweakLoader/LC 核心都在宿主镜像里, dladdr 必成功, 误伤面为零.
    Dl_info info;
    if (!caller || dladdr(caller, &info) == 0 || !info.dli_fname) return true;
    return strstr(info.dli_fname, "/Documents/Applications/") != NULL;
}

static bool tdv_hide_tweaks(const char *path, void *caller) {
    if (!path) return false;
    if (!strstr(path, "/Documents/Tweaks")) return false;
    return tdv_guest_caller_image(caller);
}

// 命中限流日志, 避免刷屏.
static void tdv_log_tweaks_hit(const char *fn, const char *path) {
    static _Atomic int hits = 0;
    int n = hits++;
    if (n < 5) {
        NSLog(@"[TDVRoot] 隐藏 Tweaks 目录命中 (%s): %s", fn, path);
    }
}

#pragma mark - 路径类替换

// 把 path 映射到 vroot; 命中返回映射指针, 否则返回原指针.
static inline const char *tdv_mapped(const char *path, char *buf, size_t bufSize) {
    if (path && path[0] == '/' && TDVRootMapPath(path, buf, bufSize)) {
        return buf;
    }
    return path;
}

static int tdv_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    bool hasMode = (flags & O_CREAT) != 0;
    if (hasMode) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    char buf[PATH_MAX];
    if (tdv_hide_tweaks(path, __builtin_return_address(0))) {
        tdv_log_tweaks_hit("open", path);
        errno = ENOENT;
        return -1;
    }
    const char *use = tdv_mapped(path, buf, sizeof(buf));
    if (hasMode) {
        return tdv_real_open(use, flags, mode);
    }
    return tdv_real_open(use, flags);
}

static int tdv_openat(int fd, const char *path, int flags, ...) {
    mode_t mode = 0;
    bool hasMode = (flags & O_CREAT) != 0;
    if (hasMode) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    char buf[PATH_MAX];
    if (tdv_hide_tweaks(path, __builtin_return_address(0))) {
        tdv_log_tweaks_hit("openat", path);
        errno = ENOENT;
        return -1;
    }
    // 相对路径不映射: 语义取决于 dirfd, 无法安全改写.
    const char *use = tdv_mapped(path, buf, sizeof(buf));
    if (hasMode) {
        return tdv_real_openat(fd, use, flags, mode);
    }
    return tdv_real_openat(fd, use, flags);
}

static int tdv_open_nocancel(const char *path, int flags, ...) {
    mode_t mode = 0;
    bool hasMode = (flags & O_CREAT) != 0;
    if (hasMode) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    char buf[PATH_MAX];
    const char *use = tdv_mapped(path, buf, sizeof(buf));
    if (hasMode) {
        return tdv_real_open_nocancel(use, flags, mode);
    }
    return tdv_real_open_nocancel(use, flags);
}

static int tdv_stat(const char *path, struct stat *sb) {
    if (tdv_hide_tweaks(path, __builtin_return_address(0))) {
        tdv_log_tweaks_hit("stat", path);
        errno = ENOENT;
        return -1;
    }
    char buf[PATH_MAX];
    return tdv_real_stat(tdv_mapped(path, buf, sizeof(buf)), sb);
}

static int tdv_lstat(const char *path, struct stat *sb) {
    if (tdv_hide_tweaks(path, __builtin_return_address(0))) {
        tdv_log_tweaks_hit("lstat", path);
        errno = ENOENT;
        return -1;
    }
    char buf[PATH_MAX];
    return tdv_real_lstat(tdv_mapped(path, buf, sizeof(buf)), sb);
}

static int tdv_fstatat(int fd, const char *path, struct stat *sb, int flags) {
    if (tdv_hide_tweaks(path, __builtin_return_address(0))) {
        tdv_log_tweaks_hit("fstatat", path);
        errno = ENOENT;
        return -1;
    }
    if (!path || path[0] != '/') {
        return tdv_real_fstatat(fd, path, sb, flags);
    }
    char buf[PATH_MAX];
    return tdv_real_fstatat(fd, tdv_mapped(path, buf, sizeof(buf)), sb, flags);
}

static int tdv_access(const char *path, int mode) {
    if (tdv_hide_tweaks(path, __builtin_return_address(0))) {
        tdv_log_tweaks_hit("access", path);
        errno = ENOENT;
        return -1;
    }
    char buf[PATH_MAX];
    return tdv_real_access(tdv_mapped(path, buf, sizeof(buf)), mode);
}

static int tdv_faccessat(int fd, const char *path, int mode, int flags) {
    if (!path || path[0] != '/') {
        return tdv_real_faccessat(fd, path, mode, flags);
    }
    char buf[PATH_MAX];
    return tdv_real_faccessat(fd, tdv_mapped(path, buf, sizeof(buf)), mode, flags);
}

static char *tdv_realpath(const char *path, char *resolved) {
    if (tdv_hide_tweaks(path, __builtin_return_address(0))) {
        tdv_log_tweaks_hit("realpath", path);
        errno = ENOENT;
        return NULL;
    }
    char buf[PATH_MAX];
    return tdv_real_realpath(tdv_mapped(path, buf, sizeof(buf)), resolved);
}

static ssize_t tdv_readlink(const char *path, char *buf, size_t bufSize) {
    char mapped[PATH_MAX];
    return tdv_real_readlink(tdv_mapped(path, mapped, sizeof(mapped)), buf, bufSize);
}

static DIR *tdv_opendir(const char *path) {
    if (tdv_hide_tweaks(path, __builtin_return_address(0))) {
        tdv_log_tweaks_hit("opendir", path);
        errno = ENOENT;
        return NULL;
    }
    char buf[PATH_MAX];
    return tdv_real_opendir(tdv_mapped(path, buf, sizeof(buf)));
}

static int tdv_mkdir(const char *path, mode_t mode) {
    char buf[PATH_MAX];
    return tdv_real_mkdir(tdv_mapped(path, buf, sizeof(buf)), mode);
}

static int tdv_rename(const char *from, const char *to) {
    char fromBuf[PATH_MAX];
    char toBuf[PATH_MAX];
    const char *newFrom = tdv_mapped(from, fromBuf, sizeof(fromBuf));
    const char *newTo = tdv_mapped(to, toBuf, sizeof(toBuf));
    return tdv_real_rename(newFrom, newTo);
}

static int tdv_unlink(const char *path) {
    char buf[PATH_MAX];
    return tdv_real_unlink(tdv_mapped(path, buf, sizeof(buf)));
}

static int tdv_getattrlist(const char *path, void *attrList, void *attrBuf,
                           size_t attrBufSize, unsigned long options) {
    char buf[PATH_MAX];
    return tdv_real_getattrlist(tdv_mapped(path, buf, sizeof(buf)),
                                attrList, attrBuf, attrBufSize, options);
}

#pragma mark - getmntinfo 追加 vroot 项

static struct statfs *gTDVMntCache = NULL;
static size_t gTDVMntCacheCount = 0;
static pthread_mutex_t gTDVMntLock = PTHREAD_MUTEX_INITIALIZER;

static void tdv_fill_fake_mount(struct statfs *fs) {
    memset(fs, 0, sizeof(*fs));
    fs->f_bsize = 4096;
    fs->f_iosize = 4096;
    fs->f_blocks = 1000000;
    fs->f_bfree = 500000;
    fs->f_bavail = 500000;
    fs->f_files = 100000;
    fs->f_ffree = 90000;
    fs->f_fsid.val[0] = 0x1337;
    fs->f_fsid.val[1] = 0xbeef;
    fs->f_owner = 0;
    fs->f_flags = MNT_LOCAL | MNT_ROOTFS;
    strlcpy(fs->f_fstypename, "apfs", sizeof(fs->f_fstypename));
    const char *root = TDVRootRootPath();
    strlcpy(fs->f_mntonname, root ? root : "/", sizeof(fs->f_mntonname));
    strlcpy(fs->f_mntfromname, "tdvroot", sizeof(fs->f_mntfromname));
}

static int tdv_getmntinfo(struct statfs **mntbufp, int flags) {
    struct statfs *raw = NULL;
    int n = tdv_real_getmntinfo(&raw, flags);
    if (n <= 0) {
        if (mntbufp) {
            *mntbufp = raw;
        }
        return n;
    }
    if (!TDVRootIsEnabled()) {
        if (mntbufp) {
            *mntbufp = raw;
        }
        return n;
    }

    int savedErrno = errno;
    pthread_mutex_lock(&gTDVMntLock);
    size_t need = (size_t)n + 1;
    if (need > gTDVMntCacheCount) {
        struct statfs *grown = realloc(gTDVMntCache, need * sizeof(struct statfs));
        if (!grown) {
            pthread_mutex_unlock(&gTDVMntLock);
            errno = savedErrno;
            if (mntbufp) {
                *mntbufp = raw;
            }
            return n;
        }
        gTDVMntCache = grown;
        gTDVMntCacheCount = need;
    }
    memcpy(gTDVMntCache, raw, (size_t)n * sizeof(struct statfs));
    tdv_fill_fake_mount(&gTDVMntCache[n]);
    if (mntbufp) {
        *mntbufp = gTDVMntCache;
    }
    pthread_mutex_unlock(&gTDVMntLock);
    errno = savedErrno;
    return n + 1;
}

static int tdv_getmntinfo_r_np(struct statfs **mntbufp, int flags) {
    struct statfs *raw = NULL;
    int n = tdv_real_getmntinfo_r_np(&raw, flags);
    if (n <= 0) {
        if (mntbufp) {
            *mntbufp = raw;
        }
        return n;
    }
    if (!TDVRootIsEnabled()) {
        if (mntbufp) {
            *mntbufp = raw;
        }
        return n;
    }

    int savedErrno = errno;
    struct statfs *out = malloc(((size_t)n + 1) * sizeof(struct statfs));
    if (!out) {
        errno = savedErrno;
        if (mntbufp) {
            *mntbufp = raw;
        }
        return n;
    }
    memcpy(out, raw, (size_t)n * sizeof(struct statfs));
    tdv_fill_fake_mount(&out[n]);
    free(raw); // getmntinfo_r_np 的缓冲区归调用方所有; 换成我们分配的扩容副本.
    if (mntbufp) {
        *mntbufp = out;
    }
    errno = savedErrno;
    return n + 1;
}

#pragma mark - 凭据伪造 (仅 full)

static uid_t tdv_getuid(void) {
    return TDVRootCurrentMode() == TDVRootModeFull ? 0 : tdv_real_getuid();
}

static uid_t tdv_geteuid(void) {
    return TDVRootCurrentMode() == TDVRootModeFull ? 0 : tdv_real_geteuid();
}

static gid_t tdv_getgid(void) {
    return TDVRootCurrentMode() == TDVRootModeFull ? 0 : tdv_real_getgid();
}

static gid_t tdv_getegid(void) {
    return TDVRootCurrentMode() == TDVRootModeFull ? 0 : tdv_real_getegid();
}

#pragma mark - sysctl 伪值表 (TD_SYSCTL_SPOOF)

// 检测器高频查询: hw.machine / kern.osversion / kern.bootargs (按名) 与
// kern.proc PFLAGS (裸 MIB). 两个入口是不同符号, 必须分别拦:
//   · sysctlbyname(name)   -> 名值表 (TDVSysctlSpoofLookup)
//   · sysctl(mib, namelen) -> 自身 kinfo_proc 的 p_flag 清洗 (见下)
// 未启用/未命中一律透传真实现 (fail-open 与本 shim 其余层一致).
// 门控数据源与伪值表在 TDVRootConfig (TDVSysctlSpoofEnabled / TDVSysctlSpoofLookup).
extern int tdv_real_sysctlbyname(const char *, void *, size_t *, void *, size_t)
    __asm("_sysctlbyname");

static int tdv_sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                            void *newp, size_t newlen) {
    if (name && oldp && oldlenp && *oldlenp > 0 && !newp) {
        char spoof[128];
        if (TDVSysctlSpoofLookup(name, spoof, sizeof(spoof))) {
            size_t want = strlen(spoof) + 1; // 含 NUL, 与内核字符串 sysctl 语义一致
            if (*oldlenp >= want) {
                memcpy(oldp, spoof, want);
                *oldlenp = want;
                return 0;
            }
            // 缓冲不足: 与真实 sysctl 一致, 返回 ENOMEM 并回写需要的长度.
            *oldlenp = want;
            return -1;
        }
    }
    return tdv_real_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

// 裸 MIB 通道: Reveil 的两条 PFlag 检查都读
//   mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()] -> struct kinfo_proc
//     · DebuggerChecker:                kp_proc.p_flag & P_TRACED (0x800)
//     · ReverseEngineeringToolsChecker: kp_proc.p_flag & P_SELECT (0x40)
// sysctlbyname 拦不到这条 (不同符号). 只伪化"查自身"这一条 MIB: 别的 pid /
// KERN_PROC_ALL / 非 proc 子树一律透传 —— 跨进程语义不由本进程决定.
extern int tdv_real_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                           void *newp, size_t newlen) __asm("_sysctl");

static int tdv_sysctl_impl(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                           void *newp, size_t newlen) {
    int rc = tdv_real_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (rc != 0 || newp != NULL || !oldp || !oldlenp) return rc;
    if (!TDVSysctlSpoofEnabled() || !name || namelen != 4) return rc;
    if (name[0] != CTL_KERN || name[1] != KERN_PROC || name[2] != KERN_PROC_PID) return rc;
    if (name[3] != getpid()) return rc;
    if (*oldlenp < sizeof(struct kinfo_proc)) return rc;
    struct kinfo_proc *kp = (struct kinfo_proc *)oldp;
    kp->kp_proc.p_flag &= ~(P_TRACED | P_SELECT);
    return rc;
}

#pragma mark - SecTask entitlement 隐藏 (TD_SECTASK_SPOOF)

// 检测器经 SecTaskCopyValueForEntitlement 读宿主任务 entitlement: 命中宿主私有键
// (get-task-allow / com.apple.private.* / com.apple.developer.* / 注入框架前缀)
// 即暴露侧载+注入宿主身份. 隐藏语义 = 返回 NULL 且 *error 清空 (与"键不存在"
// 完全同形). 合法键 (application-groups / team-identifier 等) 透传 —— 宿主自身
// 的 td_signed_app_groups (worse_query.m:133) 依赖 application-groups, 不能误伤.
// 门控与键表在 TDVRootConfig (TDVSecTaskSpoofEnabled / TDVSecTaskHideEntitlement).
typedef struct __SecTask *tdv_SecTaskRef;

extern void *tdv_real_sectask_copy(tdv_SecTaskRef task, CFStringRef entitlement,
                                   void **error)
    __asm("_SecTaskCopyValueForEntitlement");

static void *tdv_sectask_copy_impl(tdv_SecTaskRef task, CFStringRef entitlement,
                                   void **error) {
    // entitlement 是 CFStringRef (Foundation 已 import, CF 类型直接可用);
    // CFStringGetCString 不经 interpose, 无递归风险.
    char name[256];
    Boolean ok = false;
    if (entitlement) {
        ok = CFStringGetCString(entitlement, name, sizeof(name), kCFStringEncodingUTF8);
    }
    if (ok && TDVSecTaskHideEntitlement(name)) {
        if (error) *error = NULL;
        return NULL;
    }
    return tdv_real_sectask_copy(task, entitlement, error);
}

#pragma mark - csops 伪 CS flags (TD_CSOPS_SPOOF)

// 检测器两个通道读同一组内核 flags: csops(pid, CS_OPS_STATUS) 与
// csops_audittoken(token, CS_OPS_STATUS). 拦 CS_OPS_STATUS, 清
// CS_GET_TASK_ALLOW (侧载宿主必有, 必露) 与 CS_DEBUGGED (调试器判据,
// TD_CSOPS_KEEP_DEBUGGED=1 时保留给宿主自己的调试器探测链路).
// 其余 ops (CS_OPS_MARKINVALID 等) 与 pid!=self 的查询透传.
// 位定义与门控在 TDVRootConfig (TDVCsopsSpoofEnabled / TDVCsopsSpoofLookup).
extern int tdv_real_csops(int pid, unsigned int ops, void *useraddr, size_t usersize)
    __asm("_csops");
extern int tdv_real_csops_audittoken(void *token, unsigned int ops, void *useraddr,
                                     size_t usersize)
    __asm("_csops_audittoken");

static int tdv_csops_apply(unsigned int ops, void *useraddr, size_t usersize,
                           int realRc) {
    if (ops == 0 /*CS_OPS_STATUS*/ && realRc == 0 && useraddr &&
        usersize >= sizeof(unsigned int)) {
        unsigned int fake = 0;
        memcpy(&fake, useraddr, sizeof(unsigned int));
        if (TDVCsopsSpoofLookup(fake, &fake)) {
            memcpy(useraddr, &fake, sizeof(unsigned int));
        }
    }
    return realRc;
}

static int tdv_csops_impl(int pid, unsigned int ops, void *useraddr, size_t usersize) {
    // 仅伪化自身 pid 查询 (getpid 同进程恒等; 跨 pid 查询给真值 —— 访客无权跨进程读).
    int rc = tdv_real_csops(pid, ops, useraddr, usersize);
    return tdv_csops_apply(ops, useraddr, usersize, rc);
}

static int tdv_csops_audittoken_impl(void *token, unsigned int ops, void *useraddr,
                                     size_t usersize) {
    int rc = tdv_real_csops_audittoken(token, ops, useraddr, usersize);
    return tdv_csops_apply(ops, useraddr, usersize, rc);
}

#pragma mark - proc 族伪值 (TD_PROC_SPOOF)

#include <mach/mach.h>
#include <spawn.h>
// 私有 bootstrap_look_up2 (launchd bootstrap 子系统): iOS SDK 无
// servers/bootstrap.h, 常量与类型手写 (broadpatch decomp 交叉验证).
#ifndef BOOTSTRAP_UNKNOWN_SERVICE
#define BOOTSTRAP_UNKNOWN_SERVICE 4451
#endif
typedef char tdv_name_t[128];

// Reveil "Suspicious PFlag value" 走 kern.proc PFLAGS 通道; proc_pidpath 对
// 非自身 pid 的查询暴露宿主进程路径. 拦截面:
//   · proc_listallpids: 只保留自身 (宿主/其它进程全隐藏, 自身 kill/wait 不破坏)
//   · proc_pidpath: pid==self 透传 (访客 app 真实路径, 无泄漏); pid!=self → ENOENT
//   · proc_name: 同 pidpath 语义
// 门控与过滤在 TDVRootConfig (TDVProcSpoofEnabled / TDVProcFilterPids).
// kern.proc 裸 MIB 通道 (sysctl(3)) 不拦 —— Reveil 的 PFlag 检测走 proc_listallpids
// + proc_pidinfo 组合, 裸 MIB 需 fishhook (第三批 task_info 同批).
extern int tdv_real_proc_listallpids(void *buffer, int buffersize)
    __asm("_proc_listallpids");
extern int tdv_real_proc_pidpath(int pid, void *buffer, uint32_t buffersize)
    __asm("_proc_pidpath");
extern int tdv_real_proc_name(int pid, void *buffer, uint32_t buffersize)
    __asm("_proc_name");

static int tdv_proc_listallpids_impl(void *buffer, int buffersize) {
    int n = tdv_real_proc_listallpids(buffer, buffersize);
    if (n <= 0 || !buffer) return n;
    return TDVProcFilterPids((pid_t *)buffer, n);
}

static int tdv_proc_pidpath_impl(int pid, void *buffer, uint32_t buffersize) {
    if (TDVProcSpoofEnabled() && pid != getpid()) {
        return 0;  // ENOENT: 非自身进程不可见
    }
    return tdv_real_proc_pidpath(pid, buffer, buffersize);
}

static int tdv_proc_name_impl(int pid, void *buffer, uint32_t buffersize) {
    if (TDVProcSpoofEnabled() && pid != getpid()) {
        return 0;
    }
    return tdv_real_proc_name(pid, buffer, buffersize);
}

#pragma mark - bootstrap 服务名探测 (TD_PROC_SPOOF 同门控)

// 检测器探测 XPC 服务名 (bootstrap_look_up) 判断宿主身份: 命中宿主/注入框架
// 前缀的服务名返回 unknown_service (与真实不存在的服务同形). 其它服务名透传.
extern kern_return_t tdv_real_bootstrap_look_up(mach_port_t bp, tdv_name_t service_name,
                                                mach_port_t *sp, uint64_t flags, uint64_t *version)
    __asm("_bootstrap_look_up2");

static kern_return_t tdv_bootstrap_look_up2_impl(mach_port_t bp, tdv_name_t service_name,
                                                 mach_port_t *sp, uint64_t flags, uint64_t *version) {
    if (TDVProcSpoofEnabled() && service_name) {
        static const char *kServicePrefixes[] = {
            "org.tequila.", "td.", "org.emexlabs.",
            "com.apple.private.xpc.",
        };
        for (size_t i = 0; i < sizeof(kServicePrefixes) / sizeof(kServicePrefixes[0]); i++) {
            if (strncmp(service_name, kServicePrefixes[i], strlen(kServicePrefixes[i])) == 0) {
                return BOOTSTRAP_UNKNOWN_SERVICE;
            }
        }
    }
    return tdv_real_bootstrap_look_up(bp, service_name, sp, flags, version);
}




#pragma mark - posix_spawn env 重放 (TD_PROC_SPOOF 同门控)

// 访客 spawn 出来的子进程不会继承我们的门控 env (scrub 在访客自己进程内做,
// 只清不播). 若访客再 spawn 工具进程 (tar/sh), 子进程里 sysctl/proc 查询不带
// 门控 = 隐藏面出现旁路. 策略: interpose posix_spawn/spawnp, spawn 前把当前
// 进程仍存活的 TD_* 门控 env 复制进 child env (attr 的 envp 参数追加).
// 门控键清单与 LCBootstrap TDScrubGuestEnv 保持同步.
extern int tdv_real_posix_spawn(pid_t *pid, const char *path,
                                const posix_spawn_file_actions_t *fa,
                                const posix_spawnattr_t *attr,
                                char *const argv[], char *const envp[])
    __asm("_posix_spawn");
extern int tdv_real_posix_spawnp(pid_t *pid, const char *path,
                                 const posix_spawn_file_actions_t *fa,
                                 const posix_spawnattr_t *attr,
                                 char *const argv[], char *const envp[])
    __asm("_posix_spawnp");

static const char *kTDGateKeys[] = {
    "TD_NET_BLOCK", "TD_VROOT", "TD_VROOT_MODE", "TD_DYLD_TRIM",
    "TD_GLOBAL_HIDE", "TD_SYSCTL_SPOOF", "TD_SECTASK_SPOOF", "TD_CSOPS_SPOOF",
    "TD_CSOPS_KEEP_DEBUGGED", "TD_PROC_SPOOF",
};

static char **tdv_build_gated_envp(char *const envp[]) {
    // 收集当前仍设置的 TD_* 门控 → "K=V" 字符串
    char *gated[sizeof(kTDGateKeys) / sizeof(kTDGateKeys[0])];
    int gatedN = 0;
    for (size_t i = 0; i < sizeof(kTDGateKeys) / sizeof(kTDGateKeys[0]); i++) {
        const char *v = getenv(kTDGateKeys[i]);
        if (!v) continue;
        size_t need = strlen(kTDGateKeys[i]) + strlen(v) + 2;
        char *kv = malloc(need);
        if (!kv) continue;
        snprintf(kv, need, "%s=%s", kTDGateKeys[i], v);
        gated[gatedN++] = kv;
    }
    if (gatedN == 0) return NULL;  // 无门控 env, 不改 envp

    // 数原 envp 长度
    int baseN = 0;
    while (envp && envp[baseN]) baseN++;
    char **out = malloc((baseN + gatedN + 1) * sizeof(char *));
    if (!out) { for (int i = 0; i < gatedN; i++) free(gated[i]); return NULL; }
    int w = 0;
    for (int i = 0; i < baseN; i++) out[w++] = envp[i];
    for (int i = 0; i < gatedN; i++) out[w++] = gated[i];  // 门控键追加在后, 覆盖同名项
    out[w] = NULL;
    return out;
}

static int tdv_spawn_apply(char *const envp[], char ***outEnvp) {
    if (!TDVProcSpoofEnabled()) return 0;
    *outEnvp = tdv_build_gated_envp(envp);
    return (*outEnvp != NULL) ? 1 : 0;
}

static int tdv_posix_spawn_impl(pid_t *pid, const char *path,
                                const posix_spawn_file_actions_t *fa,
                                const posix_spawnattr_t *attr,
                                char *const argv[], char *const envp[]) {
    char **newEnvp = NULL;
    int built = tdv_spawn_apply(envp, &newEnvp);
    int rc = tdv_real_posix_spawn(pid, path, fa, attr, argv, built ? newEnvp : envp);
    if (built) { for (char **e = newEnvp; *e; e++) free(*e); free(newEnvp); }
    return rc;
}

static int tdv_posix_spawnp_impl(pid_t *pid, const char *path,
                                 const posix_spawn_file_actions_t *fa,
                                 const posix_spawnattr_t *attr,
                                 char *const argv[], char *const envp[]) {
    char **newEnvp = NULL;
    int built = tdv_spawn_apply(envp, &newEnvp);
    int rc = tdv_real_posix_spawnp(pid, path, fa, attr, argv, built ? newEnvp : envp);
    if (built) { for (char **e = newEnvp; *e; e++) free(*e); free(newEnvp); }
    return rc;
}

#pragma mark - interpose 表

// dyld 用 replacee 的符号名做替换; replacement 指向本文件的实现.
// 本镜像对自己的调用不受该表影响, 因此替换函数里可以直接调原实现.
#define TDV_INTERPOSE(replacement, replacee)                                          \
    __attribute__((used)) static struct {                                             \
        const void *replacement;                                                      \
        const void *replacee;                                                         \
    } tdv_interpose_##replacement __attribute__((section("__DATA,__interpose"))) = {  \
        (const void *)(uintptr_t)&replacement,                                        \
        (const void *)(uintptr_t)&replacee,                                           \
    }

TDV_INTERPOSE(tdv_open, tdv_real_open);
TDV_INTERPOSE(tdv_openat, tdv_real_openat);
TDV_INTERPOSE(tdv_open_nocancel, tdv_real_open_nocancel);
TDV_INTERPOSE(tdv_stat, tdv_real_stat);
TDV_INTERPOSE(tdv_lstat, tdv_real_lstat);
TDV_INTERPOSE(tdv_fstatat, tdv_real_fstatat);
TDV_INTERPOSE(tdv_access, tdv_real_access);
TDV_INTERPOSE(tdv_faccessat, tdv_real_faccessat);
TDV_INTERPOSE(tdv_realpath, tdv_real_realpath);
TDV_INTERPOSE(tdv_readlink, tdv_real_readlink);
TDV_INTERPOSE(tdv_opendir, tdv_real_opendir);
TDV_INTERPOSE(tdv_mkdir, tdv_real_mkdir);
TDV_INTERPOSE(tdv_rename, tdv_real_rename);
TDV_INTERPOSE(tdv_unlink, tdv_real_unlink);
TDV_INTERPOSE(tdv_getattrlist, tdv_real_getattrlist);
TDV_INTERPOSE(tdv_getmntinfo, tdv_real_getmntinfo);
TDV_INTERPOSE(tdv_getmntinfo_r_np, tdv_real_getmntinfo_r_np);
TDV_INTERPOSE(tdv_getuid, tdv_real_getuid);
TDV_INTERPOSE(tdv_geteuid, tdv_real_geteuid);
TDV_INTERPOSE(tdv_getgid, tdv_real_getgid);
TDV_INTERPOSE(tdv_getegid, tdv_real_getegid);
TDV_INTERPOSE(tdv_sysctlbyname, tdv_real_sysctlbyname);
TDV_INTERPOSE(tdv_sysctl_impl, tdv_real_sysctl);
TDV_INTERPOSE(tdv_sectask_copy_impl, tdv_real_sectask_copy);
static CFDictionaryRef tdv_sectask_copy_values_impl(tdv_SecTaskRef task,
                                                    CFArrayRef entitlements,
                                                    void **error);
extern CFDictionaryRef tdv_real_sectask_copy_values(tdv_SecTaskRef task,
                                                    CFArrayRef entitlements,
                                                    void **error)
    __asm("_SecTaskCopyValuesForEntitlements");
TDV_INTERPOSE(tdv_sectask_copy_values_impl, tdv_real_sectask_copy_values);
TDV_INTERPOSE(tdv_csops_impl, tdv_real_csops);
TDV_INTERPOSE(tdv_csops_audittoken_impl, tdv_real_csops_audittoken);
TDV_INTERPOSE(tdv_proc_listallpids_impl, tdv_real_proc_listallpids);
TDV_INTERPOSE(tdv_proc_pidpath_impl, tdv_real_proc_pidpath);
TDV_INTERPOSE(tdv_proc_name_impl, tdv_real_proc_name);
TDV_INTERPOSE(tdv_bootstrap_look_up2_impl, tdv_real_bootstrap_look_up);
TDV_INTERPOSE(tdv_posix_spawn_impl, tdv_real_posix_spawn);
TDV_INTERPOSE(tdv_posix_spawnp_impl, tdv_real_posix_spawnp);
#pragma mark - SecTask 复数/audit-token 通道 (TD_SECTASK_SPOOF 同门控)

// 绕过口子封堵: 单数 CopyValueForEntitlement 拦了, 但检测器可用
//   · SecTaskCopyValuesForEntitlements (CFDictionaryRef 一次拿多键)
//   · SecTaskCreateWithAuditToken + CopyValueForEntitlement (经 token 建任务再查)
// 两条通道绕过. 复数通道策略: 逐键过 TDVSecTaskHideEntitlement, 命中键从入参
// entitlements 数组剔除后调原实现 (返回字典少键 = 键不存在同形); 全部命中则
// 传空数组. WithAuditToken 通道: Create 本身不泄数据, 只需拦后续 Copy ——
// Copy 的 task 参数与 self 同进程, 单数拦截天然覆盖, 无需额外处理.
static CFDictionaryRef tdv_sectask_copy_values_impl(tdv_SecTaskRef task,
                                                    CFArrayRef entitlements,
                                                    void **error) {
    if (!TDVSecTaskSpoofEnabled() || entitlements == NULL) {
        return tdv_real_sectask_copy_values(task, entitlements, error);
    }
    CFIndex n = CFArrayGetCount(entitlements);
    bool anyHidden = false;
    CFMutableArrayRef filtered = CFArrayCreateMutableCopy(kCFAllocatorDefault, n, entitlements);
    if (filtered == NULL) {
        return tdv_real_sectask_copy_values(task, entitlements, error);
    }
    // 从后往前剔除命中键 (避免索引位移).
    for (CFIndex i = n - 1; i >= 0; i--) {
        CFStringRef key = (CFStringRef)CFArrayGetValueAtIndex(entitlements, i);
        char name[256];
        if (key && CFStringGetCString(key, name, sizeof(name), kCFStringEncodingUTF8) &&
            TDVSecTaskHideEntitlement(name)) {
            CFArrayRemoveValueAtIndex(filtered, i);
            anyHidden = true;
        }
    }
    if (!anyHidden) {
        CFRelease(filtered);
        return tdv_real_sectask_copy_values(task, entitlements, error);
    }
    CFDictionaryRef result = tdv_real_sectask_copy_values(task, filtered, error);
    CFRelease(filtered);
    return result;
}
