#import "FoundationPrivate.h"
#import "LCMachOUtils.h"
#import "LCSharedUtils.h"
#import "LCZeusCertificate.h"
#import "UIKitPrivate.h"
#import "utils.h"

#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld_images.h>
#include <objc/runtime.h>

#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <sys/mman.h>
#include <stdlib.h>
#include "../litehook/src/litehook.h"
#import "Tweaks/Tweaks.h"
#import "../iManager/HideShim/TDConsoleLog.h"
#include <mach-o/ldsyms.h>
#include <CommonCrypto/CommonDigest.h>

extern void TDVRootInstallIfRequested(void);

#include <sys/stat.h>
#include <unistd.h>
#include <sys/syslimits.h>
#include <string.h>

// Host home captured before any guest can setenv("HOME"). Constructors of
// linked frameworks run before main(), so this value is the host container.
static char tdHostDocumentsBuf[PATH_MAX];
__attribute__((constructor)) static void tdCaptureHostHome(void) {
    const char *h = getenv("HOME");
    if (h && h[0] == '/') {
        strlcpy(tdHostDocumentsBuf, h, sizeof(tdHostDocumentsBuf));
        strlcat(tdHostDocumentsBuf, "/Documents", sizeof(tdHostDocumentsBuf));
    }
}
const char *TDHostHomeDocumentsPath(void) {
    if (tdHostDocumentsBuf[0] == 0) tdCaptureHostHome();
    return tdHostDocumentsBuf[0] ? tdHostDocumentsBuf : NULL;
}
NSString *TDHostHomeDocumentsDir(void) {
    const char *path = TDHostHomeDocumentsPath();
    return path ? [NSString stringWithUTF8String:path] : nil;
}

// 设备上 NSLog 不容易取到, 启动关键状态统一写进宿主 Documents/ConsoleLog.
static void TDAppendLaunchLog(NSString *line) {
    if (line.length == 0) return;
    TDConsoleLog(@"%@", line);
}

extern char **environ;
static int (*appMain)(int, char**, char**);
NSUserDefaults *lcUserDefaults;
NSUserDefaults *lcSharedDefaults;
NSString *lcAppGroupPath;
NSString* lcAppUrlScheme;
NSBundle* lcMainBundle;
NSDictionary* guestAppInfo;
NSDictionary* guestContainerInfo;
NSString* lcGuestAppId;
NSString* lcLaunchURL;
bool isLiveProcess = false;
bool isSharedBundle = false;
// iManager 实验性开关 (app group defaults): 关掉后所有访客都不做环境伪值.
static bool gTDEnvSpoofGlobal = true;

@implementation NSUserDefaults(LiveContainer)
+ (instancetype)lcUserDefaults {
    return lcUserDefaults;
}
+ (instancetype)lcSharedDefaults {
    if(!lcSharedDefaults) {
        lcSharedDefaults = [[NSUserDefaults alloc] initWithSuiteName: [LCSharedUtils appGroupID]];
    }
    return lcSharedDefaults;
}
+ (NSString *)lcAppGroupPath {
    return lcAppGroupPath;
}
+ (NSString *)lcAppUrlScheme {
    return lcAppUrlScheme;
}
+ (NSBundle *)lcMainBundle {
    return lcMainBundle;
}
+ (NSDictionary *)guestAppInfo {
    return guestAppInfo;
}

+ (NSDictionary *)guestContainerInfo {
    return guestContainerInfo;
}

+ (bool)isLiveProcess {
    return isLiveProcess;
}
+ (bool)isSharedApp {
    return isSharedBundle;
}

+ (NSString*)lcGuestAppId {
    return lcGuestAppId;
}
+ (NSString*)lcLaunchURL {
    return lcLaunchURL;
}
@end

static BOOL checkJITEnabled() {
#if TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR
    return YES;
#else
    if([lcUserDefaults boolForKey:@"LCIgnoreJITOnLaunch"]) {
        return NO;
    }
    // check if jailbroken
    if (access("/usr/lib/systemhook.dylib", R_OK) == 0) {
        return YES;
    }
    
    // check csflags
    int flags;
    csops(getpid(), 0, &flags, sizeof(flags));
    return (flags & CS_DEBUGGED) != 0;
#endif
}

static uint64_t rnd64(uint64_t v, uint64_t r) {
    r--;
    return (v + r) & ~r;
}

void overwriteMainCFBundle(void) {
    // Overwrite CFBundleGetMainBundle
    uint32_t *pc = (uint32_t *)CFBundleGetMainBundle;
    void **mainBundleAddr = 0;
    
#if !TARGET_OS_SIMULATOR
    if(@available(iOS 27.0, *)) {
        // at least in iOS 27.0 db1, the logic is inversed and the __mainBundle is right after the first tbz instruction
        while (true) {
            bool isTbz = ((*pc) & 0x7F000000) == 0x36000000;
            if (isTbz) {
                // adrp <- pc-1
                // tbz <- pc
                // ldr  <- addr
                mainBundleAddr = (void **)aarch64_emulate_adrp_ldr(*(pc-1), *(uint32_t *)(pc+1), (uint64_t)(pc-1));
                break;
            }
            ++pc;
        }
    } else {
#endif
        while (true) {
            uint64_t addr = aarch64_get_tbnz_jump_address(*pc, (uint64_t)pc);
            if (addr) {
                // adrp <- pc-1
                // tbnz <- pc
                // ...
                // ldr  <- addr
                mainBundleAddr = (void **)aarch64_emulate_adrp_ldr(*(pc-1), *(uint32_t *)addr, (uint64_t)(pc-1));
                break;
            }
            ++pc;
        }
#if !TARGET_OS_SIMULATOR
    }
#endif
    assert(mainBundleAddr != NULL);
    *mainBundleAddr = (__bridge void *)NSBundle.mainBundle._cfBundle;
}

void overwriteMainNSBundle(NSBundle *newBundle) {
    // Overwrite NSBundle.mainBundle
    // iOS 16: x19 is _MergedGlobals
    // iOS 17: x19 is _MergedGlobals+4

    NSString *oldPath = NSBundle.mainBundle.executablePath;
    uint32_t *mainBundleImpl = (uint32_t *)method_getImplementation(class_getClassMethod(NSBundle.class, @selector(mainBundle)));
    for (int i = 0; i < 20; i++) {
        void **_MergedGlobals = (void **)aarch64_emulate_adrp_add(mainBundleImpl[i], mainBundleImpl[i+1], (uint64_t)&mainBundleImpl[i]);
        if (!_MergedGlobals) continue;

        // In iOS 17, adrp+add gives _MergedGlobals+4, so it uses ldur instruction instead of ldr
        if ((mainBundleImpl[i+4] & 0xFF000000) == 0xF8000000) {
            uint64_t ptr = (uint64_t)_MergedGlobals - 4;
            _MergedGlobals = (void **)ptr;
        }

        for (int mgIdx = 0; mgIdx < 20; mgIdx++) {
            if (_MergedGlobals[mgIdx] == (__bridge void *)NSBundle.mainBundle) {
                _MergedGlobals[mgIdx] = (__bridge void *)newBundle;
                break;
            }
        }
    }

    assert(![NSBundle.mainBundle.executablePath isEqualToString:oldPath]);
}

