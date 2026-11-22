//
//  TDVRootShim.m
//  TequilaDashLCUIAdapters
//
//  vroot (Tier A) libc 路径拦截层: __DATA,__interpose 表, 纯用户态, 默认关.
//
//  设计要点:
//    · 每个替换函数先 TDVRootMapPath, 命中则用映射后的绝对路径调原实现;
//      未命中 (开关关 / 非系统前缀 / LC 自身路径 / app group / 访客包) 原样透传.
//    · 原实现用显式 __asm 标签绑定裸符号 (_open/_stat/...), 并在镜像加载时
//      捕获函数地址; wrapper 走自有指针, 避免后续 fishhook 重绑造成互递归.
//    · getuid/geteuid/getgid/getegid 只在 mode=full 返回 0.
//    · getmntinfo/getmntinfo_r_np 在真实挂载表末尾追加一条 vroot 项.
//    · M41: dyld 镜像清单裁剪 (_dyld_image_count/get_image_name/header/vmaddr_slide)
//    · stat64 有意不拦截: 64 位 iOS SDK 不声明 struct stat64, 访客全是 arm64,
//      没有安全的 interpose 拼写 (见交付报告).
//
//  明确不拦截: posix_spawn/posix_spawnp/exec (保持平台原行为), fopen/NSFileManager (libc 底层已覆盖),
//  readlinkat/renameat/mkdirat 等其余 *at 变体, 以及 stat64 (见上).
//

#import "TDVRootConfig.h"
#import <Foundation/Foundation.h>
#import <mach-o/dyld_images.h>
#include "../../litehook/src/litehook.h"

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
static int (*gTDVReal_open)(const char *, int, ...);
static int (*gTDVReal_openat)(int, const char *, int, ...);
static int (*gTDVReal_open_nocancel)(const char *, int, ...);
static int (*gTDVReal_stat)(const char *, struct stat *);
static int (*gTDVReal_lstat)(const char *, struct stat *);
static int (*gTDVReal_fstatat)(int, const char *, struct stat *, int);
static int (*gTDVReal_access)(const char *, int);
static int (*gTDVReal_faccessat)(int, const char *, int, int);
static char *(*gTDVReal_realpath)(const char *, char *);
static ssize_t (*gTDVReal_readlink)(const char *, char *, size_t);
static DIR *(*gTDVReal_opendir)(const char *);
static int (*gTDVReal_mkdir)(const char *, mode_t);
static int (*gTDVReal_rename)(const char *, const char *);
static int (*gTDVReal_unlink)(const char *);
static int (*gTDVReal_getattrlist)(const char *, void *, void *, size_t, unsigned long);
static int (*gTDVReal_getmntinfo)(struct statfs **, int);
static int (*gTDVReal_getmntinfo_r_np)(struct statfs **, int);
static uid_t (*gTDVReal_getuid)(void);
static uid_t (*gTDVReal_geteuid)(void);
static gid_t (*gTDVReal_getgid)(void);
static gid_t (*gTDVReal_getegid)(void);

// 其它 tweak / App (WeChat, ESign 等) 会 fishhook open/stat 等符号. 我们若继续
// 按符号调用, 就会和对方的 hook 互相递归(真机 WeChat 已复现栈溢出).
// 镜像加载时把真实地址存进自有变量, 之后调用走变量.
#define TDV_REAL(name) (gTDVReal_##name ? gTDVReal_##name : tdv_real_##name)

__attribute__((constructor)) static void tdv_capture_real_paths(void) {
    gTDVReal_open = tdv_real_open;
    gTDVReal_openat = tdv_real_openat;
    gTDVReal_open_nocancel = tdv_real_open_nocancel;
    gTDVReal_stat = tdv_real_stat;
    gTDVReal_lstat = tdv_real_lstat;
    gTDVReal_fstatat = tdv_real_fstatat;
    gTDVReal_access = tdv_real_access;
    gTDVReal_faccessat = tdv_real_faccessat;
    gTDVReal_realpath = tdv_real_realpath;
    gTDVReal_readlink = tdv_real_readlink;
    gTDVReal_opendir = tdv_real_opendir;
    gTDVReal_mkdir = tdv_real_mkdir;
    gTDVReal_rename = tdv_real_rename;
    gTDVReal_unlink = tdv_real_unlink;
    gTDVReal_getattrlist = tdv_real_getattrlist;
    gTDVReal_getmntinfo = tdv_real_getmntinfo;
    gTDVReal_getmntinfo_r_np = tdv_real_getmntinfo_r_np;
    gTDVReal_getuid = tdv_real_getuid;
    gTDVReal_geteuid = tdv_real_geteuid;
    gTDVReal_getgid = tdv_real_getgid;
    gTDVReal_getegid = tdv_real_getegid;
}


#pragma mark - 访客可见性裁剪 (M37b: 隐藏 Tweaks 目录)

