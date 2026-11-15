//
//  TDVRootConfig.m
//  TequilaDashLCUIAdapters
//
//  vroot (Tier A) 配置与路径映射. 只读: 不改写 on-disk 二进制, 不碰 dyld/签名/mount.
//  默认关: TD_VROOT 未设置或 TD_VROOT_MODE=off 时所有导出函数都是空操作.
//

#import "TDVRootConfig.h"

#import <Foundation/Foundation.h>

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/syslimits.h>
#include <unistd.h>

#pragma mark - 状态

static pthread_mutex_t gTDVRootLock = PTHREAD_MUTEX_INITIALIZER;
static bool gTDVRootInited = false;
static bool gTDVRootEnabled = false;
static TDVRootMode gTDVRootMode = TDVRootModeOff;
static char gTDVRootRoot[PATH_MAX];
static char gTDVRootRealHome[PATH_MAX];
static char gTDVRootLCHome[PATH_MAX];
static bool gTDVRootHomesCaptured = false;

// 内置前缀表. rewriteSuffix == NULL: 映射为 <root><原路径> (/usr/bin/x -> root/usr/bin/x);
// rewriteSuffix != NULL: 去掉前缀, 再拼 <root><rewriteSuffix><剩余>:
//   /var/jb/usr/bin/x      -> root/usr/bin/x
//   /private/etc/hosts     -> root/etc/hosts
typedef struct {
    const char *prefix;
    const char *rewriteSuffix; // NULL = 保留整条原路径
} TDVRootPrefixEntry;

static const TDVRootPrefixEntry kTDVRootPrefixes[] = {
    {"/usr", NULL},
    {"/bin", NULL},
    {"/sbin", NULL},
    {"/etc", NULL},
    {"/private/etc", "/etc"},
    {"/opt", NULL},
    {"/var/jb", ""},
    {"/private/var/jb", ""},
};

#pragma mark - 小工具

static bool tdv_path_is_under(const char *path, const char *prefix) {
    if (!path || !prefix || !prefix[0]) {
        return false;
    }
    size_t n = strlen(prefix);
    return strncmp(path, prefix, n) == 0 && (path[n] == '\0' || path[n] == '/');
}

// 绝对路径归一化: 折叠重复斜杠 / 去尾斜杠 / 拒绝 "." 与 ".." 组件.
static bool tdv_normalize_absolute(const char *in, char *out, size_t outSize) {
    if (!in || in[0] != '/' || !out || outSize == 0) {
        return false;
    }
    char tmp[PATH_MAX];
    size_t len = 0;
    for (const char *p = in; *p; p++) {
        if (*p == '/' && len > 0 && tmp[len - 1] == '/') {
            continue;
        }
        if (len + 1 >= sizeof(tmp)) {
            return false;
        }
        tmp[len++] = *p;
    }
    while (len > 1 && tmp[len - 1] == '/') {
        len--;
    }
    tmp[len] = '\0';

    // 组件级校验: 只允许绝对、不含 "." / "..".
    char scan[PATH_MAX];
    if (len >= sizeof(scan)) {
        return false;
    }
    memcpy(scan, tmp, len + 1);
    char *save = NULL;
    for (char *tok = strtok_r(scan, "/", &save); tok; tok = strtok_r(NULL, "/", &save)) {
        if (strcmp(tok, ".") == 0 || strcmp(tok, "..") == 0) {
            return false;
        }
    }
    if (len >= outSize) {
        return false;
    }
    memcpy(out, tmp, len + 1);
    return true;
}

static TDVRootMode tdv_parse_mode(const char *raw) {
    if (!raw || !raw[0]) {
        return TDVRootModePath; // TD_VROOT 已设置但未写 mode: 保守的纯路径映射
    }
    if (strcasecmp(raw, "off") == 0 || strcmp(raw, "0") == 0 ||
        strcasecmp(raw, "false") == 0 || strcasecmp(raw, "no") == 0) {
        return TDVRootModeOff;
    }
    if (strcasecmp(raw, "full") == 0) {
        return TDVRootModeFull;
    }
    if (strcasecmp(raw, "path") == 0 || strcmp(raw, "1") == 0 ||
        strcasecmp(raw, "true") == 0 || strcasecmp(raw, "yes") == 0 ||
        strcasecmp(raw, "on") == 0) {
        return TDVRootModePath;
    }
    return TDVRootModeOff; // 未知取值 fail-closed
}