typedef struct {
    void *gap_0x0[2];                  // 0x00, 0x08
    char *mainExecutablePath_old;      // 0x10
    void *gap_0x18;                    // 0x18
    char *mainExecutablePath_18_4;     // 0x20
    size_t mainExecutablePathLen_27_0; // 0x28
} DyldConfig;
typedef struct {
    void *gap_0x0;
    DyldConfig *dyldConfig;
} DyldAPI;

int hook__NSGetExecutablePath_overwriteExecPath(DyldAPI* dyldApiInstancePtr, char* newPath, uint32_t* bufsize) {
    assert(dyldApiInstancePtr != 0);
    DyldConfig* dyldConfig = dyldApiInstancePtr->dyldConfig;
    assert(dyldConfig != 0);
    
    char** mainExecutablePathPtr = 0;
    // mainExecutablePath is at 0x10 for iOS 15~18.3.2, 0x20 for iOS 18.4+
    if(dyldConfig->mainExecutablePath_old != 0 && dyldConfig->mainExecutablePath_old[0] == '/') {
        mainExecutablePathPtr = &(dyldConfig->mainExecutablePath_old);
    } else if (dyldConfig->mainExecutablePath_18_4 != 0 && dyldConfig->mainExecutablePath_18_4[0] == '/') {
        mainExecutablePathPtr = &(dyldConfig->mainExecutablePath_18_4);
    } else {
        assert(mainExecutablePathPtr != 0);
    }

    kern_return_t ret = builtin_vm_protect(mach_task_self(), (mach_vm_address_t)dyldConfig, sizeof(dyldConfig), false, PROT_READ | PROT_WRITE);
    if(ret != KERN_SUCCESS) {
        assert(os_tpro_is_supported());
        os_thread_self_restrict_tpro_to_rw();
    }
    *mainExecutablePathPtr = newPath;
    
    // in iOS 27, the length is also cached, it's at +0x28
    if(@available(iOS 27.0, *)) {
        dyldConfig->mainExecutablePathLen_27_0 = strlen(newPath);
    }
    
    if(ret != KERN_SUCCESS) {
        os_thread_self_restrict_tpro_to_ro();
    }

    return 0;
}

void overwriteExecPath(const char *newExecPath) {
    // dyld4 stores executable path in a different place (iOS 15.0 +)
    // https://github.com/apple-oss-distributions/dyld/blob/ce1cc2088ef390df1c48a1648075bbd51c5bbc6a/dyld/DyldAPIs.cpp#L802
    int (*orig__NSGetExecutablePath)(void* dyldPtr, char* buf, uint32_t* bufsize);
    performHookDyldApi("_NSGetExecutablePath", 2, (void**)&orig__NSGetExecutablePath, hook__NSGetExecutablePath_overwriteExecPath);
    _NSGetExecutablePath((char*)newExecPath, NULL);
    // put the original function back
    performHookDyldApi("_NSGetExecutablePath", 2, (void**)&orig__NSGetExecutablePath, orig__NSGetExecutablePath);
}

static void *getAppEntryPoint(void *handle) {
    uint32_t entryoff = 0;
    const struct mach_header_64 *header = (struct mach_header_64 *)getGuestAppHeader();
    uint8_t *imageHeaderPtr = (uint8_t*)header + sizeof(struct mach_header_64);
    struct load_command *command = (struct load_command *)imageHeaderPtr;
    for(int i = 0; i < header->ncmds; ++i) {
        if(command->cmd == LC_MAIN) {
            struct entry_point_command ucmd = *(struct entry_point_command *)imageHeaderPtr;
            entryoff = ucmd.entryoff;
            break;
        }
        imageHeaderPtr += command->cmdsize;
        command = (struct load_command *)imageHeaderPtr;
    }
    assert(entryoff > 0);
    return (void *)header + entryoff;
}


static NSString *LCDataSHA256Hex(NSData *data) {
    if (!data) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSString *LCExecutableTextSectionSHA256(NSString *path) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    __block NSString *hash = nil;
    LCParseMachO(path.UTF8String, true, ^(const char *slicePath, struct mach_header_64 *header, int fd, void *filePtr) {
        if (!header || header->magic != MH_MAGIC_64) return;
        struct stat st = {0};
        if (fstat(fd, &st) != 0) return;
        uint64_t sliceOffset = (uint8_t *)header - (uint8_t *)filePtr;
        uint8_t *cursor = (uint8_t *)header + sizeof(struct mach_header_64);
        for (uint32_t i = 0; i < header->ncmds; i++) {
            struct load_command lc = {0};
            if ((uint8_t *)cursor + sizeof(lc) > (uint8_t *)filePtr + st.st_size) return;
            memcpy(&lc, cursor, sizeof(lc));
            if (lc.cmdsize < sizeof(lc)) return;
            if (lc.cmd == LC_SEGMENT_64 && lc.cmdsize >= sizeof(struct segment_command_64)) {
                struct segment_command_64 seg = {0};
                memcpy(&seg, cursor, sizeof(seg));
                if (strncmp(seg.segname, "__TEXT", sizeof(seg.segname)) == 0) {
                    uint8_t *sectCursor = cursor + sizeof(struct segment_command_64);
                    for (uint32_t j = 0; j < seg.nsects; j++) {
                        struct section_64 sect = {0};
                        memcpy(&sect, sectCursor, sizeof(sect));
                        uint64_t fileOffset = sliceOffset + sect.offset;
                        if (strncmp(sect.sectname, "__text", sizeof(sect.sectname)) == 0 &&
                            sect.size > 0 && fileOffset + sect.size <= (uint64_t)st.st_size) {
                            NSData *text = [NSData dataWithBytes:(uint8_t *)filePtr + fileOffset length:(NSUInteger)sect.size];
                            hash = LCDataSHA256Hex(text);
                            return;
                        }
                        sectCursor += sizeof(struct section_64);
                    }
                }
            }
            cursor += lc.cmdsize;
        }
    });
    return hash;
}

static NSArray *LCCollectExecutableEntitlementKeys(NSString *path) {
    if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    NSString *entitlementsXML = getExecutableEntitlementXML(path);
    if (![entitlementsXML isKindOfClass:NSString.class] || entitlementsXML.length <= 0) return nil;
    NSDictionary *entitlements = [NSPropertyListSerialization propertyListWithData:[entitlementsXML dataUsingEncoding:NSUTF8StringEncoding]
                                                                                options:0 format:NULL error:nil];
    if (![entitlements isKindOfClass:NSDictionary.class] || entitlements.count <= 0) return nil;
    return entitlements.allKeys;
}