// LC's loader must retain native access; only images inside an installed guest
// bundle use guest visibility. The shared classifier covers both storage roots.
static bool tdv_guest_caller_image(void *caller) {
    Dl_info info = {0};
    return caller && dladdr(caller, &info) && TDVGuestCallerIsGuestImage(info.dli_fname);
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

// 把 path 映射到 vroot 或访客包内原件; 命中返回映射指针, 否则返回原指针.
// TDVGuestFileMapHidden 以 NULL + ENOENT 通知 path hook.
static inline const char *tdv_mapped_for_caller(const char *path, char *buf, size_t bufSize,
                                                void *caller, bool *originalArtifact) {
    *originalArtifact = false;
    if (!path || path[0] != '/') {
        return path;
    }
    // 镜像枚举对外报的是伪路径, 任何拿这个名字回来的文件操作都要先翻回真实路径.
    // 弱符号: 实现在 LiveContainer/Tweaks/Dyld.m, 不在本 target 时自动跳过.
    {
        extern const char *tdv_real_path_from_virtual(const char *path) __attribute__((weak));
        if (tdv_real_path_from_virtual) {
            const char *real = tdv_real_path_from_virtual(path);
            if (real && real != path) {
                path = real;
            }
        }
    }
    Dl_info info = {0};
    const char *callerImage = caller && dladdr(caller, &info) ? info.dli_fname : NULL;
    if (!TDVGuestCallerIsGuestImage(callerImage) && path && strstr(path, ".app/")) {
        // Foundation calls libc on the app's behalf, so the frame we were
        // called from is never the app's. Find the app's frame for the paths
        // that can be an app's own file; every other path keeps the direct
        // caller, so the common case stays cheap.
        void *guestFrame = TDVGuestCallerFrame();
        memset(&info, 0, sizeof(info));
        if (guestFrame && dladdr(guestFrame, &info) != 0) {
            callerImage = info.dli_fname;
        } else {
            callerImage = NULL;
        }
    }
    TDVGuestFileMapResult guestMap = TDVGuestMapBundleFile(path, callerImage, buf, bufSize);
    if (guestMap == TDVGuestFileMapTo) {
        *originalArtifact = true;
        return buf;
    }
    if (guestMap == TDVGuestFileMapHidden) {
        errno = ENOENT;
        return NULL;
    }
    if (TDVRootMapPath(path, buf, bufSize)) {
        return buf;
    }
    return path;
}


static inline const char *tdv_vroot_mapped(const char *path, char *buf, size_t bufSize) {
    if (path && path[0] == '/' && TDVRootMapPath(path, buf, bufSize)) {
        return buf;
    }
    return path;
}

// A path that only exists to hand the guest original bytes must be invisible to
// the guest. Unlike normal reads, mutating and path-resolving hooks must not
// fall through to the backup even when the requested name is not an alias.
static inline bool tdv_guest_backup_hidden(const char *path, void *caller) {
    if (!path || path[0] != '/') return false;
    Dl_info info = {0};
    const char *callerImage = caller && dladdr(caller, &info) ? info.dli_fname : NULL;
    if (!TDVGuestCallerIsGuestImage(callerImage) && path && strstr(path, ".app/")) {
        // Same as the mapping: the frame we were called from belongs to
        // Foundation, not to the guest, so find the guest's own frame.
        void *guestFrame = TDVGuestCallerFrame();
        memset(&info, 0, sizeof(info));
        if (guestFrame && dladdr(guestFrame, &info) != 0) {
            callerImage = info.dli_fname;
        } else {
            callerImage = NULL;
        }
    }
    char backup[PATH_MAX];
    return TDVGuestMapBundleFile(path, callerImage, backup, sizeof(backup)) == TDVGuestFileMapHidden;
}

static inline bool tdv_hidden_path_result(const char *mapped) {
    return mapped == NULL;
}

static inline bool tdv_open_mutates_file(int flags) {
    return (flags & O_ACCMODE) != O_RDONLY ||
           (flags & (O_CREAT | O_TRUNC | O_APPEND)) != 0;
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
    void *caller = __builtin_return_address(0);
    if (tdv_hide_tweaks(path, caller)) {
        tdv_log_tweaks_hit("open", path);
        errno = ENOENT;
        return -1;
    }
    bool originalArtifact;
    const char *use = tdv_mapped_for_caller(path, buf, sizeof(buf), caller, &originalArtifact);
    if (tdv_hidden_path_result(use)) return -1;
    if (originalArtifact && tdv_open_mutates_file(flags)) {
        errno = EROFS;
        return -1;
    }
    if (hasMode) {
        return TDV_REAL(open)(use, flags, mode);
    }
    return TDV_REAL(open)(use, flags);
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
    void *caller = __builtin_return_address(0);
    if (tdv_hide_tweaks(path, caller)) {
        tdv_log_tweaks_hit("openat", path);
        errno = ENOENT;
        return -1;
    }
    // 相对路径不映射: 语义取决于 dirfd, 无法安全改写.
    bool originalArtifact;
    const char *use = tdv_mapped_for_caller(path, buf, sizeof(buf), caller, &originalArtifact);
    if (tdv_hidden_path_result(use)) return -1;
    if (originalArtifact && tdv_open_mutates_file(flags)) {
        errno = EROFS;
        return -1;
    }
    if (hasMode) {
        return TDV_REAL(openat)(fd, use, flags, mode);
    }
    return TDV_REAL(openat)(fd, use, flags);
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
    void *caller = __builtin_return_address(0);
    bool originalArtifact;
    const char *use = tdv_mapped_for_caller(path, buf, sizeof(buf), caller, &originalArtifact);
    if (tdv_hidden_path_result(use)) return -1;
    if (originalArtifact && tdv_open_mutates_file(flags)) {
        errno = EROFS;
        return -1;
    }
    if (hasMode) {
        return TDV_REAL(open_nocancel)(use, flags, mode);
    }
    return TDV_REAL(open_nocancel)(use, flags);
}

// Metadata queries keep the requested path. Only apply the visibility rule;
// content reads may resolve to a different backing file.
static inline const char *tdv_meta_path_for_caller(const char *path, char *buf, size_t bufSize,
                                                    void *caller) {
    if (!path || path[0] != '/') {
        return path;
    }
    Dl_info info = {0};
    const char *callerImage = caller && dladdr(caller, &info) ? info.dli_fname : NULL;
    char scratch[PATH_MAX];
    if (TDVGuestMapBundleFile(path, callerImage, scratch, sizeof(scratch)) == TDVGuestFileMapHidden) {
        errno = ENOENT;
        return NULL;
    }
    // vroot 映射只影响内容路径, 元数据仍查真实路径.
    (void)buf;
    (void)bufSize;
    // 镜像枚举对外给的是伪路径 (/var/containers/Bundle/Application/<uuid>/<App>.app/...),
    // 检测器拿着这个名字回来 stat/open 时必须翻回真实路径, 否则"枚举是假的、文件不存在"
    // 自相矛盾 —— 1.1.54 就是只伪名字不翻文件, 多任务和隐藏一起坏. 弱符号: 该实现
    // 在 LiveContainer/Tweaks/Dyld.m 里, 不同 target 编译时缺失也不影响链接.
    extern const char *tdv_real_path_from_virtual(const char *path) __attribute__((weak));
    if (tdv_real_path_from_virtual) {
        const char *real = tdv_real_path_from_virtual(path);
        if (real && real != path) {
            return real;
        }
    }
    return path;
}

static int tdv_stat(const char *path, struct stat *sb) {
    if (tdv_hide_tweaks(path, __builtin_return_address(0))) {
        tdv_log_tweaks_hit("stat", path);
        errno = ENOENT;
        return -1;
    }
    const char *use = tdv_meta_path_for_caller(path, NULL, 0, __builtin_return_address(0));
    if (tdv_hidden_path_result(use)) return -1;
    return TDV_REAL(stat)(use, sb);
}

static int tdv_lstat(const char *path, struct stat *sb) {
    if (tdv_hide_tweaks(path, __builtin_return_address(0))) {
        tdv_log_tweaks_hit("lstat", path);
        errno = ENOENT;
        return -1;
    }
    const char *use = tdv_meta_path_for_caller(path, NULL, 0, __builtin_return_address(0));
    if (tdv_hidden_path_result(use)) return -1;
    return TDV_REAL(lstat)(use, sb);
}

static int tdv_fstatat(int fd, const char *path, struct stat *sb, int flags) {
    if (tdv_hide_tweaks(path, __builtin_return_address(0))) {
        tdv_log_tweaks_hit("fstatat", path);
        errno = ENOENT;
        return -1;
    }
    if (!path || path[0] != '/') {
        return TDV_REAL(fstatat)(fd, path, sb, flags);
    }
    const char *use = tdv_meta_path_for_caller(path, NULL, 0, __builtin_return_address(0));
    if (tdv_hidden_path_result(use)) return -1;
    return TDV_REAL(fstatat)(fd, use, sb, flags);
}

static int tdv_access(const char *path, int mode) {
    if (tdv_hide_tweaks(path, __builtin_return_address(0))) {
        tdv_log_tweaks_hit("access", path);
        errno = ENOENT;
        return -1;
    }
    const char *use = tdv_meta_path_for_caller(path, NULL, 0, __builtin_return_address(0));
    if (tdv_hidden_path_result(use)) return -1;
    return TDV_REAL(access)(use, mode);
}

static int tdv_faccessat(int fd, const char *path, int mode, int flags) {
    if (!path || path[0] != '/') {
        return TDV_REAL(faccessat)(fd, path, mode, flags);
    }
    const char *use = tdv_meta_path_for_caller(path, NULL, 0, __builtin_return_address(0));
    if (tdv_hidden_path_result(use)) return -1;
    return TDV_REAL(faccessat)(fd, use, mode, flags);
}

static char *tdv_realpath(const char *path, char *resolved) {
    void *caller = __builtin_return_address(0);
    if (tdv_hide_tweaks(path, caller) || tdv_guest_backup_hidden(path, caller)) {
        if (path) tdv_log_tweaks_hit("realpath", path);
        errno = ENOENT;
        return NULL;
    }
    // realpath deliberately resolves the *visible* alias, not the backup: handing
    // the guest the `.td-original...` name would defeat the path virtualization.
    char buf[PATH_MAX];
    return TDV_REAL(realpath)(tdv_vroot_mapped(path, buf, sizeof(buf)), resolved);
}

static ssize_t tdv_readlink(const char *path, char *buf, size_t bufSize) {
    void *caller = __builtin_return_address(0);
    if (tdv_guest_backup_hidden(path, caller)) return -1;
    // 与 stat 同理: readlink 的结果必须对应访客请求的那个路径, 不能换成原件的
    // 链接目标 (否则访客看到"路径 A 指向 B", 而 A 其实是另一个文件).
    const char *use = tdv_meta_path_for_caller(path, NULL, 0, caller);
    if (tdv_hidden_path_result(use)) return -1;
    return TDV_REAL(readlink)(use, buf, bufSize);
}

static DIR *tdv_opendir(const char *path) {
    if (tdv_hide_tweaks(path, __builtin_return_address(0))) {
        tdv_log_tweaks_hit("opendir", path);
        errno = ENOENT;
        return NULL;
    }
    const char *use = tdv_meta_path_for_caller(path, NULL, 0, __builtin_return_address(0));
    if (tdv_hidden_path_result(use)) return NULL;
    return TDV_REAL(opendir)(use);
}

static int tdv_mkdir(const char *path, mode_t mode) {
    if (tdv_guest_backup_hidden(path, __builtin_return_address(0))) return -1;
    char buf[PATH_MAX];
    return TDV_REAL(mkdir)(tdv_vroot_mapped(path, buf, sizeof(buf)), mode);
}

static int tdv_rename(const char *from, const char *to) {
    void *caller = __builtin_return_address(0);
    if (tdv_guest_backup_hidden(from, caller) || tdv_guest_backup_hidden(to, caller)) return -1;
    char fromBuf[PATH_MAX];
    char toBuf[PATH_MAX];
    return TDV_REAL(rename)(tdv_vroot_mapped(from, fromBuf, sizeof(fromBuf)),
                            tdv_vroot_mapped(to, toBuf, sizeof(toBuf)));
}

static int tdv_unlink(const char *path) {
    if (tdv_guest_backup_hidden(path, __builtin_return_address(0))) return -1;
    char buf[PATH_MAX];
    return TDV_REAL(unlink)(tdv_vroot_mapped(path, buf, sizeof(buf)));
}

static int tdv_getattrlist(const char *path, void *attrList, void *attrBuf,
                           size_t attrBufSize, unsigned long options) {
    // getattrlist 是 stat 的同族: 返回元数据, 必须对应访客请求的路径.
    const char *use = tdv_meta_path_for_caller(path, NULL, 0, __builtin_return_address(0));
    if (tdv_hidden_path_result(use)) return -1;
    return TDV_REAL(getattrlist)(use, attrList, attrBuf, attrBufSize, options);
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
    int n = TDV_REAL(getmntinfo)(&raw, flags);
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
    int n = TDV_REAL(getmntinfo_r_np)(&raw, flags);
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
    return TDVRootCurrentMode() == TDVRootModeFull ? 0 : TDV_REAL(getuid)();
}

static uid_t tdv_geteuid(void) {
    return TDVRootCurrentMode() == TDVRootModeFull ? 0 : TDV_REAL(geteuid)();
}

static gid_t tdv_getgid(void) {
    return TDVRootCurrentMode() == TDVRootModeFull ? 0 : TDV_REAL(getgid)();
}

static gid_t tdv_getegid(void) {
    return TDVRootCurrentMode() == TDVRootModeFull ? 0 : TDV_REAL(getegid)();
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

// 其它 tweak(如 FakeTools 的 hooked_sysctl)会再次改写 _sysctl/_sysctlbyname 的
// 符号绑定; 我们若继续按符号调用, 就会和对方的 hook 形成互相递归(真机见过
// "excessive recursion" SIGSEGV). 在镜像加载时把真实函数地址存进自有变量,
// 后续调用走变量, 不再经过可被改写的 GOT.
extern int tdv_real_sysctl(int *, u_int, void *, size_t *, void *, size_t) __asm("_sysctl");

static int (*gTDVRealSysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int (*gTDVRealSysctlByName)(const char *, void *, size_t *, void *, size_t);

__attribute__((constructor)) static void tdv_capture_real_sysctl(void) {
    gTDVRealSysctl = tdv_real_sysctl;
    gTDVRealSysctlByName = tdv_real_sysctlbyname;
}

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
    int (*real)(const char *, void *, size_t *, void *, size_t) = gTDVRealSysctlByName;
    if (!real) real = tdv_real_sysctlbyname;
    return real(name, oldp, oldlenp, newp, newlen);
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
    int (*real)(int *, u_int, void *, size_t *, void *, size_t) = gTDVRealSysctl;
    if (!real) real = tdv_real_sysctl;
    int rc = real(name, namelen, oldp, oldlenp, newp, newlen);
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

// Compatibility views apply only to guest queries of tasks created explicitly
// from this process. Audit-token and unknown tasks retain native API semantics.
typedef struct __SecTask *tdv_SecTaskRef;

extern tdv_SecTaskRef tdv_real_sectask_create_self(CFAllocatorRef allocator)
    __asm("_SecTaskCreateFromSelf");
extern void *tdv_real_sectask_copy(tdv_SecTaskRef task, CFStringRef entitlement,
                                   void **error)
    __asm("_SecTaskCopyValueForEntitlement");
extern CFDictionaryRef tdv_real_sectask_copy_values(tdv_SecTaskRef task,
                                                    CFArrayRef entitlements,
                                                    void **error)
    __asm("_SecTaskCopyValuesForEntitlements");
// Load-time function-address relocations are independent of mutable GOT slots.
static tdv_SecTaskRef (*gTDVRealSecTaskCreateSelf)(CFAllocatorRef) = tdv_real_sectask_create_self;
static void *(*gTDVRealSecTaskCopy)(tdv_SecTaskRef, CFStringRef, void **) = tdv_real_sectask_copy;
static CFDictionaryRef (*gTDVRealSecTaskCopyValues)(tdv_SecTaskRef, CFArrayRef, void **) = tdv_real_sectask_copy_values;

// Retaining a bounded set prevents pointer reuse from classifying a foreign task
// as self. Evicted but still-live objects deliberately fall back to native reads.
#define TDV_SELF_TASK_CAP 16
static tdv_SecTaskRef gTDVSelfTasks[TDV_SELF_TASK_CAP];
static unsigned gTDVSelfTaskNext;
static pthread_mutex_t gTDVSelfTaskLock = PTHREAD_MUTEX_INITIALIZER;

static tdv_SecTaskRef tdv_sectask_create_self_impl(CFAllocatorRef allocator) {
    tdv_SecTaskRef task = gTDVRealSecTaskCreateSelf(allocator);
    if (!task || !TDVSecTaskSpoofEnabled()) return task;
    CFRetain(task);
    pthread_mutex_lock(&gTDVSelfTaskLock);
    unsigned slot = gTDVSelfTaskNext++ % TDV_SELF_TASK_CAP;
    tdv_SecTaskRef evicted = gTDVSelfTasks[slot];
    gTDVSelfTasks[slot] = task;
    pthread_mutex_unlock(&gTDVSelfTaskLock);
    if (evicted) CFRelease(evicted);
    return task;
}

static bool tdv_sectask_is_tracked_self(tdv_SecTaskRef task) {
    if (!task) return false;
    bool found = false;
    pthread_mutex_lock(&gTDVSelfTaskLock);
    for (unsigned i = 0; i < TDV_SELF_TASK_CAP; ++i) {
        if (gTDVSelfTasks[i] == task) {
            found = true;
            break;
        }
    }
    pthread_mutex_unlock(&gTDVSelfTaskLock);
    return found;
}

static const char *tdv_sectask_guest_caller(tdv_SecTaskRef task, void *caller, Dl_info *info) {
    if (!TDVSecTaskSpoofEnabled() || !tdv_sectask_is_tracked_self(task) ||
        !caller || !dladdr(caller, info) || !TDVGuestCallerIsGuestImage(info->dli_fname)) {
        return NULL;
    }
    return info->dli_fname;
}


static void *tdv_sectask_copy_impl(tdv_SecTaskRef task, CFStringRef entitlement,
                                   void **error) {
    void *value = gTDVRealSecTaskCopy(task, entitlement, error);
    if (!value || !entitlement || CFGetTypeID(entitlement) != CFStringGetTypeID()) return value;
    Dl_info info = {0};
    const char *callerImage = tdv_sectask_guest_caller(task, __builtin_return_address(0), &info);
    if (!callerImage) return value;
    char name[256];
    if (!CFStringGetCString(entitlement, name, sizeof(name), kCFStringEncodingUTF8)) return value;
    void *replacement = TDVSecTaskReplacementForEntitlement(name, callerImage);
    if (replacement) {
        CFRelease(value);
        return replacement;
    }
    if (TDVSecTaskHideEntitlement(name)) {
        CFRelease(value);
        return NULL;
    }
    return value;
}

#pragma mark - csops 伪 CS flags (TD_CSOPS_SPOOF)

// Status compatibility is guest/self only. All other operations, especially
// CS_OPS_CDHASH, return the kernel's identity rather than a package-file hash.
extern int tdv_real_csops(int pid, unsigned int ops, void *useraddr, size_t usersize)
    __asm("_csops");
extern int tdv_real_csops_audittoken(int pid, unsigned int ops, void *useraddr,
                                     size_t usersize, void *token)
    __asm("_csops_audittoken");
static int (*gTDVRealCsops)(int, unsigned int, void *, size_t) = tdv_real_csops;
static int (*gTDVRealCsopsAuditToken)(int, unsigned int, void *, size_t, void *) = tdv_real_csops_audittoken;

static int tdv_csops_apply(unsigned int ops, void *useraddr, size_t usersize,
                           int realRc, void *caller) {
    if (realRc != 0 || !useraddr || !TDVCsopsSpoofEnabled()) return realRc;
    Dl_info info = {0};
    if (!caller || !dladdr(caller, &info) || !TDVGuestCallerIsGuestImage(info.dli_fname)) return realRc;
    if (ops == 0 /*CS_OPS_STATUS*/ && usersize >= sizeof(unsigned int)) {
        unsigned int fake = 0;
        memcpy(&fake, useraddr, sizeof(unsigned int));
        if (TDVCsopsSpoofLookup(fake, &fake)) {
            memcpy(useraddr, &fake, sizeof(unsigned int));
        }
    }
    return realRc;
}

static int tdv_csops_for_caller(int pid, unsigned int ops, void *useraddr,
                                 size_t usersize, void *caller) {
    int rc = gTDVRealCsops(pid, ops, useraddr, usersize);
    if (pid != getpid()) return rc;
    return tdv_csops_apply(ops, useraddr, usersize, rc, caller);
}

static int tdv_csops_audittoken_for_caller(int pid, unsigned int ops, void *useraddr,
                                            size_t usersize, void *token, void *caller) {
    int rc = gTDVRealCsopsAuditToken(pid, ops, useraddr, usersize, token);
    if (pid != getpid()) return rc;
    return tdv_csops_apply(ops, useraddr, usersize, rc, caller);
}

static int tdv_csops_impl(int pid, unsigned int ops, void *useraddr, size_t usersize) {
    return tdv_csops_for_caller(pid, ops, useraddr, usersize, __builtin_return_address(0));
}

static int tdv_csops_audittoken_impl(int pid, unsigned int ops, void *useraddr,
                                     size_t usersize, void *token) {
    return tdv_csops_audittoken_for_caller(pid, ops, useraddr, usersize, token, __builtin_return_address(0));
}

// Exported for hook_dlsym(): some detectors call dlsym(RTLD_DEFAULT, "csops")
// and therefore bypass __DATA,__interpose. Returning this address from dlsym
// makes the same spoofing logic apply to that API path too.
__attribute__((visibility("default")))
int TDVReplacementCsops(int pid, unsigned int ops, void *useraddr, size_t usersize) {
    return tdv_csops_for_caller(pid, ops, useraddr, usersize, __builtin_return_address(0));
}

__attribute__((visibility("default")))
int TDVReplacementCsopsAuditToken(int pid, unsigned int ops, void *useraddr,
                                  size_t usersize, void *token) {
    return tdv_csops_audittoken_for_caller(pid, ops, useraddr, usersize, token, __builtin_return_address(0));
}

#pragma mark - proc 族伪值 (TD_PROC_SPOOF)

#include <mach/mach.h>
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
// kern.proc 裸 MIB 通道 (sysctl(3)) 另由 sysctl interpose 处理 (见上一节);
// 任务端口引用数另由 mach_port_get_refs 拦截 (见下一节).
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

#pragma mark - 任务端口引用数 (TD_PROC_SPOOF 同门控)

// Reveil imports mach_port_get_refs through its GOT and checks self/self SEND
// refs < 3. Only that guest query uses the compatibility view; native failures,
// RECEIVE/other rights, foreign ports/tasks and host callers remain untouched.
extern kern_return_t tdv_real_mach_port_get_refs(mach_port_t task, mach_port_name_t name,
                                                  mach_port_right_t right,
                                                  mach_port_urefs_t *refs)
    __asm("_mach_port_get_refs");
static kern_return_t (*gTDVRealMachPortGetRefs)(mach_port_t, mach_port_name_t,
                                              mach_port_right_t, mach_port_urefs_t *);

__attribute__((constructor)) static void tdv_capture_real_task_refs(void) {
    gTDVRealMachPortGetRefs = tdv_real_mach_port_get_refs;
}

static kern_return_t tdv_mach_port_get_refs_impl(mach_port_t task, mach_port_name_t name,
                                                 mach_port_right_t right,
                                                 mach_port_urefs_t *refs) {
    kern_return_t kr = gTDVRealMachPortGetRefs(task, name, right, refs);
    if (kr != KERN_SUCCESS || !refs || !TDVProcSpoofEnabled()) return kr;
    if (right != MACH_PORT_RIGHT_SEND || task != mach_task_self() || name != mach_task_self()) return kr;
    Dl_info info = {0};
    void *caller = __builtin_return_address(0);
    if (!caller || !dladdr(caller, &info) || !TDVGuestCallerIsGuestImage(info.dli_fname)) return kr;
    if (*refs > 2) *refs = 2;
    return kr;
}

void TDVInstallGuestHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Use the existing GOT rebinder, including its add-image callback, so
        // guest imports loaded after bootstrap take this route in both modes.
        // The captured pointer and source image are never rebound to our hook.
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, gTDVRealMachPortGetRefs,
                               tdv_mach_port_get_refs_impl, NULL);
        TDVInstallTaskInfoHook();
        TDVInstallSigactionHook();
    });
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