static void tdv_copy_env_path(const char *name, char *out, size_t outSize) {
    const char *raw = getenv(name);
    char norm[PATH_MAX];
    if (raw && raw[0] == '/' && tdv_normalize_absolute(raw, norm, sizeof(norm))) {
        if (strlen(norm) < outSize) {
            memcpy(out, norm, strlen(norm) + 1);
            return;
        }
    }
    if (outSize) {
        out[0] = '\0';
    }
}

// 调用方持锁. 只在首次调用时记录, 避免 full 模式 HOME 改写后把 vroot 当真实家目录.
static void tdv_capture_homes_locked(void) {
    if (gTDVRootHomesCaptured) {
        return;
    }
    gTDVRootHomesCaptured = true;
    tdv_copy_env_path("HOME", gTDVRootRealHome, sizeof(gTDVRootRealHome));
    tdv_copy_env_path("LC_HOME_PATH", gTDVRootLCHome, sizeof(gTDVRootLCHome));

    // full 模式下 HOME 可能已经被改写成 vroot 根; 那不是"真实家目录".
    const char *rootEnv = getenv("TD_VROOT");
    if (rootEnv && gTDVRootRealHome[0] && strcmp(gTDVRootRealHome, rootEnv) == 0) {
        gTDVRootRealHome[0] = '\0';
    }
    if (rootEnv && gTDVRootLCHome[0] && strcmp(gTDVRootLCHome, rootEnv) == 0) {
        gTDVRootLCHome[0] = '\0';
    }
}

// M41 门控数据源: TD_DYLD_TRIM env (launcher 透传 per-app hideLiveContainer).
static bool gTDVDyldTrim = false;

// sysctl 伪值表数据源: TD_SYSCTL_SPOOF env (launcher 透传 per-app sysctlSpoof).
// 内置默认表 = 检测器高频查询键 (libBroadpatch/Reveil 审计结论);
// TD_SYSCTL_<NAME> env (名大写化 '.'->'_') 可逐键覆盖, 未设用默认.
//
// 硬编码原则 (audit v2 修正): 表里只放**设备无关**的伪化动作.
//   · kern.bootargs -> 空串: 真 iOS 设备该值恒为空, 非空 = 越狱机/USB 引导实锤,
//     空串就是真值, 不存在"机型不符"问题.
//   · hw.machine / hw.model / kern.osversion / kern.osrelease **不进默认表**:
//     真机伪值应透传真机自身值 (检测器若持有宿主机型画像, 写死的机型反而露馅).
//     需要伪装时由 TD_SYSCTL_HW_MACHINE 等 env 显式提供, 或 Launcher 侧
//     读取宿主自身 sysctl 真值后落 env (透传 = 恒真).
typedef struct {
    const char *name;    // sysctl 名, 精确匹配
    const char *value;   // 伪值 NUL 结尾字符串; 数值型 sysctl 同样按字符串返回,
} TDVSysctlSpoofEntry;

static const TDVSysctlSpoofEntry kTDVSysctlSpoofs[] = {
    {"kern.bootargs", ""},
};

static bool gTDVSysctlSpoof = false;

// SecTask entitlement 隐藏数据源: TD_SECTASK_SPOOF env (launcher 透传 per-app secTaskSpoof).
// 精确表 = 宿主侧真实存在且暴露宿主身份的键; 前缀表 = 家族通配 (LC/TD/私有注入框架).
// 注意: 宿主自己的合法键 (com.apple.security.application-groups / team-identifier /
// application-identifier / keychain-access-groups) 一律透传 —— worse_query.m 的
// td_signed_app_groups 靠 application-groups 工作, 隐藏它会把宿主自己打断.
static const char *kTDVSecTaskHideExact[] = {
    "get-task-allow",
};
static const char *kTDVSecTaskHidePrefixes[] = {
    "com.apple.private.",
    "com.apple.developer.",
    "org.emexlabs.nyxian.",
    "org.tequila.",
    "td.tequila.",
};

