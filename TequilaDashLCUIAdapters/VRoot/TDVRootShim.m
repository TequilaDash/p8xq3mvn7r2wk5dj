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
#include <sys/stat.h>
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

#pragma mark - dyld 镜像清单裁剪 (M41)

// 目标: 访客 _dyld_image_count/_dyld_get_image_* 看不到宿主注入层.
// Reveil 类检测器枚举镜像列表即现形 (owner 2026-11-14 截图实证)。
// 过滤规则 (整行删除, 不是改名):
//   · 宿主 app bundle 目录前缀 (image0 实路径推导, 主执行文件本身保留);
//   · LC/内嵌工具链特征串 (LiveContainer/ZSign/OpenSSL/TweakLoader/CydiaSubstrate);
//   · Documents/Tweaks/ 下的 tweak dylib。
// 公开 API 直接声明 (mach-o/dyld.h); 本镜像自身调用走 dyld 同镜像豁免, 不会被我们的
// interpose 表拦到, 所以 impl 内直接调这些函数就是"原实现".
#include <mach-o/dyld.h>
#define tdv_real_dyld_image_count _dyld_image_count
#define tdv_real_dyld_get_image_name _dyld_get_image_name
#define tdv_real_dyld_get_image_header _dyld_get_image_header
#define tdv_real_dyld_get_image_vmaddr_slide _dyld_get_image_vmaddr_slide

static pthread_mutex_t gTDVDyldLock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t gTDVDyldRealCount = 0;
static uint32_t gTDVDyldKept[512];
static uint32_t gTDVDyldKeptCount = 0;
static char gTDVDyldHostDir[PATH_MAX] = {0};

static bool tdv_dyld_hidden_path(const char *path) {
    if (!path || path[0] != '/') return false;
    if (gTDVDyldHostDir[0] && strncmp(path, gTDVDyldHostDir, strlen(gTDVDyldHostDir)) == 0 &&
        (path[strlen(gTDVDyldHostDir)] == '/' || path[strlen(gTDVDyldHostDir)] == '\0')) {
        return true;
    }
    static const char *kMarks[] = {
        "/Frameworks/LiveContainerSwiftUI",
        "/Frameworks/LiveContainerShared",
        "/Frameworks/LiveContainer",
        "/Frameworks/TweakLoader",
        "/Frameworks/CydiaSubstrate",
        "/Frameworks/ZSign",
        "/Frameworks/OpenSSL",
        "/Documents/Tweaks/",
    };
    for (size_t i = 0; i < sizeof(kMarks) / sizeof(kMarks[0]); i++) {
        if (strstr(path, kMarks[i])) return true;
    }
    return false;
}

// M41 门控 (0.3.884): 与上游完全同构 —— 只有该访客开了 hideLiveContainer 才裁剪
// 镜像清单; 默认关闭, 保证基线行为与上游 LC 逐字节一致 (owner 2026-11-14 指令).
static bool tdv_dyld_trim_enabled(void) {
    // M41 门控数据源: launcher 读 per-app LCAppInfo["hideLiveContainer"] -> payload ->
    // main.m setenv("TD_DYLD_TRIM") -> TDVRootConfig 在 install 时捕获进内存.
    // (不能在这里读 LC 分类: TDVRootShim 属 LCUIAdapters target, 看不见 vendor utils.h.)
    extern bool TDVDyldTrimEnabled(void);
    return TDVDyldTrimEnabled();
}

static void tdv_dyld_rebuild_locked(void) {
    uint32_t real = tdv_real_dyld_image_count();
    const char *img0 = real > 0 ? tdv_real_dyld_get_image_name(0) : NULL;
    if (img0 && !gTDVDyldHostDir[0]) {
        // 主执行文件所在目录 = 宿主 .app 目录 (只记录一次).
        const char *slash = strrchr(img0, '/');
        if (slash) {
            size_t n = (size_t)(slash - img0);
            if (n >= sizeof(gTDVDyldHostDir)) n = sizeof(gTDVDyldHostDir) - 1;
            memcpy(gTDVDyldHostDir, img0, n);
            gTDVDyldHostDir[n] = '\0';
        }
    }
    if (!tdv_dyld_trim_enabled()) {
        // 与上游一致: 不过滤, kept = 0..real 全保留.
        if (gTDVDyldRealCount != real || gTDVDyldKeptCount != real) {
            gTDVDyldRealCount = real;
            uint32_t kept = 0;
            for (uint32_t i = 0; i < real && kept < 512; i++) gTDVDyldKept[kept++] = i;
            gTDVDyldKeptCount = kept;
        }
        return;
    }
    // 审计 §3.2.1: 每次全量重建 —— count 相同但集合变化的"卸载又加载"会让
    // 旧 kept 映射指到新镜像 (语义漂移); 访客调用频率低, 重建开销可忽略.
    if (true) {
        gTDVDyldRealCount = real;
        uint32_t kept = 0;
        for (uint32_t i = 0; i < real && kept < 512; i++) {
            const char *p = tdv_real_dyld_get_image_name(i);
            // image0 = 主执行文件, 永远保留 (UIKit/NSBundle 依赖 image0 语义).
            if (i != 0 && tdv_dyld_hidden_path(p)) continue;
            gTDVDyldKept[kept++] = i;
        }
        static int logged = 0;
        if (logged++ < 3) {
            NSLog(@"[TDVRoot] dyld 镜像裁剪: real=%u kept=%u hostDir=%s", real, kept, gTDVDyldHostDir);
        }
        gTDVDyldKeptCount = kept;
    }
}

static uint32_t tdv_dyld_count(void) {
    pthread_mutex_lock(&gTDVDyldLock);
    tdv_dyld_rebuild_locked();
    uint32_t n = gTDVDyldKeptCount;
    pthread_mutex_unlock(&gTDVDyldLock);
    return n;
}

static int32_t tdv_dyld_map(uint32_t idx) {
    pthread_mutex_lock(&gTDVDyldLock);
    tdv_dyld_rebuild_locked();
    int32_t real = (idx < gTDVDyldKeptCount) ? (int32_t)gTDVDyldKept[idx] : -1;
    pthread_mutex_unlock(&gTDVDyldLock);
    return real;
}

static uint32_t tdv_dyld_count_impl(void) { return tdv_dyld_count(); }
static const char *tdv_dyld_name_impl(uint32_t i) {
    int32_t r = tdv_dyld_map(i);
    return r < 0 ? NULL : tdv_real_dyld_get_image_name((uint32_t)r);
}
static const struct mach_header *tdv_dyld_header_impl(uint32_t i) {
    int32_t r = tdv_dyld_map(i);
    return r < 0 ? NULL : tdv_real_dyld_get_image_header((uint32_t)r);
}
static intptr_t tdv_dyld_slide_impl(uint32_t i) {
    int32_t r = tdv_dyld_map(i);
    return r < 0 ? 0 : tdv_real_dyld_get_image_vmaddr_slide((uint32_t)r);
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
TDV_INTERPOSE(tdv_dyld_count_impl, _dyld_image_count);
TDV_INTERPOSE(tdv_dyld_name_impl, _dyld_get_image_name);
TDV_INTERPOSE(tdv_dyld_header_impl, _dyld_get_image_header);
TDV_INTERPOSE(tdv_dyld_slide_impl, _dyld_get_image_vmaddr_slide);