#pragma mark - task_info(TASK_DYLD_INFO) 镜像副本 (TD_PROC_SPOOF 同门控)

// NSKSign 的 _AISCollectStableApiVersusTask 同时对比 stable API
// (_dyld_image_count/_dyld_get_image_name) 和 task_info(TASK_DYLD_INFO) 返回的
// dyld_all_image_infos.infoArray。我们隐藏 LC/TweakLoader 镜像时只改了 stable API，
// 内核 task_info 仍返回全部条目，导致两个列表数量/内容不一致 -> 必命中。
// 修法：interpose task_info，当 flavor=TASK_DYLD_INFO 且 caller 是 guest 且
// TD_PROC_SPOOF 开启时，把返回的 all_image_info_addr 指向一个删除隐藏条目后的
// dyld_all_image_infos 副本。副本按可见索引顺序填充（与 stable API 一致），
// 其余字段从真实结构逐字节拷贝。不指向空结构（1.1.45 教训）。

extern kern_return_t tdv_real_task_info(task_name_t target_task,
                                        task_flavor_t flavor,
                                        task_info_t task_info_out,
                                        mach_msg_type_number_t *task_info_outCnt)
    __asm("_task_info");
static kern_return_t (*gTDVRealTaskInfo)(task_name_t, task_flavor_t,
                                         task_info_t, mach_msg_type_number_t *)
    = tdv_real_task_info;