static bool gTDVSecTaskSpoof = false;

// csops 伪 CS flags数据源: TD_CSOPS_SPOOF env (launcher 透传 per-app csopsSpoof).
static bool gTDVCsopsSpoof = false;
// TD_CSOPS_KEEP_DEBUGGED=1: 保留 CS_DEBUGGED (我们自己的调试器探测链路依赖它,
// 见 TequilaDash-Bridging-Header.h v0.3.8): per-app 键 csopsKeepDebugged.
static bool gTDVCsopsKeepDebugged = false;

// proc 族伪值数据源: TD_PROC_SPOOF env (launcher 透传 per-app procSpoof).
static bool gTDVProcSpoof = false;

static void tdv_init_once(void);

bool TDVDyldTrimEnabled(void) {
    tdv_init_once();
    return gTDVDyldTrim;
}

bool TDVSysctlSpoofEnabled(void) {
    tdv_init_once();
    return gTDVSysctlSpoof;
}

bool TDVSecTaskSpoofEnabled(void) {
    tdv_init_once();
    return gTDVSecTaskSpoof;
}

bool TDVSecTaskHideEntitlement(const char *entitlement) {
    if (!entitlement || !TDVSecTaskSpoofEnabled()) {
        return false;
    }
    for (size_t i = 0; i < sizeof(kTDVSecTaskHideExact) / sizeof(kTDVSecTaskHideExact[0]); i++) {
        if (strcmp(entitlement, kTDVSecTaskHideExact[i]) == 0) {
            return true;
        }
    }
    for (size_t i = 0; i < sizeof(kTDVSecTaskHidePrefixes) / sizeof(kTDVSecTaskHidePrefixes[0]); i++) {
        size_t n = strlen(kTDVSecTaskHidePrefixes[i]);
        if (strncmp(entitlement, kTDVSecTaskHidePrefixes[i], n) == 0) {
            return true;
        }
    }
    return false;
}

bool TDVCsopsSpoofEnabled(void) {
    tdv_init_once();
    return gTDVCsopsSpoof;
}

// CS_OPS_STATUS 的相关位 (XNU bsd/sys/codesign.h, 与 Reveil CsOps.swift 一致):
//   CS_GET_TASK_ALLOW 0x00000004 (get-task-allow entitlement 的内核投影)
//   CS_REQUIRE_LV     0x00002000 (require library validation)
//   CS_DEBUGGED       0x10000000 (调试器已附加)
#define TDV_CS_GET_TASK_ALLOW 0x00000004u
#define TDV_CS_REQUIRE_LV     0x00002000u
#define TDV_CS_DEBUGGED       0x10000000u
// 伪值需要与真值同形状. 侧载宿主天然没有 CS_REQUIRE_LV, 检测器据此判
// "共享库验证被禁用"; 这里补上该位, 让读到的状态与正常 App Store 应用一致.
// CS_DEBUGGED 按门控清除; 其余位 (CS_VALID/CS_HARD/CS_KILL/CS_RESTRICT/
// CS_PLATFORM_BINARY/CS_ENTITLEMENTS_VALID/CS_LINKER_SIGNED…) 原样保留.
bool TDVCsopsSpoofLookup(unsigned int flagsIn, unsigned int *flagsOut) {
    if (!flagsOut || !TDVCsopsSpoofEnabled()) {
        return false;
    }
    unsigned int v = flagsIn;
    v |= TDV_CS_REQUIRE_LV;
    if (!gTDVCsopsKeepDebugged) {
        v &= ~TDV_CS_DEBUGGED;
    }
    *flagsOut = v;
    return true;
}

bool TDVProcSpoofEnabled(void) {
    tdv_init_once();
    return gTDVProcSpoof;
}

int TDVProcFilterPids(pid_t *pids, int count) {
    if (!pids || count <= 0 || !TDVProcSpoofEnabled()) {
        return count;
    }
    pid_t self = getpid();
    int kept = 0;
    for (int i = 0; i < count; i++) {
        if (pids[i] == self) {
            pids[kept++] = pids[i];
        }
    }
    return kept;
}

