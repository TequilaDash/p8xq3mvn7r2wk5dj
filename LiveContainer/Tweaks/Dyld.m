//
//  Dyld.m
//  LiveContainer
//
//  Created by s s on 2025/2/7.
//
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/mman.h>
#import "../../litehook/src/litehook.h"
#import "LCMachOUtils.h"
#include "mach_excServer.h"
#import "../utils.h"
#import "../dyld_bypass_validation.h"
@import Darwin;
@import Foundation;
@import MachO;

typedef uint32_t dyld_platform_t;

typedef struct {
    dyld_platform_t platform;
    uint32_t        version;
} dyld_build_version_t;

uint32_t lcImageIndex = 0;
uint32_t appMainImageIndex = 0;
void* appExecutableHandle = 0;
bool hookedDlopen = false;
bool tweakLoaderLoaded = false;
bool appExecutableFileTypeOverwritten = false;
const char* lcMainBundlePath = NULL;

// 前置声明: overwriteAppExecutableFileType / hook_dlsym 在本文件的更早位置使用.
static uint32_t tdv_guest_image_index(void);
static uint32_t tdv_guest_header_index(void);
static void tdv_rebuild_image_remap(void);
static void tdv_hide_image_if_needed(const struct mach_header *header);

void* (*orig_dlopen)(const char *path, int mode) = dlopen;
void* (*orig_dlsym)(void * __handle, const char * __symbol) = dlsym;
uint32_t (*orig_dyld_image_count)(void) = _dyld_image_count;
const struct mach_header* (*orig_dyld_get_image_header)(uint32_t image_index) = _dyld_get_image_header;
intptr_t (*orig_dyld_get_image_vmaddr_slide)(uint32_t image_index) = _dyld_get_image_vmaddr_slide;
const char* (*orig_dyld_get_image_name)(uint32_t image_index) = _dyld_get_image_name;
int (*orig_fcntl)(int fildes, int cmd, void *param) = 0;

uint32_t guestAppSdkVersion = 0;
uint32_t guestAppSdkVersionSet = 0;
bool (*orig_dyld_program_sdk_at_least)(void* dyldPtr, dyld_build_version_t version);
uint32_t (*orig_dyld_get_program_sdk_version)(void* dyldPtr);

mach_port_t excPort;
void *exception_handler(void *unused);

static void ensureBreakpointExceptionHandler(void) {
    if (excPort) return;

    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &excPort);
    mach_port_insert_right(mach_task_self(), excPort, excPort, MACH_MSG_TYPE_MAKE_SEND);
    pthread_t thread;
    pthread_create(&thread, NULL, exception_handler, NULL);
}

static const uint32_t kLCInvalidTweakLoaderCommand = 0x114514;
static const uint32_t kLCInvalidDuplicateCommand = 0x114515;
static struct mach_header_64 *gLCVisibleGuestHeader = NULL;

static bool lC_command_is_injected(const struct load_command *command,
                                   const uint8_t *commandsEnd) {
    if (!command || (const uint8_t *)command >= commandsEnd) return true;
    switch (command->cmd) {
        case LC_ID_DYLIB:
        case kLCInvalidTweakLoaderCommand:
        case kLCInvalidDuplicateCommand:
            return true;
        case LC_LOAD_DYLIB: {
            if (command->cmdsize < sizeof(struct dylib_command)) return false;
            const struct dylib_command *dylib = (const struct dylib_command *)command;
            uint32_t nameOffset = dylib->dylib.name.offset;
            if (nameOffset < sizeof(struct dylib_command) ||
                nameOffset >= command->cmdsize ||
                (const uint8_t *)command + nameOffset >= commandsEnd) {
                return false;
            }
            const char *name = (const char *)command + nameOffset;
            const char *nameEnd = (const char *)memchr(name, '\0',
                                                       commandsEnd - (const uint8_t *)name);
            if (!nameEnd) return false;
            return strcmp(name, "@loader_path/../../Tweaks/TweakLoader.dylib") == 0 ||
                   strcmp(name, "/var/containers/Bundle/Application/.kb-LiveContainerPrivateDocuments/Tweaks/TweakLoader.dylib") == 0;
        }
        default:
            return false;
    }
}

static void lC_clean_guest_executable_header(struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64) return;

    uint8_t *commands = (uint8_t *)header + sizeof(*header);
    uint8_t *commandsEnd = commands + header->sizeofcmds;
    uint8_t *source = commands;
    uint8_t *destination = commands;
    uint32_t visibleCommandCount = 0;
    uint32_t visibleCommandSize = 0;

    while (source + sizeof(struct load_command) <= commandsEnd) {
        struct load_command *command = (struct load_command *)source;
        uint32_t commandSize = command->cmdsize;
        if (commandSize < sizeof(struct load_command) ||
            source + commandSize > commandsEnd) {
            break;
        }
        if (!lC_command_is_injected(command, commandsEnd)) {
            if (destination != source) {
                memmove(destination, source, commandSize);
            }
            destination += commandSize;
            visibleCommandCount++;
            visibleCommandSize += commandSize;
        }
        source += commandSize;
    }

    header->ncmds = visibleCommandCount;
    header->sizeofcmds = visibleCommandSize;
    header->filetype = MH_EXECUTE;
}

static bool lC_refresh_guest_executable_header(void) {
    uint32_t guestHeaderIndex = tdv_guest_header_index();
    if (guestHeaderIndex == UINT32_MAX) guestHeaderIndex = appMainImageIndex;
    struct mach_header_64 *header =
        (struct mach_header_64 *)orig_dyld_get_image_header(guestHeaderIndex);
    if (!header) return false;

    bool alreadyCleaned = (header == gLCVisibleGuestHeader &&
                           header->filetype == MH_EXECUTE);
    if (alreadyCleaned) return true;

    char executablePath[PATH_MAX] = {};
    uint32_t executablePathSize = sizeof(executablePath);
    if (_NSGetExecutablePath(executablePath, &executablePathSize) == 0 &&
        executablePath[0] &&
        LCRestoreGuestExecutableMachOHeader(executablePath)) {
        header = (struct mach_header_64 *)orig_dyld_get_image_header(guestHeaderIndex);
        if (header) {
            gLCVisibleGuestHeader = header;
            return true;
        }
    }

    size_t protectedLength = sizeof(*header) + header->sizeofcmds;
    kern_return_t result = builtin_vm_protect(mach_task_self(),
                                               (vm_address_t)header,
                                               protectedLength,
                                               false,
                                               PROT_READ | PROT_WRITE | VM_PROT_COPY);
    if (result != KERN_SUCCESS) {
        NSLog(@"[LC] failed to make guest executable header writable");
        return false;
    }
    lC_clean_guest_executable_header(header);
    result = builtin_vm_protect(mach_task_self(),
                                (vm_address_t)header,
                                protectedLength,
                                false,
                                PROT_READ);
    if (result == KERN_SUCCESS) {
        gLCVisibleGuestHeader = header;
    }
    return result == KERN_SUCCESS;
}