bool TDVDyldInfoShouldHideImage(uint32_t realIndex);
uint32_t TDVDyldInfoVisibleIndices(uint32_t *out, uint32_t cap);

static pthread_mutex_t gTDVDyldInfoCopyLock = PTHREAD_MUTEX_INITIALIZER;
static struct dyld_all_image_infos *gTDVDyldInfoCopy = NULL;
static uint32_t gTDVDyldInfoCopySource = 0;

static bool tdv_task_info_guest_caller(void *caller) {
    Dl_info info = {0};
    return caller && dladdr(caller, &info) && TDVGuestCallerIsGuestImage(info.dli_fname);
}

static vm_address_t tdv_build_dyld_info_copy(const struct dyld_all_image_infos *real) {
    if (!real) return 0;
    const uint32_t realCount = real->infoArrayCount;
    const struct dyld_image_info *realArray = real->infoArray;
    if (!realArray || realCount == 0) return 0;

    uint32_t visible[TDV_DYLD_INFO_MAX_VISIBLE];
    uint32_t visibleCount = TDVDyldInfoVisibleIndices(visible, TDV_DYLD_INFO_MAX_VISIBLE);
    if (visibleCount == 0) return 0;

    struct dyld_image_info *copyArray = malloc((size_t)visibleCount * sizeof(struct dyld_image_info));
    if (!copyArray) return 0;
    uint32_t copyCount = 0;
    for (uint32_t i = 0; i < visibleCount && i < realCount; ++i) {
        uint32_t realIdx = visible[i];
        if (realIdx >= realCount || TDVDyldInfoShouldHideImage(realIdx)) continue;
        copyArray[copyCount] = realArray[realIdx];
        ++copyCount;
    }
    if (copyCount == 0) {
        free(copyArray);
        return 0;
    }

    size_t total = sizeof(struct dyld_all_image_infos) + (size_t)copyCount * sizeof(struct dyld_image_info);
    struct dyld_all_image_infos *copy = malloc(total);
    if (!copy) {
        free(copyArray);
        return 0;
    }
    memcpy(copy, real, sizeof(struct dyld_all_image_infos));
    copy->infoArrayCount = copyCount;
    copy->infoArray = (struct dyld_image_info *)((uintptr_t)copy + sizeof(struct dyld_all_image_infos));
    memcpy((void *)copy->infoArray, copyArray, (size_t)copyCount * sizeof(struct dyld_image_info));
    free(copyArray);

    pthread_mutex_lock(&gTDVDyldInfoCopyLock);
    if (gTDVDyldInfoCopy) free(gTDVDyldInfoCopy);
    gTDVDyldInfoCopy = copy;
    gTDVDyldInfoCopySource = realCount;
    pthread_mutex_unlock(&gTDVDyldInfoCopyLock);
    return (vm_address_t)(uintptr_t)copy;
}