bool TDVSysctlSpoofLookup(const char *name, char *out, size_t outSize) {
    if (!name || !out || outSize == 0) {
        return false;
    }
    if (!TDVSysctlSpoofEnabled()) {
        return false;
    }
    // 1) per-app 覆盖: TD_SYSCTL_<NAME> 大写化, 存在即用.
    char envName[128];
    size_t w = 0;
    const char *prefix = "TD_SYSCTL_";
    size_t plen = strlen(prefix);
    if (plen + strlen(name) + 1 <= sizeof(envName)) {
        memcpy(envName, prefix, plen);
        w = plen;
        for (const char *p = name; *p && w + 1 < sizeof(envName); p++) {
            char c = (*p == '.') ? '_' : *p;
            if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
            envName[w++] = c;
        }
        envName[w] = '\0';
        const char *override = getenv(envName);
        if (override) {
            if (strcmp(override, "__REAL__") == 0) {
                // 显式透传: 该键不伪装, 回退真实现.
                return false;
            }
            size_t n = strlen(override);
            if (n < outSize) {
                memcpy(out, override, n + 1);
                return true;
            }
            return false; // 覆盖值放不下: 透传真值 (不返回截断垃圾)
        }
    }
    // 2) 内置默认表:

    for (size_t i = 0; i < sizeof(kTDVSysctlSpoofs) / sizeof(kTDVSysctlSpoofs[0]); i++) {
        if (strcmp(name, kTDVSysctlSpoofs[i].name) == 0) {
            size_t n = strlen(kTDVSysctlSpoofs[i].value);
            if (n < outSize) {
                memcpy(out, kTDVSysctlSpoofs[i].value, n + 1);
                return true;
            }
            return false;
        }
    }
    return false;
}

static void tdv_init_locked(void) {
    __atomic_store_n(&gTDVRootEnabled, false, __ATOMIC_RELAXED);
    // M41 门控独立于 vroot: TD_DYLD_TRIM 由 launcher 按 per-app hideLiveContainer 透传.
    gTDVDyldTrim = getenv("TD_DYLD_TRIM") && getenv("TD_DYLD_TRIM")[0] == '1';
    // sysctl 伪值表独立于 vroot: TD_SYSCTL_SPOOF 由 launcher 按 per-app sysctlSpoof 透传.
    gTDVSysctlSpoof = getenv("TD_SYSCTL_SPOOF") && getenv("TD_SYSCTL_SPOOF")[0] == '1';
    // SecTask entitlement 隐藏独立于 vroot: TD_SECTASK_SPOOF.
    gTDVSecTaskSpoof = getenv("TD_SECTASK_SPOOF") && getenv("TD_SECTASK_SPOOF")[0] == '1';
    // csops 伪 CS flags 独立于 vroot: TD_CSOPS_SPOOF (+ TD_CSOPS_KEEP_DEBUGGED).
    gTDVCsopsSpoof = getenv("TD_CSOPS_SPOOF") && getenv("TD_CSOPS_SPOOF")[0] == '1';
    gTDVCsopsKeepDebugged = getenv("TD_CSOPS_KEEP_DEBUGGED") && getenv("TD_CSOPS_KEEP_DEBUGGED")[0] == '1';
    // proc 族伪值独立于 vroot: TD_PROC_SPOOF.
    gTDVProcSpoof = getenv("TD_PROC_SPOOF") && getenv("TD_PROC_SPOOF")[0] == '1';
    gTDVRootMode = TDVRootModeOff;
    gTDVRootRoot[0] = '\0';

    tdv_capture_homes_locked();

    const char *rawRoot = getenv("TD_VROOT");
    const char *rawMode = getenv("TD_VROOT_MODE");
    if (!rawRoot || rawRoot[0] != '/') {
        return;
    }
    TDVRootMode mode = tdv_parse_mode(rawMode);
    if (mode == TDVRootModeOff) {
        return;
    }
    char norm[PATH_MAX];
    if (!tdv_normalize_absolute(rawRoot, norm, sizeof(norm))) {
        return;
    }
    // 根就是 "/" 时映射等于恒等, 没有意义; 视为关闭.
    if (strcmp(norm, "/") == 0) {
        return;
    }
    memcpy(gTDVRootRoot, norm, strlen(norm) + 1);
    gTDVRootMode = mode;
    __atomic_store_n(&gTDVRootEnabled, true, __ATOMIC_RELEASE);
}