static void LCAdaptSecurityPresets(NSString *bundlePath, NSString *guestId, NSString *execName) {
    if (!bundlePath || !execName) return;
    NSString *path = [bundlePath stringByAppendingPathComponent:@"SecurityPresets.plist"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
    NSMutableDictionary *presets = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!presets) return;
    BOOL changed = NO;

    if (guestId.length > 0) {
        presets[@"secureMainBundleIdentifiers"] = @[guestId];
        changed = YES;
    }

    NSString *profileBackup = [bundlePath stringByAppendingPathComponent:@".td-original.mobileprovision"];
    NSString *profileCurrent = [bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:profileBackup] && [fm fileExistsAtPath:profileCurrent]) {
        [fm copyItemAtPath:profileCurrent toPath:profileBackup error:nil];
    }
    if (![fm fileExistsAtPath:profileCurrent] && [fm fileExistsAtPath:profileBackup]) {
        [fm copyItemAtPath:profileBackup toPath:profileCurrent error:nil];
    }
    if (![fm fileExistsAtPath:profileCurrent] && ![fm fileExistsAtPath:profileBackup]) {
        [[NSData data] writeToFile:profileCurrent atomically:YES];
        [[NSData data] writeToFile:profileBackup atomically:YES];
    }
    // The shipped baseline for secureMobileProvisioningProfileHashes is an
    // empty string: detectors treat an empty baseline as "no expectation,
    // trust the profile". 1.1.53 builds rewrote this key to a file hash and
    // the value persisted inside SecurityPresets.plist across updates, so
    // every 1.1.54 launch still saw the stale expectation and Reveil kept
    // reporting "profile tampered" even though this function no longer
    // writes it (user-visible red persisted in both fullscreen and
    // multitask). Reset the key to the shipped [""] baseline here so any
    // dirty value from an older build is cleaned on next launch, then leave
    // it alone — matching upstream LiveContainer, which never modifies it.
    if (presets[@"secureMobileProvisioningProfileHashes"] == nil ||
        ![presets[@"secureMobileProvisioningProfileHashes"] isEqual:@[@""]]) {
        presets[@"secureMobileProvisioningProfileHashes"] = @[@""];
        changed = YES;
    }
    NSString *currentExec = [bundlePath stringByAppendingPathComponent:execName];
    NSString *execHash = LCExecutableTextSectionSHA256(currentExec);
    if (execHash) {
        presets[@"secureMainExecutableMachOHashes"] = @[execHash];
        changed = YES;
    }

    // 基线必须覆盖“已有允许项 + 原包 entitlements + 当前包 entitlements”，
    // 因为 Reveil 用当前可执行路径读取值集合；只写原包会漏掉迁移中新增的键。
    // `presets[@"secureEntitlementKeys"]` 可能是 NSArray/字符串/空值；不能直接
    // 交给 setWithSet，否则会抛 "set argument is not an NSSet"。
    NSMutableSet *entitlementKeys = [NSMutableSet set];
    id existingKeys = presets[@"secureEntitlementKeys"];
    if ([existingKeys isKindOfClass:NSArray.class] || [existingKeys isKindOfClass:NSSet.class]) {
        for (id key in existingKeys) {
            if ([key isKindOfClass:NSString.class]) [entitlementKeys addObject:key];
        }
    }
    NSArray *currentEntitlementKeys = LCCollectExecutableEntitlementKeys(currentExec);
    if (currentEntitlementKeys) {
        [entitlementKeys addObjectsFromArray:currentEntitlementKeys];
    }
    if (entitlementKeys.count > 0) {
        presets[@"secureEntitlementKeys"] = [entitlementKeys.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [a compare:b options:NSNumericSearch];
        }];
        changed = YES;
    }

    if (changed) {
        [presets writeToFile:path atomically:YES];
        NSLog(@"[LC] adapted SecurityPresets baseline guest=%@ exec=%@", guestId, execHash);
    }
}
static void LCEnsureOriginalInfoPlistBackup(NSString* bundlePath,
                                            NSString* knownGuestId) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* plistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSString* backupPath = [bundlePath stringByAppendingPathComponent:@".td-original.Info.plist"];
    if (![fm fileExistsAtPath:backupPath]) {
        if (![fm fileExistsAtPath:plistPath]) {
            return;
        }
        [fm copyItemAtPath:plistPath toPath:backupPath error:nil];
    }
    NSString* hostBundleId = NSBundle.mainBundle.bundleIdentifier;
    if (![knownGuestId isKindOfClass:NSString.class] || knownGuestId.length == 0 ||
        [knownGuestId isEqualToString:hostBundleId]) {
        return;
    }
    NSMutableDictionary* dict = [[NSMutableDictionary alloc] initWithContentsOfFile:backupPath];
    NSString* backupBundleId = [dict[@"CFBundleIdentifier"] isKindOfClass:NSString.class]
        ? dict[@"CFBundleIdentifier"] : nil;
    if (dict && [backupBundleId isEqualToString:hostBundleId]) {
        dict[@"CFBundleIdentifier"] = knownGuestId;
        [dict writeBinToFile:backupPath atomically:YES];
    }
}