static kern_return_t tdv_task_info_impl(task_name_t target_task, task_flavor_t flavor,
                                        task_info_t task_info_out,
                                        mach_msg_type_number_t *task_info_outCnt) {
    kern_return_t kr = gTDVRealTaskInfo(target_task, flavor, task_info_out, task_info_outCnt);
    if (kr != KERN_SUCCESS || flavor != TASK_DYLD_INFO || !task_info_out || !task_info_outCnt) return kr;
    if (*task_info_outCnt < TASK_DYLD_INFO_COUNT) return kr;
    // 门控: proc 伪值开关, 或 stable API 视图已被镜像裁剪 (TDVDyldRemapActive).
    // 后者是硬约束: 裁剪后 stable API 只给可见镜像, task_info 侧不给同一个集合
    // 的话, 全能签 (NSKSign) 的 stable-vs-task 对比必然判红.
    if (!TDVProcSpoofEnabled() && !TDVDyldRemapActive()) return kr;
    if (!tdv_task_info_guest_caller(__builtin_return_address(0))) return kr;

    task_dyld_info_data_t *out = (task_dyld_info_data_t *)task_info_out;
    const struct dyld_all_image_infos *real = (const struct dyld_all_image_infos *)(uintptr_t)out->all_image_info_addr;
    if (!real) return kr;

    pthread_mutex_lock(&gTDVDyldInfoCopyLock);
    bool reusable = gTDVDyldInfoCopy && gTDVDyldInfoCopySource == real->infoArrayCount;
    vm_address_t copyAddr = reusable ? (vm_address_t)(uintptr_t)gTDVDyldInfoCopy : 0;
    pthread_mutex_unlock(&gTDVDyldInfoCopyLock);
    if (copyAddr) {
        out->all_image_info_addr = copyAddr;
        return kr;
    }

    copyAddr = tdv_build_dyld_info_copy(real);
    if (!copyAddr) return kr;
    out->all_image_info_addr = copyAddr;
    return kr;
}

void TDVInstallTaskInfoHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, gTDVRealTaskInfo,
                               tdv_task_info_impl, NULL);
    });
}

#pragma mark - sigaction 查询伪值 (TD_PROC_SPOOF 同门控)

// Reveil 3.4 的信号处理器检查对信号 1...31 逐个 sigaction(sig, NULL, &old),
// old.__sa_handler 非 0 (SIG_DFL) 即红. 我们自己的崩溃记录/Guard handler 是
// 合法注册, 不能撤; interpose 只改"查询"返回: act == NULL 且 old != NULL 且
// caller 是 guest 且门控开启时, 把 old 的 handler 归零. 注册调用
// (act != NULL) 完全透传, 我们的 handler 照常工作. NSKSign 的 fishhook 还原
// 只覆盖固定 5 个 dyld 符号, 不含 sigaction.

// 只写检测语义判断的字段 handler @0。早先实现把 mask/flags 一并清零，对以
// 紧凑缓冲区作 old 的调用方越界写 8 字节，触发 Reveil 检测线程
// __stack_chk_fail（123758.ips：FUN_100147270 尾部 bl __stack_chk_fail）。
struct tdv_sigaction_stubs {
    void *handler;
};

extern int tdv_real_sigaction(int signum, const void *act, struct tdv_sigaction_stubs *old)
    __asm("_sigaction");