static void overwriteAppExecutableFileType(void) {
    lC_refresh_guest_executable_header();
}

// 镜像清单裁剪: 维护一张"可见索引 -> 真实索引"映射表.
// 旧实现用 count-1-tweakLoader 的算术隐含"被隐藏的镜像必在末尾", 只盖得住
// LC 主镜像 + TweakLoader 两项; LC 的其余 framework 与 Documents/Tweaks 下的
// dylib 仍会以 (改名后的) 条目留在表里, 被检测器按"非系统路径"计数.
// 映射表把 LC 自身镜像 (bundle 前缀 / procursus) 与访客 tweak dylib 全部剔除,
// 同时把 index 0 固定为访客主可执行 (dyld 约定), 且每次新镜像加载后重建,
// 不存在"数量相等即认为没变"的陈旧问题.
#define TDV_HIDE_CAP 4096
static const struct mach_header *gTDVHiddenHeaders[TDV_HIDE_CAP];
static int gTDVHiddenCount = 0;
static uint32_t gTDVRemap[2][TDV_HIDE_CAP];
static uint32_t gTDVRemapCount[2];
static _Atomic int gTDVRemapActive = 0;
static bool gTDVRemapEnabled = false;
static bool gTDVMapLogged = false;
// 隐藏开关只控制 LiveContainer 自身镜像是否对访客可见; 注入的 tweak 镜像
// (TweakLoader / Documents/Tweaks) 一律不进枚举表 —— 全能签一类的自检会
// 枚举已加载镜像的 load command, 关掉"隐藏"不应该把注入面暴露出来.
static bool gTDVHideLCImages = false;

static bool tdv_is_hidden_path(const char *name) {
    if (!name || !name[0]) return false;
    // 注入面: 无条件隐藏.
    if (strstr(name, "/Documents/Tweaks/")) return true;
    if (strstr(name, "/TweakLoader.dylib")) return true;
    if (!gTDVHideLCImages) return false;
    if (lcMainBundlePath && lcMainBundlePath[0] &&
        strncmp(name, lcMainBundlePath, strlen(lcMainBundlePath)) == 0) {
        return true;
    }
    if (strstr(name, "/procursus/")) return true;
    return false;
}

static bool tdv_header_is_hidden(const struct mach_header *h) {
    for (int i = 0; i < gTDVHiddenCount; i++) {
        if (gTDVHiddenHeaders[i] == h) return true;
    }
    return false;
}

static void tdv_mark_hidden(const struct mach_header *h) {
    if (!h || tdv_header_is_hidden(h)) return;
    if (gTDVHiddenCount >= TDV_HIDE_CAP) return;
    gTDVHiddenHeaders[gTDVHiddenCount++] = h;
}

// 访客主可执行 = 第一个不是宿主/扩展自身的 MH_EXECUTE.
// 隐藏关闭时宿主镜像不会被标记为 hidden, 不排除 lcImageIndex 就会把它当成访客:
// getAppEntryPoint 会从宿主二进制读 LC_MAIN, 访客跳错入口后立即被终止.
// 隐藏开启时访客已被 LCPatchExecSlice 改成 MH_DYLIB, 这里返回 UINT32_MAX,
// 由调用方回退到 appMainImageIndex.
static uint32_t tdv_guest_image_index(void) {
    uint32_t total = orig_dyld_image_count();
    // The host process keeps previously launched guests mapped. Until the new
    // executable path has been resolved, its newest MH_EXECUTE is the current guest.
    for (uint32_t i = total; i > 0; i--) {
        uint32_t index = i - 1;
        if (index == lcImageIndex) continue;
        const struct mach_header *h = orig_dyld_get_image_header(index);
        if (!h || tdv_header_is_hidden(h)) continue;
        if (h->filetype == MH_EXECUTE) return index;
    }
    return UINT32_MAX;
}

// 当前访客的主镜像索引.
// dlopen 成功后 appMainImageIndex 已按路径解析成真实索引, 优先信任它:
// 常驻进程里上一轮访客的镜像仍在表内, 靠"第一个非隐藏 MH_EXECUTE"扫描
// 可能命中上一个访客. 只有它不是当前访客时才回退到扫描.
static uint32_t tdv_guest_header_index(void) {
    uint32_t total = orig_dyld_image_count();
    if (appMainImageIndex < total) {
        const struct mach_header *h = orig_dyld_get_image_header(appMainImageIndex);
        if (h && !tdv_header_is_hidden(h)) return appMainImageIndex;
    }
    return tdv_guest_image_index();
}

static void tdv_rebuild_image_remap(void) {
    if (!gTDVRemapEnabled) return;
    uint32_t total = orig_dyld_image_count();
    int inactive = 1 - atomic_load(&gTDVRemapActive);
    uint32_t *buf = gTDVRemap[inactive];
    uint32_t n = 0;
    uint32_t guest = tdv_guest_header_index();
    if (guest == UINT32_MAX) {
        // 还没有解析出访客时退化为"第一个非隐藏可执行文件", 保证 index 0 契约.
        guest = tdv_guest_image_index();
    }
    if (guest != UINT32_MAX) buf[n++] = guest;
    for (uint32_t i = 0; i < total && n < TDV_HIDE_CAP; i++) {
        if (i == guest) continue;
        const struct mach_header *h = orig_dyld_get_image_header(i);
        if (!h || tdv_header_is_hidden(h)) continue;
        buf[n++] = i;
    }
    gTDVRemapCount[inactive] = n;
    atomic_store(&gTDVRemapActive, inactive);

    // 首次拿到访客主可执行时把"访客能看到的镜像清单"打一遍: 检测器报"注入库"
    // 时用它直接对号, 不用再猜是哪条路径没被裁掉.
    if (!gTDVMapLogged && guest != UINT32_MAX) {
        gTDVMapLogged = true;
        for (uint32_t k = 0; k < n; k++) {
            const char *name = orig_dyld_get_image_name(buf[k]);
            NSLog(@"[TDImageMap] %u %s", k, name ? name : "?");
        }
    }
}

static inline bool tdv_map_image_index(uint32_t image_index, uint32_t *real_index) {
    if (!gTDVRemapEnabled) {
        *real_index = image_index;
        return true;
    }
    int active = atomic_load(&gTDVRemapActive);
    if (image_index >= gTDVRemapCount[active]) return false;
    *real_index = gTDVRemap[active][image_index];
    return true;
}