static NSString* invokeAppMain(NSString *selectedApp, NSString *selectedContainer, int argc, char *argv[]) {
    NSString *appError = nil;
    if([[lcUserDefaults objectForKey:@"LCWaitForDebugger"] boolValue]) {
        sleep(100);
    }
    if (!LCSharedUtils.certificatePassword) {
#if !TARGET_OS_SIMULATOR
        if(@available(iOS 26.0 ,*))  {
            return @"JIT-less mode is required since iOS 26, and it needs the certificate that signed this app. Install this app with Zeus and let it use Zeus's certificate, or import a certificate in Settings.";
        }
#endif
        // First of all, let's check if we have JIT
        for (int i = 0; i < 10 && !checkJITEnabled(); i++) {
            usleep(1000*100);
        }
        if (!checkJITEnabled()) {
            appError = @"JIT was not enabled. If you want to use zContainer without JIT, setup JITLess mode in settings.";
            return appError;
        }
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docPath = [NSString stringWithFormat:@"%s/Documents", getenv("LC_HOME_PATH")];
    
    NSURL *appGroupFolder = nil;
    
    NSString *bundlePath = [NSString stringWithFormat:@"%@/Applications/%@", docPath, selectedApp];

    guestAppInfo = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/LCAppInfo.plist", bundlePath]];

    // not found locally, let's look for the app in shared folder
    if(!guestAppInfo) {
        NSURL *appGroupPath = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[LCSharedUtils appGroupID]];
        appGroupFolder = [appGroupPath URLByAppendingPathComponent:@"LiveContainer"];
        bundlePath = [NSString stringWithFormat:@"%@/Applications/%@", appGroupFolder.path, selectedApp];
        guestAppInfo = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/LCAppInfo.plist", bundlePath]];
        isSharedBundle = true;
    }
    
    if(!guestAppInfo) {
        return @"App bundle not found! Unable to read LCAppInfo.plist.";
    }
    
    if([guestAppInfo[@"doUseLCBundleId"] boolValue] ) {
        NSMutableDictionary* infoPlist = [NSMutableDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Info.plist", bundlePath]];
        LCEnsureOriginalInfoPlistBackup(bundlePath, infoPlist[@"CFBundleIdentifier"]);
        CFErrorRef error = NULL;
        void* taskSelf = SecTaskCreateFromSelf(NULL);
        CFTypeRef value = taskSelf ? SecTaskCopyValueForEntitlement(taskSelf, CFSTR("application-identifier"), &error) : NULL;
        if (taskSelf) CFRelease(taskSelf);
        if (error) CFRelease(error);
        if (value && CFGetTypeID(value) != CFStringGetTypeID()) {
            CFRelease(value);
            value = NULL;
        }
        if (value) {
            NSString *entStr = (__bridge_transfer NSString *)value;
            NSRange dotRange = [entStr rangeOfString:@"."];
            if (dotRange.location != NSNotFound) {
                NSString *expectedBundleId = [entStr substringFromIndex:dotRange.location + 1];
                if(![infoPlist[@"CFBundleIdentifier"] isEqualToString:expectedBundleId]) {
                    infoPlist[@"CFBundleIdentifier"] = expectedBundleId;
                    [infoPlist writeBinToFile:[NSString stringWithFormat:@"%@/Info.plist", bundlePath] atomically:YES];
                }
            }
        }
    }
    
    NSBundle *appBundle = [[NSBundle alloc] initWithPathForMainBundle:bundlePath];
    
    if(!appBundle) {
        return @"App not found";
    }
    
    // find container in Info.plist
    NSString* dataUUID = selectedContainer;
    if(!dataUUID) {
        dataUUID = guestAppInfo[@"LCDataUUID"];
    }

    if(dataUUID == nil) {
        return @"Container not found!";
    }
    
    if(isLiveProcess) {
        lcAppUrlScheme = [lcUserDefaults stringForKey:@"hostUrlScheme"];
        [lcUserDefaults removeObjectForKey:@"hostUrlScheme"];
    }
    
    NSError *error;

    // Setup tweak loader
    NSString *tweakFolder = nil;
    if (isSharedBundle) {
        tweakFolder = [appGroupFolder.path  stringByAppendingPathComponent:@"Tweaks"];
    } else {
        tweakFolder = [docPath stringByAppendingPathComponent:@"Tweaks"];
    }
    setenv("LC_GLOBAL_TWEAKS_FOLDER", tweakFolder.UTF8String, 1);

    // Update TweakLoader symlink. Older releases could leave either a regular
    // stale dylib or an absolute symlink pointing at a removed container path.
    NSString *tweakLoaderPath = [tweakFolder stringByAppendingPathComponent:@"TweakLoader.dylib"];
    NSString *liveContainerBundlePath = NSBundle.mainBundle.bundlePath;
    if ([liveContainerBundlePath hasSuffix:@"/PlugIns/LiveProcess.appex"]) {
        // traverse back to LiveContainer.app
        liveContainerBundlePath = liveContainerBundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    }
    NSString *tweakLoaderTarget = [liveContainerBundlePath stringByAppendingPathComponent:@"Frameworks/TweakLoader.dylib"];
    char currentTarget[PATH_MAX] = {};
    ssize_t currentTargetLength = readlink(tweakLoaderPath.UTF8String, currentTarget, sizeof(currentTarget) - 1);
    BOOL tweakLoaderCurrent = currentTargetLength > 0 &&
                              strcmp(currentTarget, tweakLoaderTarget.UTF8String) == 0;
    if (!tweakLoaderCurrent) {
        remove(tweakLoaderPath.UTF8String);
        if (symlink(tweakLoaderTarget.UTF8String, tweakLoaderPath.UTF8String) != 0) {
            NSData *currentTweakLoader = [NSData dataWithContentsOfFile:tweakLoaderTarget];
            if (currentTweakLoader) {
                [currentTweakLoader writeToFile:tweakLoaderPath atomically:YES];
            }
        }
    }

    // If JIT is enabled, bypass library validation so we can load arbitrary binaries
    bool isJitEnabled = checkJITEnabled();
    if (isJitEnabled) {
        init_bypassDyldLibValidation();
    }

    // The executable path is used right below, so check it first
    if(!appBundle.executablePath) {
        return @"App's executable path not found. Please try force re-signing or reinstalling this app.";
    }

    // Locate dyld image name address
    const char **path = _CFGetProcessPath();
    const char *oldPath = *path;
    
    // Overwrite @executable_path
    const char *appExecPath = appBundle.executablePath.fileSystemRepresentation;
    *path = appExecPath;
    overwriteExecPath(appExecPath);
    
    // Overwrite NSUserDefaults
    NSString *recordedGuestId = guestAppInfo[@"LCOrignalBundleIdentifier"];
    if (![recordedGuestId isKindOfClass:NSString.class] || recordedGuestId.length == 0) {
        recordedGuestId = guestAppInfo[@"TDOriginalBundleIdentifier"];
    }
    if ([recordedGuestId isKindOfClass:NSString.class] && recordedGuestId.length > 0) {
        lcGuestAppId = recordedGuestId;
    } else if ([guestAppInfo[@"doUseLCBundleId"] boolValue]) {
        lcGuestAppId = appBundle.bundleIdentifier;
    } else {
        lcGuestAppId = appBundle.bundleIdentifier;
    }
    LCAdaptSecurityPresets(bundlePath, lcGuestAppId, appBundle.executablePath.lastPathComponent);
    NSBundleGuestHooksInit();

    // Overwrite home and tmp path
    NSString *newHomePath = nil;
    NSArray<NSDictionary*>* containers = guestAppInfo[@"LCContainers"];
    NSURL* bookmarkURL = nil;

    // see if the container contains a bookmark. if so, resolve it and report error upon failure.
    if(containers && [containers isKindOfClass:NSArray.class]) {
        for(NSDictionary* container in containers){
            if(![container isKindOfClass:NSDictionary.class]) {
                continue;
            }
            if([container[@"folderName"] isEqualToString:dataUUID]) {
                NSData* bookmarkData = container[@"bookmarkData"];
                if(bookmarkData && [bookmarkData isKindOfClass:NSData.class]) {
                    // we will be killed by watchdog before timedout, so we set this error beforehand.
                    [lcUserDefaults setObject:@"Bookmark resolution timed out. Is the data storage offline?" forKey:@"error"];
                    NSError* err = nil;
                    BOOL isStale = false;
                    bookmarkURL = [NSURL URLByResolvingBookmarkData:bookmarkData options:0 relativeToURL:nil bookmarkDataIsStale:&isStale error:&err];
                    bool access = [bookmarkURL startAccessingSecurityScopedResource];
                    if(!bookmarkURL || !access) {
                        NSString* reason = err.localizedDescription;
                        NSString* message = @"Bookmark resolution failed or unable to access the container. You might need to readd the data storage.";
                        return reason ? [NSString stringWithFormat:@"%@ %@", message, reason] : message;
                    }
                    [lcUserDefaults removeObjectForKey:@"error"];
                }
                break;
            }
        }
    }
    
    if (bookmarkURL) {
        newHomePath = bookmarkURL.path;
    } else if(isSharedBundle) {
        newHomePath = [NSString stringWithFormat:@"%@/Data/Application/%@", appGroupFolder.path, dataUUID];
        
    } else {
        newHomePath = [NSString stringWithFormat:@"%@/Data/Application/%@", docPath, dataUUID];
    }
    
    
    NSString *newTmpPath = [newHomePath stringByAppendingPathComponent:@"tmp"];
    remove(newTmpPath.UTF8String);
    symlink(getenv("TMPDIR"), newTmpPath.UTF8String);
    
    if([guestAppInfo[@"doSymlinkInbox"] boolValue]) {
        NSString* inboxSymlinkPath = [NSString stringWithFormat:@"%s/%@-Inbox", getenv("TMPDIR"), [appBundle bundleIdentifier]];
        NSString* inboxPath = [newHomePath stringByAppendingPathComponent:@"Inbox"];
        
        if (![fm fileExistsAtPath:inboxPath]) {
            [fm createDirectoryAtPath:inboxPath withIntermediateDirectories:YES attributes:nil error:&error];
        }
        if([fm fileExistsAtPath:inboxSymlinkPath]) {
            NSString* fileType = [fm attributesOfItemAtPath:inboxSymlinkPath error:&error][NSFileType];
            if(fileType == NSFileTypeDirectory) {
                NSArray* contents = [fm contentsOfDirectoryAtPath:inboxSymlinkPath error:&error];
                for(NSString* content in contents) {
                    [fm moveItemAtPath:[inboxSymlinkPath stringByAppendingPathComponent:content] toPath:[inboxPath stringByAppendingPathComponent:content] error:&error];
                }
                [fm removeItemAtPath:inboxSymlinkPath error:&error];
            }
        }
        

        symlink(inboxPath.UTF8String, inboxSymlinkPath.UTF8String);
    } else {
        NSString* inboxSymlinkPath = [NSString stringWithFormat:@"%s/%@-Inbox", getenv("TMPDIR"), [appBundle bundleIdentifier]];
        NSDictionary* targetAttribute = [fm attributesOfItemAtPath:inboxSymlinkPath error:&error];
        if(targetAttribute) {
            if(targetAttribute[NSFileType] == NSFileTypeSymbolicLink) {
                [fm removeItemAtPath:inboxSymlinkPath error:&error];
            }
        }

    }
    
    setenv("CFFIXED_USER_HOME", newHomePath.UTF8String, 1);
    setenv("HOME", newHomePath.UTF8String, 1);
    // we don't change TMP's env in case some apps clear cache by directly deleting the tmp folder,
    // which if symlinked, the new tmp cannot be recreated (#1040, #1125) or the app may camplain about the tmp folder being a symlimk (#884)

    // Setup directories
    NSArray *dirList = @[@"Library/Caches", @"Library/Cookies", @"Documents", @"SystemData"];
    for (NSString *dir in dirList) {
        NSString *dirPath = [newHomePath stringByAppendingPathComponent:dir];
        [fm createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    NSString* containerInfoPath = [newHomePath stringByAppendingPathComponent:@"LCContainerInfo.plist"];
    guestContainerInfo = [NSDictionary dictionaryWithContentsOfFile:containerInfoPath];
    
    [LCSharedUtils setContainerUsingByLC:lcAppUrlScheme folderName:dataUUID auditToken:0];

    // Overwrite NSBundle
    overwriteMainNSBundle(appBundle);

    // Overwrite CFBundle
    overwriteMainCFBundle();

    // Overwrite executable info
    NSMutableArray<NSString *> *objcArgv = NSProcessInfo.processInfo.arguments.mutableCopy;
    objcArgv[0] = appBundle.executablePath;
    [NSProcessInfo.processInfo performSelector:@selector(setArguments:) withObject:objcArgv];
    NSProcessInfo.processInfo.processName = appBundle.infoDictionary[@"CFBundleExecutable"];
    *_CFGetProgname() = NSProcessInfo.processInfo.processName.UTF8String;
    Class swiftNSProcessInfo = NSClassFromString(@"_NSSwiftProcessInfo");
    if(swiftNSProcessInfo) {
        // Swizzle the arguments method to return the ObjC arguments
        SEL selector = @selector(arguments);
        method_setImplementation(class_getInstanceMethod(swiftNSProcessInfo, selector), class_getMethodImplementation(NSProcessInfo.class, selector));
    }
    
    // Read the host-container flag before guest defaults and HOME are installed.
    NSString *tdHostDocuments = TDHostHomeDocumentsDir();
    NSString *tdFlagPath = tdHostDocuments ? [tdHostDocuments stringByAppendingPathComponent:@"TDGlobalHide"] : nil;
    NSString *tdGlobalValue = tdFlagPath ? [NSString stringWithContentsOfFile:tdFlagPath encoding:NSUTF8StringEncoding error:nil] : nil;
    BOOL tdFileGlobalHide = [tdGlobalValue isEqualToString:@"1"];
    BOOL tdPayloadGlobalHide = getenv("TD_GLOBAL_HIDE") && getenv("TD_GLOBAL_HIDE")[0] == '1';
    BOOL tdGlobalHide = tdFileGlobalHide || tdPayloadGlobalHide;
    BOOL tdPerAppHide = [guestAppInfo[@"hideLiveContainer"] boolValue];
    BOOL tdHideLiveContainer = tdGlobalHide || tdPerAppHide;
    NSLog(@"[TDGlobalHide] path=%@ value=%@ payload=%d guest=%d global=%d hide=%d pre-NUD", tdFlagPath,
          tdGlobalValue ?: @"<missing>", (int)tdPayloadGlobalHide, (int)tdPerAppHide,
          (int)tdGlobalHide, (int)tdHideLiveContainer);

    // Preserve the pre-experimental Home button behavior for "keep current":
    // Appearance's global switch plus the app's own per-app switch.
    BOOL tdShowHomeButton = [lcUserDefaults boolForKey:@"LCShowHomeButtonInApps"] &&
                            ![guestAppInfo[@"hideHomeButton"] boolValue];
    setenv("TD_SHOW_HOME_BUTTON_IN_APPS", tdShowHomeButton ? "1" : "0", 1);

    // hook NSUserDefault before running libraries' initializers
    NUDGuestHooksInit();
    SecItemGuestHooksInit();
    NSFMGuestHooksInit();
    initDead10ccFix();
    if(isLiveProcess) {
        NSURLSCGuestHooksInit();
    }
    // ignore setting handler from guest app
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, NSSetUncaughtExceptionHandler, hook_do_nothing, nil);
    
    BOOL hookDlopen = !isSharedBundle && LCSharedUtils.certificatePassword && isLiveProcess;
    // 环境门控默认开启: 用户关掉"隐藏"只是不希望裁剪 dyld 清单, 不应连带
    // 把 sysctl/SecTask/csops/proc 的伪值也关掉. per-app 显式配置优先.
    id tdSysctlValue = guestAppInfo[@"sysctlSpoof"];
    id tdSecTaskValue = guestAppInfo[@"secTaskSpoof"];
    id tdCsopsValue = guestAppInfo[@"csopsSpoof"];
    id tdProcValue = guestAppInfo[@"procSpoof"];
    BOOL tdSysctlSpoof = gTDEnvSpoofGlobal && (tdGlobalHide || (tdSysctlValue ? [tdSysctlValue boolValue] : YES));
    BOOL tdSecTaskSpoof = gTDEnvSpoofGlobal && (tdGlobalHide || (tdSecTaskValue ? [tdSecTaskValue boolValue] : YES));
    BOOL tdCsopsSpoof = gTDEnvSpoofGlobal && (tdGlobalHide || (tdCsopsValue ? [tdCsopsValue boolValue] : YES));
    BOOL tdProcSpoof = gTDEnvSpoofGlobal && (tdGlobalHide || (tdProcValue ? [tdProcValue boolValue] : YES));
    // This process hosts multiple guests; every launch must replace the previous
    // guest's gates instead of inheriting them from the resident process.
    setenv("TD_SYSCTL_SPOOF", tdSysctlSpoof ? "1" : "0", 1);
    setenv("TD_SECTASK_SPOOF", tdSecTaskSpoof ? "1" : "0", 1);
    setenv("TD_CSOPS_SPOOF", tdCsopsSpoof ? "1" : "0", 1);
    setenv("TD_PROC_SPOOF", tdProcSpoof ? "1" : "0", 1);
    if (![guestAppInfo[@"csopsKeepDebugged"] boolValue] || tdGlobalHide) {
        setenv("TD_CSOPS_KEEP_DEBUGGED", "0", 1);
    } else {
        setenv("TD_CSOPS_KEEP_DEBUGGED", "1", 1);
    }
    TDVRootInstallIfRequested();
    NSLog(@"[TDGlobalHide] gates hide=%d sysctl=%d sectask=%d csops=%d proc=%d", (int)tdHideLiveContainer,
          (int)tdSysctlSpoof, (int)tdSecTaskSpoof, (int)tdCsopsSpoof, (int)tdProcSpoof);
    TDAppendLaunchLog([NSString stringWithFormat:@"launch app=%@ hide=%d global=%d gates=%d%d%d%d",
                       selectedApp, (int)tdHideLiveContainer, (int)tdGlobalHide,
                       (int)tdSysctlSpoof, (int)tdSecTaskSpoof, (int)tdCsopsSpoof, (int)tdProcSpoof]);
    DyldHooksInit(tdHideLiveContainer, hookDlopen, [guestAppInfo[@"spoofSDKVersion"] unsignedIntValue]);
    
    if([guestContainerInfo[@"spoofIdentifierForVendor"] boolValue]) {
        NSString* idForVendorStr = guestContainerInfo[@"spoofedIdentifierForVendor"];
        if([idForVendorStr isKindOfClass:NSString.class]) {
            NSUUID* idForVendorUUID = [[NSUUID UUID] initWithUUIDString:idForVendorStr];
            if(idForVendorUUID) {
                IDFVHookInit(idForVendorUUID);
            }
        }
    }
    
    bool is32bit = [guestAppInfo[@"is32bit"] boolValue];
    if(is32bit) {
        [lcUserDefaults removeObjectForKey:@"LC32BitTranslationLayerLogFile"];
        if (!isJitEnabled) {
            return @"JIT is required to run 32-bit apps.";
        }
        
        NSString *selected32BitLayer = guestAppInfo[@"selected32BitEmulator"] ?: [lcSharedDefaults stringForKey:@"LCSelected32BitEmulator"];
        if(selected32BitLayer.length == 0) {
            appError = @"No 32-bit emulator selected";
            NSLog(@"[LCBootstrap] %@", appError);
            *path = oldPath;
            return appError;
        }
        NSBundle *selected32bitLayerBundle = [NSBundle bundleWithPath:[NSString stringWithFormat:@"%@/Applications/%@", docPath, selected32BitLayer]];
        if(!selected32bitLayerBundle && LCSharedUtils.appGroupPath) {
            selected32bitLayerBundle = [NSBundle bundleWithPath:[NSString stringWithFormat:@"%@/LiveContainer/Applications/%@", LCSharedUtils.appGroupPath.path, selected32BitLayer]];
        }
        if(!selected32bitLayerBundle) {
            appError = @"The specified 32-bit emulator app is not found";
            NSLog(@"[LCBootstrap] %@", appError);
            *path = oldPath;
            return appError;
        }
        // maybe need to save selected32bitLayerBundle to static variable?
        appExecPath = strdup(selected32bitLayerBundle.executablePath.UTF8String);
        overwriteExecPath(appExecPath);
    }
    if(![guestAppInfo[@"dontInjectTweakLoader"] boolValue]) {
        tweakLoaderLoaded = true;
    }
    
    // Preload executable to bypass RT_NOLOAD
    // 必须是真实镜像索引: 隐藏开启后 _dyld_image_count 已被重绑成可见数量,
    // 用它记录 dlopen 前位置会让 appMainImageIndex 偏移, 访客入口取错后立即终止.
    appMainImageIndex = LCRealImageCount();
    __block void *appHandle = 0;
    void (^dlopenBlock)(void) = ^{
        appHandle = dlopen_nolock(appExecPath, RTLD_LAZY|RTLD_GLOBAL|RTLD_FIRST);
    };
    TDAppendLaunchLog([NSString stringWithFormat:@"dlopen start path=%s", appExecPath]);
    
    BOOL is27up = false;
    if(@available(iOS 27, *)) { is27up = true; }
    if(is27up && [guestAppInfo[@"segCountMismatch"] boolValue]) {
        bypass_seg_count_check(dlopenBlock);
    } else {
        dlopenBlock();
    }

    appExecutableHandle = appHandle;
    const char *dlerr = dlerror();
    
    if (!appHandle || (uint64_t)appHandle > 0xf00000000000) {
        if (dlerr) {
            appError = @(dlerr);
        } else {
            appError = @"dlopen: an unknown error occurred";
        }
        NSLog(@"[LCBootstrap] %@", appError);
        TDAppendLaunchLog([NSString stringWithFormat:@"dlopen failed: %@", appError]);
        *path = oldPath;
        return appError;
    }

    // 现在访客确实在了镜像表里; 用路径比对拿到真实索引, 不再依赖"dlopen 前数量".
    uint32_t resolvedGuestIndex = LCGuestImageIndexForPath(appExecPath);
    if (resolvedGuestIndex != UINT32_MAX) {
        appMainImageIndex = resolvedGuestIndex;
    }
    LCRebuildImageRemap();
    NSLog(@"[LCBootstrap] guest image index=%u total=%u", appMainImageIndex, LCRealImageCount());
    TDAppendLaunchLog([NSString stringWithFormat:@"guest index=%u total=%u path=%s",
                       appMainImageIndex, LCRealImageCount(), appExecPath]);
    
    if (![guestAppInfo[@"dontLoadTweakLoader"] boolValue]) {
        NSString *hostBundlePath = lcMainBundle.bundlePath;
        if ([hostBundlePath hasSuffix:@"/PlugIns/LiveProcess.appex"]) {
            hostBundlePath = hostBundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
        }
        NSString *tweakLoaderPath = [hostBundlePath stringByAppendingPathComponent:@"Frameworks/TweakLoader.dylib"];
        void *handle = dlopen(tweakLoaderPath.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
        if (handle) {
            tweakLoaderLoaded = true;
            TDAppendLaunchLog([NSString stringWithFormat:@"tweakloader fallback ok path=%@",
                               tweakLoaderPath]);
        } else {
            const char *loaderError = dlerror();
            NSLog(@"[LCBootstrap] failed to load TweakLoader from %@: %s", tweakLoaderPath, loaderError);
            TDAppendLaunchLog([NSString stringWithFormat:@"tweakloader fallback failed path=%@ error=%s",
                               tweakLoaderPath, loaderError ?: "unknown"]);
        }
    }
    // Fix dynamic properties of some apps
    [NSUserDefaults performSelector:@selector(initialize)];

    // Attempt to load the bundle. 32-bit bundle will always fail because of 32-bit main executable, so ignore it
    if (!is32bit && ![appBundle loadAndReturnError:&error]) {
        appError = error.localizedDescription;
        NSLog(@"[LCBootstrap] loading bundle failed: %@", error);
        TDAppendLaunchLog([NSString stringWithFormat:@"bundle load failed: %@", appError]);
        *path = oldPath;
        return appError;
    }
    NSLog(@"[LCBootstrap] loaded bundle");
    TDAppendLaunchLog(@"bundle loaded");

    // Find main()
    appMain = getAppEntryPoint(appHandle);
    if (!appMain) {
        appError = @"Could not find the main entry point";
        NSLog(@"[LCBootstrap] %@", appError);
        TDAppendLaunchLog([NSString stringWithFormat:@"entry point failed: %@", appError]);
        *path = oldPath;
        return appError;
    }

    // Go!
    NSLog(@"[LCBootstrap] jumping to main %p", appMain);
    TDAppendLaunchLog([NSString stringWithFormat:@"jump main %p", appMain]);
    int ret;
    if(!is32bit) {
        argv[0] = (char *)appExecPath;
        ret = appMain(argc, argv, environ);
    } else {
        char *argv32[] = {(char*)appExecPath, (char*)*path, NULL};
        ret = appMain(sizeof(argv32)/sizeof(*argv32) - 1, argv32, environ);
    }
    // code 0 是正常退出: 返回 nil, 不让上层把"访客自己退出"当成启动失败弹错误框.
    if (ret == 0) {
        NSString *reason = [NSString stringWithFormat:@"guest main returned 0 (normal exit) pid=%d path=%s",
                            [[NSProcessInfo processInfo] processIdentifier], appExecPath];
        NSLog(@"%@", reason);
        TDAppendLaunchLog(reason);
        return nil;
    }
    return [NSString stringWithFormat:@"App returned from its main function with code %d.", ret];
}

static void exceptionHandler(NSException *exception) {
    NSString *error = [NSString stringWithFormat:@"%@\nCall stack: %@", exception.reason, exception.callStackSymbols];
    if(isLiveProcess) {
        NSExtensionContext *context = [NSClassFromString(@"LiveProcessHandler") extensionContext];
        [context cancelRequestWithError:[NSError errorWithDomain:@"LiveProcess" code:1 userInfo:@{NSLocalizedDescriptionKey: error}]];
    } else {
        [lcUserDefaults setObject:error forKey:@"error"];
    }
}

int LiveContainerMain(int argc, char *argv[]) {
    lcMainBundle = [NSBundle mainBundle];
    lcUserDefaults = NSUserDefaults.standardUserDefaults;
    
    lcSharedDefaults = [[NSUserDefaults alloc] initWithSuiteName: [LCSharedUtils appGroupID]];
    lcAppUrlScheme = NSBundle.mainBundle.infoDictionary[@"CFBundleURLTypes"][0][@"CFBundleURLSchemes"][0];
    lcAppGroupPath = [[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[NSClassFromString(@"LCSharedUtils") appGroupID]] path];
    isLiveProcess = [lcAppUrlScheme isEqualToString:@"liveprocess"];
    // Settings and the app groups of apps inside, kept before zContainer had its
    // app group, move into the group before anything below, the UI or a guest app
    // reads them.
    if(!isLiveProcess) {
        [LCSharedUtils migrateSharedDefaultsIfNeeded];
    }
    setenv("LC_HOME_PATH", getenv("HOME"), 0);

    // ConsoleLog 必须落在宿主 App 与 LiveProcess 都能写的 app group 里;
    // 实验性开关同样从这里读, 两个进程才能看到同一份设置.
    {
        NSURL *groupURL = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[LCSharedUtils appGroupID]];
        if (groupURL) {
            NSString *consoleDir = [[groupURL URLByAppendingPathComponent:@"LiveContainer/ConsoleLog"] path];
            [[NSFileManager defaultManager] createDirectoryAtPath:consoleDir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
            setenv("TD_CONSOLE_LOG_DIR", consoleDir.UTF8String, 1);
        }
        BOOL signals = [lcSharedDefaults objectForKey:@"TDConsoleSignals"] ? [lcSharedDefaults boolForKey:@"TDConsoleSignals"] : NO;
        setenv("TD_CONSOLE_SIGNALS", signals ? "1" : "0", 1);
        gTDEnvSpoofGlobal = [lcSharedDefaults objectForKey:@"TDEnvSpoof"] ? [lcSharedDefaults boolForKey:@"TDEnvSpoof"] : YES;
    }

    NSString *selectedApp = [lcUserDefaults stringForKey:@"selected"];
    NSString *selectedContainer = [lcUserDefaults stringForKey:@"selectedContainer"];
    NSString *launchUrl = nil;
    do {
        if(selectedApp) {
            launchUrl = [lcUserDefaults stringForKey:@"launchAppUrlScheme"];
            break;
        }
        // check launch task in shared defaults
        NSString* scheemFromLaunchExtension = [lcSharedDefaults stringForKey:@"LCLaunchExtensionScheme"];
        if(![scheemFromLaunchExtension isEqualToString:lcAppUrlScheme]) break;
        NSString* selectedAppFromLaunchExtension = [lcSharedDefaults stringForKey:@"LCLaunchExtensionBundleID"];
        if(!selectedAppFromLaunchExtension) break;
        NSDate* launchDate = [lcSharedDefaults objectForKey:@"LCLaunchExtensionLaunchDate"];
        NSTimeInterval secondsSinceDate = [launchDate timeIntervalSinceNow];
        if (secondsSinceDate >= 0 || secondsSinceDate < -3.0) break;
        
        selectedApp = selectedAppFromLaunchExtension;
        selectedContainer = [lcSharedDefaults stringForKey:@"LCLaunchExtensionContainerName"];
        launchUrl = [lcSharedDefaults stringForKey:@"LCLaunchExtensionLaunchURL"];
        
        [lcSharedDefaults removeObjectForKey:@"LCLaunchExtensionBundleID"];
        if (selectedContainer) [lcSharedDefaults removeObjectForKey:@"LCLaunchExtensionContainerName"];
        if (launchUrl) [lcSharedDefaults removeObjectForKey:@"LCLaunchExtensionLaunchURL"];
    } while (0);
    
    NSString* lastLaunchDataUUID;
    if(!isLiveProcess) {
        lastLaunchDataUUID = [lcUserDefaults objectForKey:@"lastLaunchDataUUID"];
    } else {
        lastLaunchDataUUID = selectedContainer;
    }
    
    // we put all files in app group after fixing 0xdead10cc. This call is here in case user upgraded lc with app's data in private Library/SharedDocuments
    [LCSharedUtils moveSharedAppFolderBack];
    
    if(lastLaunchDataUUID) {
        NSString* lastLaunchType = [lcUserDefaults objectForKey:@"lastLaunchType"];
        NSString* preferencesTo;
        if([lastLaunchType isEqualToString:@"Shared"]) {
            preferencesTo = [LCSharedUtils.appGroupPath.path stringByAppendingPathComponent:[NSString stringWithFormat:@"LiveContainer/Data/Application/%@/Library/Preferences", lastLaunchDataUUID]];
        } else {
            NSString *docPath = [NSString stringWithFormat:@"%s/Documents", getenv("LC_HOME_PATH")];
            preferencesTo = [docPath stringByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@/Library/Preferences", lastLaunchDataUUID]];
        }
        // recover preferences
        // this is not needed anymore, it's here for backward competability
        [LCSharedUtils dumpPreferenceToPath:preferencesTo dataUUID:lastLaunchDataUUID];
        if(!isLiveProcess) {
            [lcUserDefaults removeObjectForKey:@"lastLaunchDataUUID"];
            [lcUserDefaults removeObjectForKey:@"lastLaunchType"];
        }
    }
    // in case some weird apps remove the tmp folder
    [NSFileManager.defaultManager createDirectoryAtPath:@(getenv("TMPDIR")) withIntermediateDirectories:YES attributes:nil error:nil];
    
    if([selectedApp isEqualToString:@"ui"]) {
        selectedApp = nil;
        [lcUserDefaults removeObjectForKey:@"selected"];
        [lcUserDefaults removeObjectForKey:@"selectedContainer"];
    }
    
    // Take in the certificate Zeus put inside this app, before the UI or a guest
    // app looks for one. The extensions read it from the app group instead.
    if(!isLiveProcess) {
        [LCZeusCertificate moveCertificateOutOfStandardDefaults];
        [LCZeusCertificate importIfNeeded];
    }

    if(selectedApp && !selectedContainer) {
        selectedContainer = [LCSharedUtils findDefaultContainerWithBundleId:selectedApp];
    }
    NSString* runningLC = [LCSharedUtils getContainerUsingLCSchemeWithFolderName:selectedContainer];
    // if another instance is running, we just switch to that one, these should be called after uiapplication initialized
    // however if the running lc is liveprocess and current lc is livecontainer1 we just continue
    if(selectedApp && runningLC) {
        [lcUserDefaults removeObjectForKey:@"selected"];
        [lcUserDefaults removeObjectForKey:@"selectedContainer"];
        
        if([runningLC hasSuffix:@"liveprocess"]) {
            runningLC = runningLC.stringByDeletingPathExtension;
        }
        
        NSString* selectedAppBackUp = selectedApp;
        selectedApp = nil;
        dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC));
        dispatch_after(delay, dispatch_get_main_queue(), ^{
            // Base64 encode the data
            NSString* urlStr;
            if(selectedContainer) {
                urlStr = [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=%@&container-folder-name=%@", runningLC, selectedAppBackUp, selectedContainer];
            } else {
                urlStr = [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=%@", runningLC, selectedAppBackUp];
            }
            
            NSURL* url = [NSURL URLWithString:urlStr];
            if([[NSClassFromString(@"UIApplication") sharedApplication] canOpenURL:url]){
                [[NSClassFromString(@"UIApplication") sharedApplication] openURL:url options:@{} completionHandler:nil];
                
                NSString *launchUrl = [lcUserDefaults stringForKey:@"launchAppUrlScheme"];
                // also pass url scheme to another lc
                if(launchUrl) {
                    [lcUserDefaults removeObjectForKey:@"launchAppUrlScheme"];

                    // Base64 encode the data
                    NSData *data = [launchUrl dataUsingEncoding:NSUTF8StringEncoding];
                    NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
                    
                    NSString* finalUrl = [NSString stringWithFormat:@"%@://open-url?url=%@", runningLC, encodedUrl];
                    NSURL* url = [NSURL URLWithString: finalUrl];
                    
                    [[NSClassFromString(@"UIApplication") sharedApplication] openURL:url options:@{} completionHandler:nil];

                }
            }
        });

    }
    // Per-app TweakLoader switches (dontInjectTweakLoader / dontLoadTweakLoader)
    // are intentionally honored in both modes; only the payload transport differs.
    NSSetUncaughtExceptionHandler(&exceptionHandler);
    TDConsoleLogInstallCrashHandlers();

    if (selectedApp) {
        [lcUserDefaults removeObjectForKey:@"selected"];
        [lcUserDefaults removeObjectForKey:@"selectedContainer"];
        if(launchUrl) {
            lcLaunchURL = launchUrl;
            [lcUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
        }
        NSString *appError = invokeAppMain(selectedApp, selectedContainer, argc, argv);
        if (appError) {
            if(isLiveProcess) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                    NSExtensionContext *context = [NSClassFromString(@"LiveProcessHandler") extensionContext];
                    [context cancelRequestWithError:[NSError errorWithDomain:@"LiveProcess" code:1 userInfo:@{NSLocalizedDescriptionKey: appError}]];
                    exit(1);
                });
                // spin and wait for iOS to terminate
                CFRunLoopRun();
            } else {
                [lcUserDefaults setObject:appError forKey:@"error"];
                // potentially unrecovable state, exit now
                return 1;
            }
        }
    }
    
    if(isLiveProcess) {
        // The extension process must never return from its main: libxpc
        // aborts _xpc_objc_uimain with SIGTRAP when it does ("Bug in
        // libxpc: _xpc_objc_uimain() is not supposed to return"). A guest
        // whose main() exits lands here on the second pass, because the
        // fake UIApplicationMain re-enters LiveProcessMain and no second
        // extension request ever arrives. Park the main runloop on a
        // never-firing source instead: FrontBoard tears the extension down
        // when its scene closes, which kills us without us returning.
        NSLog(@"LiveProcess guest finished; parking main runloop to keep _xpc_objc_uimain alive");
        dispatch_source_t keepAlive = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(keepAlive, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
        dispatch_source_set_event_handler(keepAlive, ^{});
        dispatch_resume(keepAlive); // keeps the main runloop busy forever
        for (;;) CFRunLoopRun(); // never returns; the system kills us
    }
    
    // put back cookies
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *libraryURL = [fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;;
    NSURL *cookies2URL = [libraryURL URLByAppendingPathComponent:@"Cookies2"];
    
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:cookies2URL.path isDirectory:&isDir] && isDir) {
        NSError *error = nil;
        NSURL *cookiesURL  = [libraryURL URLByAppendingPathComponent:@"Cookies"];
        // Remove old Caches folder if exists
        if ([fm fileExistsAtPath:cookiesURL.path]) {
            if ([fm removeItemAtURL:cookiesURL error:&error]) {
                [fm moveItemAtURL:cookies2URL toURL:cookiesURL error:&error];
            } else{
                NSLog(@"Failed to remove old Cookies folder: %@", error);
            }
        }
    }
    
    void *LiveContainerSwiftUIHandle = dlopen("@executable_path/Frameworks/LiveContainerSwiftUI.framework/LiveContainerSwiftUI", RTLD_LAZY);
    NSCAssert(LiveContainerSwiftUIHandle, @"%s", dlerror());
    
    if ([lcUserDefaults boolForKey:@"LCLoadTweaksToSelf"]) {
        NSString *tweakFolder = nil;
        if (isSharedBundle) {
            NSURL *appGroupPath = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[LCSharedUtils appGroupID]];
            tweakFolder = [appGroupPath.path stringByAppendingPathComponent:@"LiveContainer/Tweaks"];
        } else {
            NSString *docPath = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject.path;
            tweakFolder = [docPath stringByAppendingPathComponent:@"Tweaks"];
        }
        setenv("LC_GLOBAL_TWEAKS_FOLDER", tweakFolder.UTF8String, 1);
#if TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR
        extern void DyldHookLoadableIntoProcess(void);
        DyldHookLoadableIntoProcess();
#endif
        dlopen("@executable_path/Frameworks/TweakLoader.dylib", RTLD_LAZY);
    }

    int (*LiveContainerSwiftUIMain)(void) = dlsym(LiveContainerSwiftUIHandle, "main");
    return LiveContainerSwiftUIMain();

}

#ifdef DEBUG
int callAppMain(int argc, char *argv[], char *envp[]) {
    assert(appMain != NULL);
    __attribute__((musttail)) return appMain(argc, argv, envp);
}
#endif