static int (*gTDVRealSigaction)(int, const void *, struct tdv_sigaction_stubs *) = tdv_real_sigaction;

static int tdv_sigaction_impl(int signum, const void *act, struct tdv_sigaction_stubs *old) {
    int rc = gTDVRealSigaction(signum, act, old);
    if (rc != 0 || act || !old || !TDVProcSpoofEnabled()) return rc;
    if (!tdv_task_info_guest_caller(__builtin_return_address(0))) return rc;
    // SIG_DFL 的判定字段只有 handler；mask/flags 属于调用方的缓冲区，保持真值。
    old->handler = NULL;
    return rc;
}


void TDVInstallSigactionHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, gTDVRealSigaction,
                               tdv_sigaction_impl, NULL);
    });
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

// dladdr 把镜像路径直接写进调用方的 dli_fname; 这里也换成伪路径, 与镜像枚举和
// NSBundle.bundlePath 保持一致, 否则检测器把三者互比就能看出"从可写目录加载".
extern int tdv_real_dladdr(const void *addr, Dl_info *info) __asm("_dladdr");

static int tdv_dladdr(const void *addr, Dl_info *info) {
    int rc = tdv_real_dladdr(addr, info);
    if (rc == 0 || !info || !info->dli_fname) return rc;
    extern const char *tdv_masked_image_name(const char *realName) __attribute__((weak));
    if (!tdv_masked_image_name) return rc;
    const char *masked = tdv_masked_image_name(info->dli_fname);
    if (masked && masked != info->dli_fname) {
        info->dli_fname = masked;
    }
    return rc;
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
TDV_INTERPOSE(tdv_dladdr, tdv_real_dladdr);
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
TDV_INTERPOSE(tdv_sectask_create_self_impl, tdv_real_sectask_create_self);
TDV_INTERPOSE(tdv_sectask_copy_values_impl, tdv_real_sectask_copy_values);
TDV_INTERPOSE(tdv_csops_impl, tdv_real_csops);
TDV_INTERPOSE(tdv_csops_audittoken_impl, tdv_real_csops_audittoken);
TDV_INTERPOSE(tdv_proc_listallpids_impl, tdv_real_proc_listallpids);
TDV_INTERPOSE(tdv_proc_pidpath_impl, tdv_real_proc_pidpath);
TDV_INTERPOSE(tdv_proc_name_impl, tdv_real_proc_name);
TDV_INTERPOSE(tdv_bootstrap_look_up2_impl, tdv_real_bootstrap_look_up);
#pragma mark - SecTask 复数/audit-token 通道 (TD_SECTASK_SPOOF 同门控)

// Always query the complete native key set first, preserving validation errors,
// missing keys and ownership. Copy the result only when an existing value changes.
static CFDictionaryRef tdv_sectask_copy_values_impl(tdv_SecTaskRef task,
                                                    CFArrayRef entitlements,
                                                    void **error) {
    CFDictionaryRef result = gTDVRealSecTaskCopyValues(task, entitlements, error);
    if (!result || !entitlements || CFGetTypeID(entitlements) != CFArrayGetTypeID()) return result;
    Dl_info info = {0};
    const char *callerImage = tdv_sectask_guest_caller(task, __builtin_return_address(0), &info);
    if (!callerImage) return result;
    CFMutableDictionaryRef changed = NULL;
    CFIndex count = CFArrayGetCount(entitlements);
    for (CFIndex i = 0; i < count; ++i) {
        CFTypeRef key = CFArrayGetValueAtIndex(entitlements, i);
        if (!key || CFGetTypeID(key) != CFStringGetTypeID() || !CFDictionaryContainsKey(result, key)) continue;
        char name[256];
        if (!CFStringGetCString((CFStringRef)key, name, sizeof(name), kCFStringEncodingUTF8)) continue;
        CFTypeRef replacement = TDVSecTaskReplacementForEntitlement(name, callerImage);
        if (replacement && CFEqual(replacement, CFDictionaryGetValue(result, key))) {
            CFRelease(replacement);
            continue;
        }
        bool hide = !replacement && TDVSecTaskHideEntitlement(name);
        if (!replacement && !hide) continue;
        if (!changed) changed = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, result);
        if (!changed) {
            if (replacement) CFRelease(replacement);
            return result;
        }
        if (replacement) {
            CFDictionarySetValue(changed, key, replacement);
            CFRelease(replacement);
        } else {
            CFDictionaryRemoveValue(changed, key);
        }
    }
    if (!changed) return result;
    CFRelease(result);
    return changed;
}