// 只通过加载时捕获的真实 dyld 表按 header 找路径，不在 add-image 回调里调用
// dladdr：dladdr 会在 dyld 正加载 tweak 时重入 dyld，读到尚未完成的映射。
static void tdv_hide_image_with_name(const struct mach_header *header, const char *name) {
    if (!header || !tdv_is_hidden_path(name)) return;
    tdv_mark_hidden(header);
}

static void tdv_hide_image_if_needed(const struct mach_header *header) {
    if (!gTDVRemapEnabled || !header) return;
    uint32_t total = orig_dyld_image_count();
    for (uint32_t i = 0; i < total; i++) {
        if (orig_dyld_get_image_header(i) == header) {
            tdv_hide_image_with_name(header, orig_dyld_get_image_name(i));
            return;
        }
    }
}

void* hook_dlsym(void * __handle, const char * __symbol) {
    // Detectors such as Reveil resolve csops through dlsym(RTLD_DEFAULT, ...),
    // which bypasses __DATA,__interpose. Route that lookup to TweakLoader's
    // exported replacement when the csops spoof gate is enabled.
    if (__handle == (void*)RTLD_DEFAULT && __symbol && getenv("TD_CSOPS_SPOOF") &&
        getenv("TD_CSOPS_SPOOF")[0] == '1') {
        if (strcmp(__symbol, "csops") == 0) {
            void *replacement = orig_dlsym(RTLD_DEFAULT, "TDVReplacementCsops");
            if (replacement) return replacement;
        } else if (strcmp(__symbol, "csops_audittoken") == 0) {
            void *replacement = orig_dlsym(RTLD_DEFAULT, "TDVReplacementCsopsAuditToken");
            if (replacement) return replacement;
        }
    }
    if(__handle == (void*)RTLD_MAIN_ONLY) {
        if(strcmp(__symbol, MH_EXECUTE_SYM) == 0) {
            if(!appExecutableFileTypeOverwritten) {
                overwriteAppExecutableFileType();
                appExecutableFileTypeOverwritten = true;
            }
            uint32_t guestHeaderIndex = tdv_guest_header_index();
            if (guestHeaderIndex == UINT32_MAX) guestHeaderIndex = appMainImageIndex;
            return (void*)orig_dyld_get_image_header(guestHeaderIndex);
        }
        __handle = appExecutableHandle;
    } else if (__handle != (void*)RTLD_SELF && __handle != (void*)RTLD_NEXT) {
        void* ans = orig_dlsym(__handle, __symbol);
        if(!ans) {
            return 0;
        }
        for(int i = 0; i < gRebindCount; i++) {
            global_rebind rebind = gRebinds[i];
            if(ans == rebind.replacee) {
                return rebind.replacement;
            }
        }
        return ans;
    }
    
    __attribute__((musttail)) return orig_dlsym(__handle, __symbol);
}

uint32_t hook_dyld_image_count(void) {
    if (!gTDVRemapEnabled) return orig_dyld_image_count();
    return gTDVRemapCount[atomic_load(&gTDVRemapActive)];
}

const struct mach_header* hook_dyld_get_image_header(uint32_t image_index) {
    uint32_t real_index = 0;
    if (!tdv_map_image_index(image_index, &real_index)) return NULL;
    const struct mach_header *header = orig_dyld_get_image_header(real_index);
    if (image_index == 0 && header &&
        (header->filetype != MH_EXECUTE ||
         (const struct mach_header *)gLCVisibleGuestHeader != header)) {
        lC_refresh_guest_executable_header();
    }
    return header;
}

intptr_t hook_dyld_get_image_vmaddr_slide(uint32_t image_index) {
    uint32_t real_index = 0;
    if (!tdv_map_image_index(image_index, &real_index)) return 0;
    return orig_dyld_get_image_vmaddr_slide(real_index);
}

// Detectors (Reveil-class) treat any image outside the system directories as
// injected. A guest's own executable and frameworks live under
// Documents/Applications/<folder>/, so they all match unless the reported
// name is masked. Rewrite it to the shape a normal install has:
// /var/containers/Bundle/Application/<uuid>/<bundle-id>.app/<image>.
// The real path keeps working for everything that stats the file: dyld's
// own tables still carry it, and file reads go through the kernel path.
const char *guestExecutableMaskedName(const char *realName);

const char* hook_dyld_get_image_name(uint32_t image_index) {
    uint32_t real_index = 0;
    if (!tdv_map_image_index(image_index, &real_index)) return NULL;
    const char *name = orig_dyld_get_image_name(real_index);
    if (name && strstr(name, "/Documents/Applications/")) {
        return guestExecutableMaskedName(name);
    }
    return name;
}

void TDRefreshDyldImageRemap(void) {
    if (!gTDVRemapEnabled) return;
    uint32_t total = orig_dyld_image_count();
    for (uint32_t i = 0; i < total; i++) {
        tdv_hide_image_if_needed(orig_dyld_get_image_header(i));
    }
    tdv_rebuild_image_remap();
}

void* getDSCAddr(void) {
    task_dyld_info_data_t dyldInfo;
    
    uint32_t count = TASK_DYLD_INFO_COUNT;
    task_info(mach_task_self_, TASK_DYLD_INFO, (task_info_t)&dyldInfo, &count);
    struct dyld_all_image_infos *infos = (struct dyld_all_image_infos *)dyldInfo.all_image_info_addr;
    return (void*)infos->sharedCacheBaseAddress;
}

void* getCachedSymbol(NSString* symbolName, mach_header_u* header) {
    NSDictionary* symbolOffsetDict = [NSUserDefaults.lcSharedDefaults objectForKey:@"symbolOffsetCache"][symbolName];
    if(!symbolOffsetDict) {
        return NULL;
    }
    NSData* cachedSymbolUUID = symbolOffsetDict[@"uuid"];
    if(!cachedSymbolUUID) {
        return NULL;
    }
    const uint8_t* uuid = LCGetMachOUUID(header);
    if(!uuid || memcmp(uuid, [cachedSymbolUUID bytes], 16)) {
        return NULL;
    }
    
    return (void*)header + [symbolOffsetDict[@"offset"] unsignedLongLongValue];
}

void saveCachedSymbol(NSString* symbolName, mach_header_u* header, uint64_t offset) {
    NSMutableDictionary* allSymbolOffsetDict = [[NSUserDefaults.lcSharedDefaults objectForKey:@"symbolOffsetCache"] mutableCopy];
    if(!allSymbolOffsetDict) {
        allSymbolOffsetDict = [[NSMutableDictionary alloc] init];
    }
    
    allSymbolOffsetDict[symbolName] = @{
        @"uuid": [NSData dataWithBytes:LCGetMachOUUID(header) length:16],
        @"offset": @(offset),
    };
    [NSUserDefaults.lcSharedDefaults setObject:allSymbolOffsetDict forKey:@"symbolOffsetCache"];
}

