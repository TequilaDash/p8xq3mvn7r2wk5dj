//
//  TDVRootConfig.m
//  TequilaDashLCUIAdapters
//
//  vroot (Tier A) 配置与路径映射. 只读: 不改写 on-disk 二进制, 不碰 dyld/签名/mount.
//  默认关: TD_VROOT 未设置或 TD_VROOT_MODE=off 时所有导出函数都是空操作.
//

#import "TDVRootConfig.h"

#import <Foundation/Foundation.h>

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <execinfo.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
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
static _Atomic bool gTDVProcSpoof = false;

static void tdv_init_once(void);

// 门控一律 live 读 env: 这些值由 launcher 按**每次启动** setenv, 而
// tdv_init_once 在常驻宿主进程里只跑一次 —— 首读之后 env 再变也不会被看到.
// (TD_PROC_SPOOF 在 1.1.55 已改为 live 读; 其余门控同样处理.)
static bool tdv_gate_live(const char *key) {
    const char *raw = getenv(key);
    return raw && raw[0] == '1';
}

bool TDVDyldTrimEnabled(void) {
    bool enabled = tdv_gate_live("TD_DYLD_TRIM");
    gTDVDyldTrim = enabled;
    return enabled;
}

bool TDVSysctlSpoofEnabled(void) {
    bool enabled = tdv_gate_live("TD_SYSCTL_SPOOF");
    gTDVSysctlSpoof = enabled;
    return enabled;
}

