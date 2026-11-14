//
//  TDRootHideInit.c
//  TequilaDash
//
//  本仓自有代码 —— 上游 roothide/libroothide init.c 的替代实现 (差异点见头文件).
//  上游 init.c 是 EPSL 之外的 MIT 文件, 我们没有拷它的推导逻辑, 而是重写为
//  「显式 setter + TD_VROOT 环境变量」两条通道 (见 TDRootHideInit.h).
//

#include "TDRootHideInit.h"

#include "common.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/syslimits.h>

// 上游 init.c 定义的两个全局 (common.h 里 extern); 我们的定义点.
EXPORT const char* __roothideinit_JBRAND = NULL;
EXPORT const char* __roothideinit_JBROOT = NULL;

static pthread_mutex_t gTDRootHideLock = PTHREAD_MUTEX_INITIALIZER;

static char gTDRootHideRoot[PATH_MAX];
static char gTDRootHideBrand[32];
static bool gTDRootHideInstalled = false;

#pragma mark - 内部

// 生成与 common.c is_jbrand_value 匹配的 brand 值:
// value 低 8 位 = (value>>8 ^ value>>16 ^ ... ^ value>>56) 的低 8 位.
static uint64_t tdroothide_make_brand(void) {
    uint64_t value = 0;
    for (int shift = 8; shift <= 56; shift += 8) {
        value |= ((uint64_t)(arc4random() & 0xFF)) << shift;
    }
    uint8_t check = (uint8_t)(value >> 8) ^ (uint8_t)(value >> 16) ^
                    (uint8_t)(value >> 24) ^ (uint8_t)(value >> 32) ^
                    (uint8_t)(value >> 40) ^ (uint8_t)(value >> 48) ^
                    (uint8_t)(value >> 56);
    value |= (uint64_t)check;
    return value;
}

// 调用方持锁. 拷贝根, 生成/复用 brand, 落 __roothideinit_* 全局.
static bool tdroothide_install_locked(const char *root) {
    if (!root || root[0] != '/') {
        return false;
    }
    size_t len = strlen(root);
    while (len > 1 && root[len - 1] == '/') {
        len--;
    }
    if (len <= 1 || len >= sizeof(gTDRootHideRoot)) {
        return false;
    }
    if (gTDRootHideInstalled &&
        strlen(gTDRootHideRoot) == len &&
        memcmp(gTDRootHideRoot, root, len) == 0) {
        return true; // 同根幂等
    }

    char brand[32];
    snprintf(brand, sizeof(brand), "%016llX", (unsigned long long)tdroothide_make_brand());

    char normalized[PATH_MAX];
    memcpy(normalized, root, len);
    normalized[len] = '\0';

    // 目录名若带 .jbroot-<hex> 组件, 校验其 brand 合法 (非法名会让 rootfs_alloc
    // 的名字组件识别失效, 上游语义).
    const char *last = strrchr(normalized, '/');
    if (last && !is_jbroot_name(last + 1)) {
        return false;
    }

    memcpy(gTDRootHideRoot, normalized, len + 1);
    memcpy(gTDRootHideBrand, brand, sizeof(brand));
    __roothideinit_JBROOT = gTDRootHideRoot;
    __roothideinit_JBRAND = gTDRootHideBrand;
    gTDRootHideInstalled = true;
    return true;
}

#pragma mark - 导出

bool TDRootHideSetJBRoot(const char *jbrootPath) {
    pthread_mutex_lock(&gTDRootHideLock);
    bool ok = tdroothide_install_locked(jbrootPath);
    pthread_mutex_unlock(&gTDRootHideLock);
    return ok;
}

bool TDRootHideInstallFromEnvIfRequested(void) {
    const char *rawRoot = getenv("TD_VROOT");
    if (!rawRoot || rawRoot[0] != '/') {
        return false;
    }
    // 与 Tier A TDVRootConfig 同一门控: TD_VROOT_MODE=off 即视为未安装.
    const char *rawMode = getenv("TD_VROOT_MODE");
    if (rawMode && (strcasecmp(rawMode, "off") == 0 || strcmp(rawMode, "0") == 0 ||
                    strcasecmp(rawMode, "false") == 0 || strcasecmp(rawMode, "no") == 0)) {
        return false;
    }
    pthread_mutex_lock(&gTDRootHideLock);
    bool ok = tdroothide_install_locked(rawRoot);
    pthread_mutex_unlock(&gTDRootHideLock);
    return ok;
}

const char *TDRootHideJBRootPath(void) {
    pthread_mutex_lock(&gTDRootHideLock);
    const char *root = gTDRootHideInstalled ? gTDRootHideRoot : NULL;
    pthread_mutex_unlock(&gTDRootHideLock);
    return root;
}

const char *TDRootHideJBRootBrand(void) {
    pthread_mutex_lock(&gTDRootHideLock);
    const char *brand = gTDRootHideInstalled ? gTDRootHideBrand : NULL;
    pthread_mutex_unlock(&gTDRootHideLock);
    return brand;
}

bool TDRootHideMakeRandomRootName(char *out, size_t outSize) {
    if (!out || outSize < sizeof(JB_ROOT_PREFIX) + JB_RAND_LENGTH) {
        return false;
    }
    char name[64];
    snprintf(name, sizeof(name), "%s%016llX", JB_ROOT_PREFIX,
             (unsigned long long)tdroothide_make_brand());
    if (!is_jbroot_name(name)) {
        return false; // 自检: 必须能被 vendored 名字代数识别
    }
    if (strlen(name) >= outSize) {
        return false;
    }
    strcpy(out, name);
    return true;
}

// TDLibVrootApi.dylib (symredirect shim 库) 的自举点: 被改写的 rootfs 二进制把它
// 装进任何进程时, 构造器从 TD_VROOT 恢复 JBROOT —— 等价上游 roothideinit.dylib
// 构造器的角色, 但输入是环境变量而不是库自身路径.
__attribute__((constructor)) static void _tdroothide_init(void) {
    TDRootHideInstallFromEnvIfRequested();
}