bool hook_dyld_program_sdk_at_least(void* dyldApiInstancePtr, dyld_build_version_t version) {
    // we are targeting ios, so we hard code 2
    if(version.platform == 0xffffffff){
        return version.version <= guestAppSdkVersionSet;
    } else if (version.platform != 1){
        return version.version <= guestAppSdkVersion;
    } else {
        return false;
    }
}

uint32_t hook_dyld_get_program_sdk_version(void* dyldApiInstancePtr) {
    return guestAppSdkVersion;
}


bool performHookDyldApi(const char* functionName, uint32_t adrpOffset, void** origFunction, void* hookFunction) {
    
    uint32_t* baseAddr = dlsym(RTLD_DEFAULT, functionName);
    assert(baseAddr != 0);
    uint32_t* adrpInstPtr = baseAddr + adrpOffset;

    // find the following instruction pattern: 1 adrp + 2 ldr
    // adrp    x8, 0x1e6cf0000
    // ldr     x0, [x8, #0x30]  {dyld4::gAPIs}
    // ldr     x16, [x0]
    
    static long adrpExtraOffset = -1;
    if(adrpExtraOffset == -1) {
        // let't hope the function is not longer than 200 instructions
        uint32_t* end = baseAddr + 200;
        for(uint32_t* cur = adrpInstPtr;cur < end;++cur) {
            if ((*cur & 0x9f000000) != 0x90000000) {
                continue;
            }
            if ((*(cur+1) & 0xFFC00000) != 0xF9400000) {
                continue;
            }
            if ((*(cur+2) & 0xFFC00000) != 0xF9400000) {
                continue;
            }
            adrpExtraOffset = cur - adrpInstPtr;
            break;
        }
        assert(adrpExtraOffset != -1);
    }
    
    adrpInstPtr += adrpExtraOffset;

    void* gdyldPtr = (void*)aarch64_emulate_adrp_ldr(*adrpInstPtr, *(adrpInstPtr + 1), (uint64_t)adrpInstPtr);
    
    assert(gdyldPtr != 0);
    assert(*(void**)gdyldPtr != 0);
    void* vtablePtr = **(void***)gdyldPtr;
    
    void* vtableFunctionPtr = 0;
    uint32_t* movInstPtr = adrpInstPtr + 6;

    if((*movInstPtr & 0x7F800000) == 0x52800000) {
        // arm64e, mov imm + add + ldr
        uint32_t imm16 = (*movInstPtr & 0x1FFFE0) >> 5;
        vtableFunctionPtr = vtablePtr + imm16;
    } else if ((*movInstPtr & 0xFFE00C00) == 0xF8400C00) {
        // arm64e, ldr immediate Pre-index 64bit
        uint32_t imm9 = (*movInstPtr & 0x1FF000) >> 12;
        vtableFunctionPtr = vtablePtr + imm9;
    } else {
        // arm64
        uint32_t* ldrInstPtr2 = adrpInstPtr + 3;
        assert((*ldrInstPtr2 & 0xBFC00000) == 0xB9400000);
        uint32_t size2 = (*ldrInstPtr2 & 0xC0000000) >> 30;
        uint32_t imm12_2 = (*ldrInstPtr2 & 0x3FFC00) >> 10;
        vtableFunctionPtr = vtablePtr + (imm12_2 << size2);
    }

    
    kern_return_t ret = builtin_vm_protect(mach_task_self(), (mach_vm_address_t)vtableFunctionPtr, sizeof(uintptr_t), false, PROT_READ | PROT_WRITE | VM_PROT_COPY);
    if(ret != KERN_SUCCESS) {
        assert(os_tpro_is_supported());
        os_thread_self_restrict_tpro_to_rw();
    }
    *origFunction = (void*)*(void**)vtableFunctionPtr;
    *(uint64_t*)vtableFunctionPtr = (uint64_t)hookFunction;
    builtin_vm_protect(mach_task_self(), (mach_vm_address_t)vtableFunctionPtr, sizeof(uintptr_t), false, PROT_READ);
    if(ret != KERN_SUCCESS) {
        assert(os_tpro_is_supported());
        os_thread_self_restrict_tpro_to_ro();
    }
    return true;
}

bool initGuestSDKVersionInfo(void) {
    void* dyldBase = getDyldBase();
    // it seems Apple is constantly changing findVersionSetEquivalent's signature so we directly search sVersionMap instead
    uint32_t* versionMapPtr = getCachedSymbol(@"__ZN5dyld3L11sVersionMapE", dyldBase);
    // check if the cached pointer is valid in case dyld is swapped by Dopamine. #1454
    if(!versionMapPtr || versionMapPtr[0] != 0x07db0901) {
#if !TARGET_OS_SIMULATOR
        const char* dyldPath = "/usr/lib/dyld";
#else
        const char* dyldPath = "/usr/lib/dyld_sim";
#endif
        uint64_t offset = 0;
        if(@available(iOS 27.0, *)) {
            offset = LCFindSymbolOffset(dyldPath, "__ZN5dyld311sVersionMapE");
        } else {
            offset = LCFindSymbolOffset(dyldPath, "__ZN5dyld3L11sVersionMapE");
        }
        assert(offset);
        versionMapPtr = dyldBase + offset;
        saveCachedSymbol(@"__ZN5dyld3L11sVersionMapE", dyldBase, offset);
    }
    
    assert(versionMapPtr);
    // however sVersionMap's struct size is also unknown, but we can figure it out
    // we assume the size is 10K so we won't need to change this line until maybe iOS 40
    uint32_t* versionMapEnd = versionMapPtr + 2560;
    // ensure the first is versionSet and the third is iOS version (5.0.0)
    assert(versionMapPtr[0] == 0x07db0901 && versionMapPtr[2] == 0x00050000);
    // get struct size. we assume size is smaller then 128. appearently Apple won't have so many platforms
    uint32_t size = 0;
    for(int i = 1; i < 128; ++i) {
        // find the next versionSet (for 6.0.0)
        if(versionMapPtr[i] == 0x07dc0901) {
            size = i;
            break;
        }
    }
    assert(size);
    
    NSOperatingSystemVersion currentVersion = [[NSProcessInfo processInfo] operatingSystemVersion];
    uint32_t maxVersion = ((uint32_t)currentVersion.majorVersion << 16) | ((uint32_t)currentVersion.minorVersion << 8);
    
    uint32_t candidateVersion = 0;
    uint32_t candidateVersionEquivalent = 0;
    uint32_t newVersionSetVersion = 0;
    for(uint32_t* nowVersionMapItem = versionMapPtr; nowVersionMapItem < versionMapEnd; nowVersionMapItem += size) {
        newVersionSetVersion = nowVersionMapItem[2];
        if (newVersionSetVersion > guestAppSdkVersion) { break; }
        candidateVersion = newVersionSetVersion;
        candidateVersionEquivalent = nowVersionMapItem[0];
        if(newVersionSetVersion >= maxVersion) { break; }
    }
    
    if (newVersionSetVersion == 0xffffffff && candidateVersion == 0) {
        candidateVersionEquivalent = newVersionSetVersion;
    }

    guestAppSdkVersionSet = candidateVersionEquivalent;
    
    return true;
}