bool TDVSecTaskSpoofEnabled(void) {
    bool enabled = tdv_gate_live("TD_SECTASK_SPOOF");
    gTDVSecTaskSpoof = enabled;
    return enabled;
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

static bool tdv_string_ends_with(const char *s, const char *suffix) {
    size_t n = strlen(s), m = strlen(suffix);
    return n >= m && strncmp(s + n - m, suffix, m) == 0;
}

static const char *tdv_guest_bundle_component(const char *imagePath) {
    if (!imagePath || imagePath[0] != '/') return NULL;
    static const char *const roots[] = {
        "/Documents/Applications/",
        "/LiveContainer/Applications/", // bootstrap's shared app-group route
    };
    for (size_t i = 0; i < sizeof(roots) / sizeof(roots[0]); ++i) {
        const char *root = strstr(imagePath, roots[i]);
        if (!root) continue;
        const char *component = root + strlen(roots[i]);
        const char *end = strchr(component, '/');
        if (end && end[1] && end - component > 4 && memcmp(end - 4, ".app", 4) == 0) {
            return component;
        }
    }
    return NULL;
}

bool TDVGuestCallerIsGuestImage(const char *imagePath) {
    return tdv_guest_bundle_component(imagePath) != NULL;
}

// The frameworks that stand between an app and the bytes it reads. A frame in
// one of them is not the app, so the walk skips it.
static bool tdv_is_framework_frame(const char *imagePath) {
    static const char *const skips[] = {
        "/libobjc.", "/Foundation.", "/CoreFoundation.", "/libsystem_",
        "/libdispatch.", "/libswift", "/dyld", "/UIKitCore.",
        "/LiveContainerShared", "/TweakLoader",
    };
    for (size_t i = 0; i < sizeof(skips) / sizeof(skips[0]); ++i) {
        if (strstr(imagePath, skips[i])) return true;
    }
    return false;
}

void *TDVGuestCallerFrame(void) {
    void *frames[32];
    int count = backtrace(frames, 32);
    // frames[0] is this function; the app's frame is the first one that is not
    // a framework in between.
    for (int i = 1; i < count; ++i) {
        Dl_info info = {0};
        if (dladdr(frames[i], &info) == 0 || !info.dli_fname) continue;
        if (tdv_is_framework_frame(info.dli_fname)) continue;
        return frames[i];
    }
    return NULL;
}

bool TDVGuestBundleDirFromCallerImage(const char *callerImage, char *out, size_t outSize) {
    const char *component = tdv_guest_bundle_component(callerImage);
    if (!component || !out || outSize == 0) return false;
    size_t length = (size_t)(strchr(component, '/') - callerImage);
    if (length + 1 > outSize) {
        return false;
    }
    memcpy(out, callerImage, length);
    out[length] = '\0';
    return true;
}

// Small bounded profile cache, keyed by the guest bundle directory.
#define TDVGuestCacheSlots 4
static pthread_mutex_t gTDVGuestLock = PTHREAD_MUTEX_INITIALIZER;
// Backup lookups may re-enter interposed filesystem and Foundation APIs.
// Nested queries belong to this mapper, not to a new guest request.
static __thread bool gTDVGuestFileMapInProgress = false;
// NSBundle's CFBundle uses realpath while its Objective-C path can omit
// /private. Compare only this known iOS /var alias, without filesystem IO.
static const char *tdv_var_path(const char *path) {
    return strncmp(path, "/private/var/", 13) == 0 ? path + 8 : path;
}



__attribute__((visibility("default")))
TDVGuestFileMapResult TDVGuestMapBundleFile(const char *path, const char *callerImage,
                                            char *out, size_t outSize) {
    if (!path || !out || outSize == 0 || gTDVGuestFileMapInProgress) {
        return TDVGuestFileMapNone;
    }
    char bundle[PATH_MAX];
    if (!TDVGuestBundleDirFromCallerImage(callerImage, bundle, sizeof(bundle))) {
        return TDVGuestFileMapNone; // 宿主自身 / 未知 caller / 镜像不在 .app 里
    }
    char normalized[PATH_MAX];
    if (!tdv_normalize_absolute(path, normalized, sizeof(normalized))) return TDVGuestFileMapNone;
    const char *requested = tdv_var_path(normalized);
    const char *callerBundle = tdv_var_path(bundle);
    if (!tdv_path_is_under(requested, callerBundle)) {
        return TDVGuestFileMapNone;
    }
    const char *child = requested + strlen(callerBundle);
    if (child[0] != '/' || child[1] == '\0') {
        return TDVGuestFileMapNone;
    }
    child++;
    if (strchr(child, '/') != NULL) {
        return TDVGuestFileMapNone; // 只处理 bundle 根下的直接子文件
    }
    // 原件自己不该被访客看见: 让它读到 ENOENT, 否则"打开备份"就能绕过映射,
    // 而备份的存在本身也是容器化痕迹.
    if (strncmp(child, ".td-original.", strlen(".td-original.")) == 0 ||
        tdv_string_ends_with(child, ".td-original.executable")) {
        return TDVGuestFileMapHidden;
    }
    char backup[PATH_MAX];
    gTDVGuestFileMapInProgress = true;
    TDVGuestFileMapResult result = TDVGuestFileMapNone;
    if (strcmp(child, "embedded.mobileprovision") == 0) {
        // A missing backup is not proof that the imported app had no profile.
        // Leave the current file visible when no readable regular original exists.
        if (snprintf(backup, sizeof(backup), "%s/.td-original.mobileprovision", bundle) < (int)sizeof(backup)) {
            struct stat st;
            if (stat(backup, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0) {
                int length = snprintf(out, outSize, "%s", backup);
                result = length >= 0 && (size_t)length < outSize
                    ? TDVGuestFileMapTo : TDVGuestFileMapNone;
            }
        }
    } else if (strcmp(child, "Info.plist") == 0) {
        // `doUseLCBundleId` 会把包内 Info.plist 改成宿主标识符. 访客静态读这份文件
        // 时会立刻看到篡改; 有原件备份就交给它, 没备份则保持当前文件可用.
        if (snprintf(backup, sizeof(backup), "%s/.td-original.Info.plist", bundle) < (int)sizeof(backup)) {
            struct stat st;
            if (stat(backup, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0) {
                int length = snprintf(out, outSize, "%s", backup);
                result = length >= 0 && (size_t)length < outSize
                    ? TDVGuestFileMapTo : TDVGuestFileMapNone;
            }
        }
    } else {
        // 主可执行文件 (以及任何被打过并留了备份的直接子文件):
        // LCAppInfo 的备份名就是 `<原名>.td-original.executable`, 因此存在即命中.
        if (snprintf(backup, sizeof(backup), "%s/%s.td-original.executable", bundle, child) < (int)sizeof(backup)) {
            struct stat st;
            if (stat(backup, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0) {
                int length = snprintf(out, outSize, "%s", backup);
                result = length >= 0 && (size_t)length < outSize
                    ? TDVGuestFileMapTo : TDVGuestFileMapNone;
            }
        }
    }
    gTDVGuestFileMapInProgress = false;
    return result;
}

// profile 的 entitlements 缓存: 键 = bundle 目录.
static char gTDVGuestProfileBundles[TDVGuestCacheSlots][PATH_MAX];
static NSDictionary *gTDVGuestProfileEntitlements[TDVGuestCacheSlots];
static bool gTDVGuestProfileResolved[TDVGuestCacheSlots];
static unsigned gTDVGuestProfileNext = 0;

// `.td-original.mobileprovision` 是一段 CMS 包着一个 XML plist, 安装时的
// entitlements 就在那个 plist 里. 从字节里切出 plist 即可, 不引入 CMS 解析依赖.
// 解析不出来返回 nil (调用方保持现有行为).
static NSDictionary *tdv_profile_entitlements_from_path(const char *profilePath) {
    NSString *path = [NSString stringWithUTF8String:profilePath];
    if (!path) {
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data.length == 0) {
        return nil;
    }
    const char *bytes = (const char *)data.bytes;
    static const char kOpen[] = "<plist";
    static const char kXml[] = "<?xml";
    static const char kClose[] = "</plist>";
    const char *begin = memmem(bytes, data.length, kOpen, sizeof(kOpen) - 1);
    if (!begin) {
        begin = memmem(bytes, data.length, kXml, sizeof(kXml) - 1);
    }
    if (!begin) {
        return nil;
    }
    size_t rest = (size_t)(bytes + data.length - begin);
    const char *end = memmem(begin, rest, kClose, sizeof(kClose) - 1);
    if (!end) {
        return nil;
    }
    end += sizeof(kClose) - 1;
    NSData *plistData = [data subdataWithRange:NSMakeRange((size_t)(begin - bytes), (size_t)(end - begin))];
    NSDictionary *profile = [NSPropertyListSerialization propertyListWithData:plistData
                                                                      options:NSPropertyListImmutable
                                                                       format:NULL
                                                                        error:NULL];
    if (![profile isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    NSDictionary *entitlements = profile[@"Entitlements"];
    if (![entitlements isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    return entitlements;
}

// 只在调用方要求时读盘一次, 之后按 bundle 命中缓存 (锁内不做 IO 以外的分配).
static NSDictionary *tdv_guest_profile_entitlements_locked(const char *bundle) {
    for (int i = 0; i < TDVGuestCacheSlots; i++) {
        if (gTDVGuestProfileResolved[i] && strcmp(gTDVGuestProfileBundles[i], bundle) == 0) {
            return gTDVGuestProfileEntitlements[i];
        }
    }
    char profilePath[PATH_MAX];
    NSDictionary *entitlements = nil;
    if (snprintf(profilePath, sizeof(profilePath), "%s/.td-original.mobileprovision", bundle) < (int)sizeof(profilePath)) {
        entitlements = tdv_profile_entitlements_from_path(profilePath);
    }
    int slot = (int)(gTDVGuestProfileNext % TDVGuestCacheSlots);
    gTDVGuestProfileNext++;
    snprintf(gTDVGuestProfileBundles[slot], sizeof(gTDVGuestProfileBundles[slot]), "%s", bundle);
    gTDVGuestProfileEntitlements[slot] = entitlements;
    gTDVGuestProfileResolved[slot] = true;
    return entitlements;
}

// 替换表: 请求键 -> 原 profile 里可能带着同一事实的键 (首选在前). 表外的键一律不动,
// 宿主合法键仍走透传, 不在此处硬编码任何 bundle.
typedef struct {
    const char *requested;
    const char *profileKeys[3];
} TDVSecTaskReplacementEntry;

static const TDVSecTaskReplacementEntry kTDVSecTaskReplacements[] = {
    {"application-identifier", {"application-identifier", "com.apple.application-identifier", NULL}},
    {"com.apple.application-identifier", {"com.apple.application-identifier", "application-identifier", NULL}},
    {"team-identifier", {"team-identifier", "com.apple.developer.team-identifier", NULL}},
    {"com.apple.developer.team-identifier", {"com.apple.developer.team-identifier", "team-identifier", NULL}},
    {"keychain-access-groups", {"keychain-access-groups", "com.apple.keychain-access-groups", NULL}},
    {"com.apple.keychain-access-groups", {"com.apple.keychain-access-groups", "keychain-access-groups", NULL}},
    {"application-groups", {"com.apple.security.application-groups", "application-groups", NULL}},
    {"com.apple.security.application-groups", {"com.apple.security.application-groups", "application-groups", NULL}},
};

void *TDVSecTaskReplacementForEntitlement(const char *entitlement, const char *callerImage) {
    if (!entitlement || gTDVGuestFileMapInProgress || !TDVSecTaskSpoofEnabled() ||
        !TDVGuestCallerIsGuestImage(callerImage)) {
        return NULL;
    }
    char bundle[PATH_MAX];
    if (!TDVGuestBundleDirFromCallerImage(callerImage, bundle, sizeof(bundle))) {
        return NULL;
    }
    const TDVSecTaskReplacementEntry *entry = NULL;
    for (size_t i = 0; i < sizeof(kTDVSecTaskReplacements) / sizeof(kTDVSecTaskReplacements[0]); i++) {
        if (strcmp(entitlement, kTDVSecTaskReplacements[i].requested) == 0) {
            entry = &kTDVSecTaskReplacements[i];
            break;
        }
    }
    if (!entry) {
        return NULL;
    }
    gTDVGuestFileMapInProgress = true;
    pthread_mutex_lock(&gTDVGuestLock);
    NSDictionary *entitlements = tdv_guest_profile_entitlements_locked(bundle);
    id value = nil;
    for (int i = 0; i < 3 && entry->profileKeys[i] != NULL; i++) {
        id candidate = entitlements[[NSString stringWithUTF8String:entry->profileKeys[i]]];
        if ([candidate isKindOfClass:NSString.class] || [candidate isKindOfClass:NSArray.class]) {
            value = candidate;
            break;
        }
    }
    pthread_mutex_unlock(&gTDVGuestLock);
    gTDVGuestFileMapInProgress = false;
    if (!value) {
        return NULL; // 原 profile 里没有这个键 / 解析失败: 保持现有行为
    }
    return (void *)CFRetain((__bridge CFTypeRef)value);
}

bool TDVCsopsSpoofEnabled(void) {
    bool enabled = tdv_gate_live("TD_CSOPS_SPOOF");
    gTDVCsopsSpoof = enabled;
    return enabled;
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
    // 同样 live 读: 保留调试位是 per-app 键, 与其它门控同生命周期.
    if (!tdv_gate_live("TD_CSOPS_KEEP_DEBUGGED")) {
        v &= ~TDV_CS_DEBUGGED;
    }
    *flagsOut = v;
    return true;
}


bool TDVProcSpoofEnabled(void) {
    // True live read, bypassing tdv_init_once entirely: the resident
    // fullscreen host process runs this shim's initializers long before
    // LCBootstrap per-launch setenv, so the init-once cache (even refreshed
    // inside tdv_init_locked) freezes the pre-launch value forever. Every
    // mach_port_get_refs call then answered "spoof off" and Reveil kept
    // reporting the task port as externally referenced. getenv on a fixed
    // name is a cheap table walk next to each mach call.
    const char *raw = getenv("TD_PROC_SPOOF");
    bool enabled = raw && raw[0] == '1';
    gTDVProcSpoof = enabled;
    return enabled;
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
    // proc 族伪值独立于 vroot: TD_PROC_SPOOF. Re-read live: the resident
    // fullscreen host process initializes this shim before LCBootstrap sets
    // the per-launch env, and the cached 0 then never caught up — the guest
    // in fullscreen kept reporting "task port referenced extra". getenv on
    // a known-name key is a table lookup next to each mach call.
    {
        const char *rawProc = getenv("TD_PROC_SPOOF");
        bool procSpoofNow = rawProc && rawProc[0] == '1';
        gTDVProcSpoof = procSpoofNow;
    }
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