static void tdv_init_once(void) {
    if (__atomic_load_n(&gTDVRootInited, __ATOMIC_ACQUIRE)) {
        return;
    }
    pthread_mutex_lock(&gTDVRootLock);
    if (!__atomic_load_n(&gTDVRootInited, __ATOMIC_RELAXED)) {
        tdv_init_locked();
        __atomic_store_n(&gTDVRootInited, true, __ATOMIC_RELEASE);
    }
    pthread_mutex_unlock(&gTDVRootLock);
}

#pragma mark - 导出

bool TDVRootIsEnabled(void) {
    tdv_init_once();
    return __atomic_load_n(&gTDVRootEnabled, __ATOMIC_ACQUIRE);
}

TDVRootMode TDVRootCurrentMode(void) {
    tdv_init_once();
    return __atomic_load_n(&gTDVRootEnabled, __ATOMIC_ACQUIRE) ? gTDVRootMode : TDVRootModeOff;
}

const char *TDVRootRootPath(void) {
    tdv_init_once();
    return __atomic_load_n(&gTDVRootEnabled, __ATOMIC_ACQUIRE) ? gTDVRootRoot : NULL;
}

bool TDVRootShouldSkipPath(const char *path) {
    if (!path || path[0] != '/') {
        return true;
    }
    tdv_init_once();
    if (!__atomic_load_n(&gTDVRootEnabled, __ATOMIC_ACQUIRE)) {
        // 未启用时无需判断; map 会直接失败.
        return false;
    }
    // 已经在 vroot 内: 不能二次映射.
    if (tdv_path_is_under(path, gTDVRootRoot)) {
        return true;
    }
    // LC 自己的容器 / 扩展容器 / app group / 访客包: 必须保持真实路径.
    if (gTDVRootRealHome[0] && tdv_path_is_under(path, gTDVRootRealHome)) {
        return true;
    }
    if (gTDVRootLCHome[0] && tdv_path_is_under(path, gTDVRootLCHome)) {
        return true;
    }
    static const char *kRealPrefixes[] = {
        "/private/var/mobile/Containers/",
        "/var/mobile/Containers/",
        "/private/var/containers/",
        "/var/containers/",
        "/System/",
        "/Library/",
        "/dev/",
        "/private/preboot/",
    };
    for (size_t i = 0; i < sizeof(kRealPrefixes) / sizeof(kRealPrefixes[0]); i++) {
        if (tdv_path_is_under(path, kRealPrefixes[i])) {
            return true;
        }
    }
    // LC 自身镜像 / TweakLoader / 嵌套 LC / 访客包的字符串护栏 (容器前缀已被上面覆盖,
    // 这里防的是经 app group 或 bookmark 解析出来的非常规绝对路径).
    static const char *kRealFragments[] = {
        "/Documents/Applications/",
        "/Documents/Data/Application/",
        "/LiveContainer/Data/AppGroup/",
        "/LCAppGroup/",
        "/Frameworks/LiveContainer",
        "/TweakLoader",
    };
    for (size_t i = 0; i < sizeof(kRealFragments) / sizeof(kRealFragments[0]); i++) {
        if (strstr(path, kRealFragments[i]) != NULL) {
            return true;
        }
    }
    // dyld 本体永远走真实路径 (dyld shared cache 的装载入口).
    if (strcmp(path, "/usr/lib/dyld") == 0 || strncmp(path, "/usr/lib/dyld", 13) == 0) {
        return true;
    }
    return false;
}