#if TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR
void DyldHookLoadableIntoProcess(void) {
    uint32_t *patchAddr = (uint32_t *)litehook_find_symbol(getDyldBase(), "__ZNK6mach_o6Header19loadableIntoProcessENS_8PlatformE7CStringb");
    size_t patchSize = sizeof(uint32_t[2]);

    kern_return_t kret;
    kret = builtin_vm_protect(mach_task_self(), (vm_address_t)patchAddr, patchSize, false, PROT_READ | PROT_WRITE | VM_PROT_COPY);
    assert(kret == KERN_SUCCESS);

    patchAddr[0] = 0xD2800020; // mov x0, #1
    patchAddr[1] = 0xD65F03C0; // ret

    kret = builtin_vm_protect(mach_task_self(), (vm_address_t)patchAddr, patchSize, false, PROT_READ | PROT_EXEC);
    assert(kret == KERN_SUCCESS);
}
#endif

void DyldHooksInit(bool hideLiveContainer, bool hookDlopen, uint32_t spoofSDKVersion) {
    // 每次启动访客都重置裁剪状态: 同一个进程里可能先后以"隐藏开/关"启动不同访客,
    // 而 litehook 的符号重绑不可逆. 不重置的话, 先开隐藏再关隐藏的那次启动仍会
    // 走裁剪后的索引表 (index0 契约错位) -> 主可执行入口取错 -> App 被终止.
    gTDVHiddenCount = 0;
    gTDVRemapEnabled = false;
    gTDVRemapCount[0] = 0;
    gTDVRemapCount[1] = 0;
    atomic_store(&gTDVRemapActive, 0);
    gTDVMapLogged = false;
    gLCVisibleGuestHeader = NULL;
    lcImageIndex = UINT32_MAX;
    
    // 复制成自有缓冲区: fileSystemRepresentation 的生命周期不归我们管, 但这条路径
    // 之后要被镜像枚举/回调反复比较. 常驻进程会多次启动访客, 先释放上一轮.
    free((void *)lcMainBundlePath);
    if(NSUserDefaults.isLiveProcess) {
        lcMainBundlePath = strdup(NSUserDefaults.lcMainBundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.fileSystemRepresentation);
    } else {
        lcMainBundlePath = strdup(NSUserDefaults.lcMainBundle.bundlePath.fileSystemRepresentation);
    }
    // 常驻进程会保留上一轮访客镜像；不能按第一个 MH_EXECUTE 猜宿主。
    // 用加载时捕获的真实 dyld 表按宿主 bundle 路径定位。
    uint32_t imageCount = orig_dyld_image_count();
    if (lcMainBundlePath && lcMainBundlePath[0]) {
        size_t bundlePathLength = strlen(lcMainBundlePath);
        for (uint32_t i = 0; i < imageCount; i++) {
            const struct mach_header *header = orig_dyld_get_image_header(i);
            const char *name = orig_dyld_get_image_name(i);
            if (header && header->filetype == MH_EXECUTE && name &&
                strncmp(name, lcMainBundlePath, bundlePathLength) == 0 &&
                name[bundlePathLength] == '/') {
                lcImageIndex = i;
                break;
            }
        }
    }
    // 不重新赋值 orig_dyld_get_image_header: 文件顶部的静态初始化已在加载时
    // 捕获真实实现；上一次隐藏启动可能已把该符号重绑到 hook，这里再取一次会把
    // orig 指回 hook 自身，递归调用直接爆栈（表现为访客被终止）。
    
    // hook dlsym to solve RTLD_MAIN_ONLY, hook other functions to hide LiveContainer itself
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, dlsym, hook_dlsym, nil);
    // 所有进程统一裁剪注入面 (TweakLoader / Documents/Tweaks)；隐藏开关只决定
    // LiveContainer 自身镜像是否可见。规则对任何访客一致，不做应用名判断。
    gTDVHideLCImages = hideLiveContainer;
    gTDVRemapEnabled = true;
    if (gTDVRemapEnabled) {
        uint32_t initialCount = orig_dyld_image_count();
        for (uint32_t i = 0; i < initialCount; i++) {
            tdv_hide_image_if_needed(orig_dyld_get_image_header(i));
        }
        tdv_rebuild_image_remap();
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, _dyld_image_count, hook_dyld_image_count, nil);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, _dyld_get_image_header, hook_dyld_get_image_header, nil);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, _dyld_get_image_vmaddr_slide, hook_dyld_get_image_vmaddr_slide, nil);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, _dyld_get_image_name, hook_dyld_get_image_name, nil);
    }
    
    appExecutableFileTypeOverwritten = !hideLiveContainer;
    
    if(spoofSDKVersion) {
        guestAppSdkVersion = spoofSDKVersion;
        if(!initGuestSDKVersionInfo() ||
           !performHookDyldApi("dyld_program_sdk_at_least", 1, (void**)&orig_dyld_program_sdk_at_least, hook_dyld_program_sdk_at_least) ||
           !performHookDyldApi("dyld_get_program_sdk_version", 0, (void**)&orig_dyld_get_program_sdk_version, hook_dyld_get_program_sdk_version)) {
            return;
        }
    }
    
    hookedDlopen = hookDlopen;
    if(hookDlopen) {
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, dlopen, jitless_hook_dlopen, nil);
    }
    
#if TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR
    DyldHookLoadableIntoProcess();
#endif
}

void* getGuestAppHeader(void) {
    lC_refresh_guest_executable_header();
    uint32_t guest = tdv_guest_header_index();
    if (guest == UINT32_MAX) guest = appMainImageIndex;
    return (void*)orig_dyld_get_image_header(guest);
}

void LCRefreshGuestExecutableHeader(void) {
    lC_refresh_guest_executable_header();
}

// 真实镜像总数: 隐藏开启时 _dyld_image_count 已被重绑成"可见数量",
// 不能再当作 dlopen 前的位置索引使用.
uint32_t LCRealImageCount(void) {
    return orig_dyld_image_count();
}

// 按路径定位访客主镜像的真实索引.
// "dlopen 之前的数量"在常驻进程里不可靠: 隐藏态拿到的是可见数量, 同一进程
// 反复启动访客时上一轮的镜像也还在表里. 直接比路径是唯一确定的做法.
uint32_t LCGuestImageIndexForPath(const char *path) {
    if (!path || !path[0]) return UINT32_MAX;
    const char *guestName = strrchr(path, '/');
    guestName = guestName ? guestName + 1 : path;
    uint32_t total = orig_dyld_image_count();
    for (uint32_t i = 0; i < total; i++) {
        const char *name = orig_dyld_get_image_name(i);
        if (!name) continue;
        if (strcmp(name, path) == 0) return i;
    }
    // 同名可执行可能有多份（常驻进程里上一轮访客仍在表内），从后往前取最新加载的。
    for (uint32_t i = total; i > 0; i--) {
        const char *name = orig_dyld_get_image_name(i - 1);
        if (!name) continue;
        const char *base = strrchr(name, '/');
        base = base ? base + 1 : name;
        if (strcmp(base, guestName) == 0) return i - 1;
    }
    return UINT32_MAX;
}

void LCRebuildImageRemap(void) {
    tdv_rebuild_image_remap();
}

#pragma mark - Fix black screen
#if !TARGET_OS_SIMULATOR
#define HOOK_LOCK_1ST_ARG void *ptr,
#else
#define HOOK_LOCK_1ST_ARG
#endif
static void *lockPtrToIgnore;
static mach_port_t tidToIgnore;
void hook_libdyld_os_unfair_recursive_lock_lock_with_options(HOOK_LOCK_1ST_ARG void* lock, uint32_t options) {
    if(!lockPtrToIgnore) lockPtrToIgnore = lock;
    if(lock != lockPtrToIgnore || tidToIgnore != mach_thread_self()) {
        os_unfair_recursive_lock_lock_with_options(lock, options);
    }
}
void hook_libdyld_os_unfair_recursive_lock_unlock(HOOK_LOCK_1ST_ARG void* lock) {
    if(lock != lockPtrToIgnore || tidToIgnore != mach_thread_self()) {
        os_unfair_recursive_lock_unlock(lock);
    }
}

bool hook_libdyld_os_unfair_recursive_lock_trylock(HOOK_LOCK_1ST_ARG void* lock) {
    if(!lockPtrToIgnore) lockPtrToIgnore = lock;
    if(lock != lockPtrToIgnore || tidToIgnore != mach_thread_self()) {
        return os_unfair_recursive_lock_trylock(lock);
    }
    return true;
}

static void* findDyldSymbolWithCache(NSString* symbolName, void** ptrStorage) {
    if(*ptrStorage) {
        return *ptrStorage;
    }
    void *dyldBase = getDyldBase();
    *ptrStorage = getCachedSymbol(symbolName, dyldBase);
    if(!*ptrStorage) {
        void *dyldBase = getDyldBase();
        uint64_t offset = LCFindSymbolOffset("/usr/lib/dyld", symbolName.UTF8String);
        *ptrStorage = dyldBase + offset;
        saveCachedSymbol(symbolName, dyldBase, offset);
    }
    return *ptrStorage;
}

// return index of that function in vtable
int searchVtable(void** vtable, void *func) {
    for(int i = 0; i < 100; ++i) {
        if(vtable[i] == func) {
            return i;
        }
    }
    return -1;
}

void *dlopen_nolock(const char *path, int mode) {
    tidToIgnore = mach_thread_self();
    const char *libdyldPath = "/usr/lib/system/libdyld.dylib";
    mach_header_u *libdyldHeader = LCGetLoadedImageHeader(0, libdyldPath);
    assert(libdyldHeader != NULL);
#if !TARGET_OS_SIMULATOR
    NSString *lockPtrName = @"dyld4::LibSystemHelpers::os_unfair_recursive_lock_lock_with_options";
    NSString *unlockPtrName = @"dyld4::LibSystemHelpers::os_unfair_recursive_lock_unlock_with_options";
    NSString *tryLockPtrName = @"dyld4::LibSystemHelpers::os_unfair_recursive_lock_trylock";
    void **lockPtr = getCachedSymbol(lockPtrName, libdyldHeader);
    void **unlockPtr = getCachedSymbol(unlockPtrName, libdyldHeader);
    void **trylockPtr = 0;
    bool shouldPatchTrylock = false;
    if(@available(iOS 26.5, *)) {
        shouldPatchTrylock = true;
        trylockPtr = getCachedSymbol(tryLockPtrName, libdyldHeader);
    }
    
    if(!unlockPtr || !lockPtr || (shouldPatchTrylock && !trylockPtr)) {
        void **vtableLibSystemHelpers = litehook_find_dsc_symbol(libdyldPath, "__ZTVN5dyld416LibSystemHelpersE");
        
        if(!lockPtr) {
            void *lockFunc = litehook_find_dsc_symbol(libdyldPath, "__ZNK5dyld416LibSystemHelpers42os_unfair_recursive_lock_lock_with_optionsEP26os_unfair_recursive_lock_s24os_unfair_lock_options_t");
            int lockOffset = searchVtable(vtableLibSystemHelpers, lockFunc);
            NSCAssert(lockOffset != -1, @"dyld has changed: lockOffset not found in vtable");
            lockPtr = vtableLibSystemHelpers + lockOffset;
            saveCachedSymbol(lockPtrName, libdyldHeader, (uintptr_t)lockPtr - (uintptr_t)libdyldHeader);
        }
        
        if(!unlockPtr) {
            void *unlockFunc = litehook_find_dsc_symbol(libdyldPath, "__ZNK5dyld416LibSystemHelpers31os_unfair_recursive_lock_unlockEP26os_unfair_recursive_lock_s");
            int unlockOffset = searchVtable(vtableLibSystemHelpers, unlockFunc);
            NSCAssert(unlockOffset != -1, @"dyld has changed: unlockOffset not found in vtable");
            unlockPtr = vtableLibSystemHelpers + unlockOffset;
            saveCachedSymbol(unlockPtrName, libdyldHeader, (uintptr_t)unlockPtr - (uintptr_t)libdyldHeader);
        }
        
        if(shouldPatchTrylock && !trylockPtr) {
            // after 26.5b2 dyld4::RuntimeLocks::couldDlopenLock is added and called when dlopen is called with RTLD_NO_LOAD,
            // which calls os_unfair_recursive_lock_trylock, so we should also hook that
            void *tryLockFunc = litehook_find_dsc_symbol(libdyldPath, "__ZNK5dyld416LibSystemHelpers32os_unfair_recursive_lock_trylockEP26os_unfair_recursive_lock_s");
            int trylockOffset = searchVtable(vtableLibSystemHelpers, tryLockFunc);
            // in case people use b1, we don't use NSCAssert here
            if(trylockOffset != -1) {
                trylockPtr = vtableLibSystemHelpers + trylockOffset;
                saveCachedSymbol(tryLockPtrName, libdyldHeader, (uintptr_t)trylockPtr - (uintptr_t)libdyldHeader);
            } else {
                NSLog(@"dyld has changed: trylockOffset not found in vtable");
                shouldPatchTrylock = false;
            }
        }
    }
    
    kern_return_t ret;
    mach_vm_address_t vtablePageStart = (mach_vm_address_t)((uint64_t)lockPtr & ~(16384 - 1));
    
    ret = builtin_vm_protect(mach_task_self(), vtablePageStart, 16384, false, PROT_READ | PROT_WRITE | VM_PROT_COPY);
    bool tproUnlocked = ret != KERN_SUCCESS;
    if(tproUnlocked) {
        assert(os_tpro_is_supported());
        os_thread_self_restrict_tpro_to_rw();
    }
    void *origLockPtr = *lockPtr, *origUnlockPtr = *unlockPtr, *origTryLockPtr = 0;
    *lockPtr = hook_libdyld_os_unfair_recursive_lock_lock_with_options;
    *unlockPtr = hook_libdyld_os_unfair_recursive_lock_unlock;
    if(shouldPatchTrylock) {
        origTryLockPtr = *trylockPtr;
        *trylockPtr = hook_libdyld_os_unfair_recursive_lock_trylock;
    }
    
    builtin_vm_protect(mach_task_self(), vtablePageStart, 16384, false, PROT_READ);
    if(tproUnlocked) {
        os_thread_self_restrict_tpro_to_ro();
    }
    
    void *result;
    if(hookedDlopen) {
        result = jitless_hook_dlopen(path, mode);
    } else {
        result = dlopen(path, mode);
    }
    
    ret = builtin_vm_protect(mach_task_self(), vtablePageStart, 16384, false, PROT_READ | PROT_WRITE);
    tproUnlocked = ret != KERN_SUCCESS;
    if(tproUnlocked) {
        assert(os_tpro_is_supported());
        os_thread_self_restrict_tpro_to_rw();
    }
    *lockPtr = origLockPtr;
    *unlockPtr = origUnlockPtr;
    if(shouldPatchTrylock) {
        *trylockPtr = origTryLockPtr;
    }
    
    builtin_vm_protect(mach_task_self(), vtablePageStart, 16384, false, PROT_READ);
    if(tproUnlocked) {
        os_thread_self_restrict_tpro_to_ro();
    }
#else
    litehook_rebind_symbol(libdyldHeader, os_unfair_recursive_lock_lock_with_options, hook_libdyld_os_unfair_recursive_lock_lock_with_options, nil);
    litehook_rebind_symbol(libdyldHeader, os_unfair_recursive_lock_unlock, hook_libdyld_os_unfair_recursive_lock_unlock, nil);
    void *result = dlopen(path, mode);
    litehook_rebind_symbol(libdyldHeader, hook_libdyld_os_unfair_recursive_lock_lock_with_options, os_unfair_recursive_lock_lock_with_options, nil);
    litehook_rebind_symbol(libdyldHeader, hook_libdyld_os_unfair_recursive_lock_unlock, os_unfair_recursive_lock_unlock, nil);
#endif
    return result;
}