bool TDVRootMapPath(const char *path, char *out, size_t outSize) {
    if (!path || path[0] != '/' || !out || outSize == 0) {
        return false;
    }
    tdv_init_once();
    if (!__atomic_load_n(&gTDVRootEnabled, __ATOMIC_ACQUIRE)) {
        return false;
    }
    if (TDVRootShouldSkipPath(path)) {
        return false;
    }

    int savedErrno = errno;
    bool mapped = false;
    for (size_t i = 0; i < sizeof(kTDVRootPrefixes) / sizeof(kTDVRootPrefixes[0]); i++) {
        const TDVRootPrefixEntry *entry = &kTDVRootPrefixes[i];
        size_t plen = strlen(entry->prefix);
        if (strncmp(path, entry->prefix, plen) != 0) {
            continue;
        }
        if (path[plen] != '\0' && path[plen] != '/') {
            continue;
        }
        const char *tail = path;
        const char *suffix = "";
        if (entry->rewriteSuffix) {
            tail = path + plen;
            suffix = entry->rewriteSuffix;
        }
        int n = snprintf(out, outSize, "%s%s%s", gTDVRootRoot, suffix, tail);
        if (n > 0 && (size_t)n < outSize) {
            mapped = true;
        }
        break;
    }
    errno = savedErrno;
    if (!mapped && outSize) {
        out[0] = '\0';
    }
    return mapped;
}

void TDVRootInstallIfRequested(void) {
    pthread_mutex_lock(&gTDVRootLock);
    // 强制重读: 进程早期 interpose 调用可能已把配置读成 off.
    tdv_init_locked();
    __atomic_store_n(&gTDVRootInited, true, __ATOMIC_RELEASE);
    bool enabled = __atomic_load_n(&gTDVRootEnabled, __ATOMIC_RELAXED);
    TDVRootMode mode = gTDVRootMode;
    char root[PATH_MAX] = {0};
    memcpy(root, gTDVRootRoot, sizeof(root));
    pthread_mutex_unlock(&gTDVRootLock);

    if (enabled) {
        NSLog(@"[TDVRoot] enabled mode=%@ root=%s",
              mode == TDVRootModeFull ? @"full" : @"path", root);
    }
}

void TDVRootApplyEnvironmentOverrides(void) {
    // 先记录真实家目录 (full 模式马上要改写 HOME).
    pthread_mutex_lock(&gTDVRootLock);
    tdv_capture_homes_locked();
    pthread_mutex_unlock(&gTDVRootLock);

    const char *rawRoot = getenv("TD_VROOT");
    if (!rawRoot || rawRoot[0] != '/') {
        return;
    }
    TDVRootMode mode = tdv_parse_mode(getenv("TD_VROOT_MODE"));
    if (mode == TDVRootModeOff) {
        return;
    }
    char root[PATH_MAX];
    if (!tdv_normalize_absolute(rawRoot, root, sizeof(root)) || strcmp(root, "/") == 0) {
        return;
    }

    if (mode == TDVRootModeFull) {
        setenv("HOME", root, 1);
        setenv("CFFIXED_USER_HOME", root, 1);
    }

    // PATH 前置 vroot 的 bin 目录; 幂等 (已经以第一项开头则跳过).
    const char *oldPath = getenv("PATH");
    if (!oldPath) {
        oldPath = "/usr/bin:/bin:/usr/sbin:/sbin";
    }
    char first[PATH_MAX];
    int firstLen = snprintf(first, sizeof(first), "%s/usr/bin", root);
    if (firstLen <= 0 || (size_t)firstLen >= sizeof(first)) {
        return;
    }
    if (strncmp(oldPath, first, (size_t)firstLen) == 0 &&
        (oldPath[firstLen] == '\0' || oldPath[firstLen] == ':')) {
        return;
    }
    size_t rootLen = strlen(root);
    size_t need = (size_t)firstLen + strlen(oldPath) + 4 * rootLen + 128;
    char *newPath = malloc(need);
    if (!newPath) {
        return;
    }
    int n = snprintf(newPath, need, "%s:%s/bin:%s/usr/sbin:%s/sbin:%s/usr/local/bin:%s",
                     root, root, root, root, root, oldPath);
    if (n > 0 && (size_t)n < need) {
        setenv("PATH", newPath, 1);
    }
    free(newPath);
}