#pragma mark - Workaround `file system sandbox blocked mmap()`
// when using multitask app in private container, we need to temporarily hook dyld's mmap
void *exception_handler(void *unused) {
    mach_msg_server(mach_exc_server, sizeof(union __RequestUnion__catch_mach_exc_subsystem), excPort, MACH_MSG_OPTION_NONE);
    abort();
}

void *jitless_hook_dlopen(const char *path, int mode) {
    searchDyldFunctions();
    if (!excPort) {
        ensureBreakpointExceptionHandler();
    }
    
    // save old thread states
    exception_mask_t mask = EXC_MASK_BREAKPOINT;
    mach_msg_type_number_t masksCnt = 1;
    exception_handler_t handler = excPort;
    exception_behavior_t behavior = EXCEPTION_STATE | MACH_EXCEPTION_CODES;
    thread_state_flavor_t flavor = ARM_THREAD_STATE64;
    arm_debug_state64_t origDebugState;
    mach_port_t thread = mach_thread_self();
    thread_get_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&origDebugState, &(mach_msg_type_number_t){ARM_DEBUG_STATE64_COUNT});
    thread_swap_exception_ports(thread, mask, handler, behavior, flavor, &mask, &masksCnt, &handler, &behavior, &flavor);
    assert(masksCnt == 1);
    
    // hook dyld's mmap
    arm_debug_state64_t hookDebugState = origDebugState;
    hookDebugState.__bvr[0] = (uint64_t)orig_dyld_mmap;
    hookDebugState.__bcr[0] = 0x1e5;
    thread_set_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&hookDebugState, ARM_DEBUG_STATE64_COUNT);
    
    // fixup @loader_path since we cannot use musttail here
    void *result;
    void *callerAddr = __builtin_return_address(0);
    struct dl_info info;
    if (path && !strncmp(path, "@loader_path/", 13) && dladdr(callerAddr, &info)) {
        char resolvedPath[PATH_MAX];
        snprintf(resolvedPath, sizeof(resolvedPath), "%s/%s", dirname((char *)info.dli_fname), path + 13);
        result = orig_dlopen(resolvedPath, mode);
    } else {
        result = orig_dlopen(path, mode);
    }
    if (result) TDRefreshDyldImageRemap();
    // restore old thread states
    thread_set_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&origDebugState, ARM_DEBUG_STATE64_COUNT);
    thread_swap_exception_ports(thread, mask, handler, behavior, flavor, &mask, &masksCnt, &handler, &behavior, &flavor);
    
    return result;
}

void* jitless_hook_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
    void *map = __mmap(addr, len, prot, flags, fd, offset);
    // only handle mapping __TEXT segment from fd outside of permitted path
    if (map != MAP_FAILED || !(prot & PROT_EXEC) || fd < 0) return map;
    
    // to get around `file system sandbox blocked mmap()` we temporarily move it to permitted path
    char filePath[PATH_MAX];
    if (fcntl(fd, F_GETPATH, filePath) != 0) return map;
    char newTmpPath[PATH_MAX];
    sprintf(newTmpPath, "%s/Documents/.fd%d.dylib", getenv("LP_HOME_PATH"), fd);
    rename(filePath, newTmpPath);
    map = __mmap(addr, len, prot, flags, fd, offset);
    rename(newTmpPath, filePath);
    
    return map;
}

static void *machOChainedFixupsValidLinkedit;
static void *machoErrorCtor;

void bypass_seg_count_check(void (^block)(void)) {
    void *validLinkedit = findDyldSymbolWithCache(@"__ZNK6mach_o13ChainedFixups13validLinkeditEybNSt3__14spanIKNS_13MappedSegmentELm18446744073709551615EEEb", &machOChainedFixupsValidLinkedit);
    arm_debug_state64_t origValidLinkeditDebugState = {0};
    exception_mask_t validLinkeditMask = EXC_MASK_BREAKPOINT;
    mach_msg_type_number_t validLinkeditMasksCnt = 1;
    exception_handler_t validLinkeditHandler = excPort;
    exception_behavior_t validLinkeditBehavior = EXCEPTION_STATE | MACH_EXCEPTION_CODES;
    thread_state_flavor_t validLinkeditFlavor = ARM_THREAD_STATE64;
    mach_port_t thread = mach_thread_self();
    if(validLinkedit) {
        ensureBreakpointExceptionHandler();
        validLinkeditHandler = excPort;
        thread_get_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&origValidLinkeditDebugState, &(mach_msg_type_number_t){ARM_DEBUG_STATE64_COUNT});
        thread_swap_exception_ports(thread, validLinkeditMask, validLinkeditHandler, validLinkeditBehavior, validLinkeditFlavor, &validLinkeditMask, &validLinkeditMasksCnt, &validLinkeditHandler, &validLinkeditBehavior, &validLinkeditFlavor);
        assert(validLinkeditMasksCnt == 1);

        arm_debug_state64_t hookDebugState = origValidLinkeditDebugState;
        hookDebugState.__bvr[1] = (uint64_t)validLinkedit;
        hookDebugState.__bcr[1] = 0x1e5;
        thread_set_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&hookDebugState, ARM_DEBUG_STATE64_COUNT);
    }

    block();
    
    if(validLinkedit) {
        thread_set_state(thread, ARM_DEBUG_STATE64, (thread_state_t)&origValidLinkeditDebugState, ARM_DEBUG_STATE64_COUNT);
        thread_swap_exception_ports(thread, validLinkeditMask, validLinkeditHandler, validLinkeditBehavior, validLinkeditFlavor, &validLinkeditMask, &validLinkeditMasksCnt, &validLinkeditHandler, &validLinkeditBehavior, &validLinkeditFlavor);
    }
}

void bypass_os_variant_has_internal_content(void (^block)(void)) {
#if !TARGET_OS_SIMULATOR
    const char *libsystem_darwinPath = "/usr/lib/system/libsystem_darwin.dylib";
    mach_header_u *libsystem_darwinHeader = LCGetLoadedImageHeader(0, libsystem_darwinPath);
    NSString *internalRelTypeName = @"_internal_release_type";
    uint32_t *internalRelTypePtr = getCachedSymbol(internalRelTypeName, libsystem_darwinHeader);
    if (!internalRelTypePtr) {
        internalRelTypePtr = litehook_find_dsc_symbol(libsystem_darwinPath, internalRelTypeName.UTF8String);
        uint64_t offset = (uint64_t)((void*)internalRelTypePtr - (void*)libsystem_darwinHeader);
        saveCachedSymbol(internalRelTypeName, libsystem_darwinHeader, offset);
    }
    
    uint32_t orig = *internalRelTypePtr;
    *internalRelTypePtr = 3;
#endif
    
    // Bypass iOS 16's +[SpringBoardUI load] crash
    Class xctest = objc_allocateClassPair(NSObject.class, "XCTestConfiguration", 0);
    if (xctest) objc_registerClassPair(xctest);
    
    block();
    
    if (xctest) objc_disposeClassPair(xctest);
#if !TARGET_OS_SIMULATOR
    *internalRelTypePtr = orig;
#endif
}

kern_return_t catch_mach_exception_raise_state( mach_port_t exception_port, exception_type_t exception, const mach_exception_data_t code, mach_msg_type_number_t codeCnt, int *flavor, const thread_state_t old_state, mach_msg_type_number_t old_stateCnt, thread_state_t new_state, mach_msg_type_number_t *new_stateCnt) {
    arm_thread_state64_t *old = (arm_thread_state64_t *)old_state;
    arm_thread_state64_t *new = (arm_thread_state64_t *)new_state;
    uint64_t pc = arm_thread_state64_get_pc(*old);
    // TODO: merge with dyld bypass?
    if(pc == (uint64_t)orig_dyld_mmap) {
        *new = *old;
        *new_stateCnt = old_stateCnt;
        arm_thread_state64_set_pc_fptr(*new, jitless_hook_mmap);
        return KERN_SUCCESS;
    } else if (pc == (uint64_t)machOChainedFixupsValidLinkedit) {
        *new = *old;
        *new_stateCnt = old_stateCnt;
        static char emptyValidLinkeditBuffer[100] = "Create an issue on LiveContainer GitHub if you see this.";
        void (*ctor)(void* self, char* msg) = (void (*)(void*, char*))findDyldSymbolWithCache(@"__ZN6mach_o5ErrorC1EPKcz", &machoErrorCtor);
        ctor((void *)old->__x[8], emptyValidLinkeditBuffer);
        // not sure if this offset will change again
        *(uint8_t *)(((void *)old->__x[8]) + 0xa0) = 0;
        arm_thread_state64_set_pc_presigned_fptr(*new, arm_thread_state64_get_lr_fptr(*old) ?: (void *)arm_thread_state64_get_lr(*old));
        return KERN_SUCCESS;
    }
    NSLog(@"[DyldLVBypass] Unknown breakpoint at pc: %p", (void*)pc);
    return KERN_FAILURE;
}

kern_return_t catch_mach_exception_raise(mach_port_t exception_port, mach_port_t thread, mach_port_t task, exception_type_t exception, mach_exception_data_t code, mach_msg_type_number_t codeCnt) {
    abort();
}

kern_return_t catch_mach_exception_raise_state_identity(mach_port_t exception_port, mach_port_t thread, mach_port_t task, exception_type_t exception, mach_exception_data_t code, mach_msg_type_number_t codeCnt, int *flavor, thread_state_t old_state, mach_msg_type_number_t old_stateCnt, thread_state_t new_state, mach_msg_type_number_t *new_stateCnt) {
    abort();
}

// Masked image name for guests: one process-lifetime buffer, rewritten on
// demand. The bundle id comes from the guest's own identity, so the fake
// path reads as "<bundle-id>.app" exactly like a normal install.
const char *guestExecutableMaskedName(const char *realName) {
    static char masked[PATH_MAX];
    if (!realName || !realName[0]) return realName;
    NSString *guestId = NSUserDefaults.lcGuestAppId;
    if (!guestId.length) return realName;
    const char *lastSlash = strrchr(realName, '/');
    if (!lastSlash) return realName;
    snprintf(masked, sizeof(masked),
             "/var/containers/Bundle/Application/00000000-0000-0000-0000-000000000000/%s.app%s",
             guestId.UTF8String, lastSlash);
    return masked;
}
