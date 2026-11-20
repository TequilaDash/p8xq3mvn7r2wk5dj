//
//  main.m
//  LiveProcess
//
//  Created by Duy Tran on 3/5/25.
//

#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import "../LiveContainer/utils.h"
#import "../LiveContainer/LCSharedUtils.h"
#import <objc/message.h>
#import "../LiveContainer/Tweaks/Tweaks.h"

extern void TDConsoleLog(NSString *format, ...);
extern void TDConsoleLogInstallCrashHandlers(void);

@interface LiveProcessHandler : NSObject<NSExtensionRequestHandling>
@end
@implementation LiveProcessHandler
static NSExtensionContext *extensionContext;
static NSDictionary *retrievedAppInfo;
+ (NSExtensionContext *)extensionContext {
    return extensionContext;
}

+ (NSDictionary *)retrievedAppInfo {
    return retrievedAppInfo;
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    TDConsoleLog(@"[LiveProcess] extension request received");
    extensionContext = context;
    retrievedAppInfo = [context.inputItems.firstObject userInfo];
    // Return control to LiveContainerMain
    CFRunLoopStop(CFRunLoopGetMain());
}
@end

extern int LiveContainerMain(int argc, char *argv[]);
static char **_envp, **_apple = NULL;
int LiveProcessMain(int argc, char *argv[]) {
    // LCBootstrap 稍后也会写这个环境变量; 这里先写是为了让最早的信号安装
    // 就能看到开关, 避免开关开启后第一个崩溃窗口没有采集器.
    Class sharedUtils = NSClassFromString(@"LCSharedUtils");
    NSString *groupID = nil;
    if ([sharedUtils respondsToSelector:@selector(appGroupID)]) {
        groupID = ((NSString *(*)(id, SEL))objc_msgSend)(sharedUtils, @selector(appGroupID));
    }
    NSUserDefaults *sharedDefaults = groupID ? [[NSUserDefaults alloc] initWithSuiteName:groupID] : nil;
    BOOL signalsEnabled = [sharedDefaults objectForKey:@"TDConsoleSignals"] ? [sharedDefaults boolForKey:@"TDConsoleSignals"] : NO;
    setenv("TD_CONSOLE_SIGNALS", signalsEnabled ? "1" : "0", 1);
    // Install crash/file logging before any guest code can kill the process.
    TDConsoleLogInstallCrashHandlers();
    TDConsoleLog(@"[LiveProcess] main entered");
    // Let NSExtensionContext initialize, once it's done it will call CFRunLoopStop
    CFRunLoopRun();
    // Ensure app info is delivered
    NSDictionary *appInfo = LiveProcessHandler.retrievedAppInfo;
    NSCAssert(appInfo, @"Failed to retrieve app info");
    
    // Check if we received a request to execute a custom payload
    NSString *customPayloadDylib = appInfo[@"customPayloadDylib"];
    if(customPayloadDylib) {
        void *handle = dlopen(customPayloadDylib.fileSystemRepresentation, RTLD_LAZY);
        NSCAssert(appInfo, @"Failed to load custom payload dylib at path: %@", customPayloadDylib);
        
        NSString *customPayloadEntry = appInfo[@"customPayloadEntry"];
        NSCAssert(customPayloadEntry, @"Missing customPayloadEntry");
        int (*payloadEntry)(int, char **, char **, char **) = dlsym(handle, customPayloadEntry.UTF8String);
        return payloadEntry(argc, argv, _envp, _apple);
    }
    
    NSLog(@"Retrieved app info: %@", appInfo);
    // Carry per-app environment gates into the separate extension process.
    // 全局隐藏开关住在 app group defaults 里 (宿主与扩展都能读); appInfo 里的
    // tdGlobalHide 从未被写入, 过去这里恒为 NO -> 多任务访客永远拿到"未开启
    // 全局隐藏", 与全屏访客环境不一致 (用户实测"开了和不开一样").
    NSUserDefaults *lcShared = [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];
    BOOL tdGlobalHide = [appInfo[@"tdGlobalHide"] boolValue] || [lcShared boolForKey:@"TDGlobalHide"];
    // "环境伪值"总闸: 宿主 iManager 的开关住在 app group 里, 扩展进程同样读得到.
    NSNumber *envSpoofValue = [lcShared objectForKey:@"TDEnvSpoof"];
    BOOL tdEnvSpoofGlobal = envSpoofValue ? envSpoofValue.boolValue : YES;
    if (tdGlobalHide) {
        setenv("TD_GLOBAL_HIDE", "1", 1);
    } else {
        unsetenv("TD_GLOBAL_HIDE");
    }
    struct { __unsafe_unretained NSString *infoKey; const char *envKey; } gateMap[] = {
        {@"sysctlSpoof", "TD_SYSCTL_SPOOF"},
        {@"secTaskSpoof", "TD_SECTASK_SPOOF"},
        {@"csopsSpoof", "TD_CSOPS_SPOOF"},
        {@"procSpoof", "TD_PROC_SPOOF"},
        {@"csopsKeepDebugged", "TD_CSOPS_KEEP_DEBUGGED"},
    };
    for (size_t i = 0; i < sizeof(gateMap) / sizeof(gateMap[0]); i++) {
        NSNumber *value = [appInfo[gateMap[i].infoKey] isKindOfClass:NSNumber.class] ? appInfo[gateMap[i].infoKey] : nil;
        BOOL enabled;
        if (strcmp(gateMap[i].envKey, "TD_CSOPS_KEEP_DEBUGGED") == 0) {
            enabled = tdGlobalHide ? NO : (value ? value.boolValue : NO);
        } else {
            enabled = tdGlobalHide || (value ? value.boolValue : YES);
        }
        // "环境伪值"总闸在 app group 里 (宿主与扩展都能读): 关掉时四个伪值门控
        // 全部关闭, 与 LCBootstrap 全屏路径的 gTDEnvSpoofGlobal 语义一致.
        if (!tdEnvSpoofGlobal) {
            enabled = NO;
        }
        setenv(gateMap[i].envKey, enabled ? "1" : "0", 1);
    }
    // per-app 隐藏开关同样没进 appInfo 的门控表: 多任务访客的 dyld 裁剪因此
    // 与全屏不一致. LCSharedUtils 里 hideLiveContainer 由 LCBootstrap 直接读
    // 访客 bundle 的 LCAppInfo.plist, 这里只需要把裁剪总闸传到访客进程.
    {
        NSNumber *hideNumber = [appInfo[@"hideLiveContainer"] isKindOfClass:NSNumber.class] ? appInfo[@"hideLiveContainer"] : nil;
        BOOL hide = hideNumber ? hideNumber.boolValue : NO;
        if (!hide) {
            // appInfo 里没有该键时, 用 app group 里宿主写入的值兜底.
            NSNumber *sharedHide = [lcShared objectForKey:@"TDHideLiveContainer"];
            hide = sharedHide ? sharedHide.boolValue : NO;
        }
        setenv("TD_DYLD_TRIM", hide ? "1" : "0", 1);
    }
    setenv("LP_HOME_PATH", getenv("HOME"), 1);
    const char *overrideHomePath = [appInfo[@"lcHomePath"] fileSystemRepresentation];
    if(overrideHomePath) setenv("LC_HOME_PATH", overrideHomePath, 1);
    // The extension enters before its payload environment exists. Re-run after
    // applying the payload so TDConsoleSignals=1 actually installs handlers.
    TDConsoleLogInstallCrashHandlers();
    NSUserDefaults *lcUserDefaults = NSUserDefaults.standardUserDefaults;
    [lcUserDefaults setObject:appInfo[@"hostUrlScheme"] forKey:@"hostUrlScheme"];
    [lcUserDefaults setObject:appInfo[@"launchAppUrlScheme"] forKey:@"launchAppUrlScheme"];
    [lcUserDefaults setObject:appInfo[@"selected"] forKey:@"selected"];
    [lcUserDefaults setObject:appInfo[@"selectedContainer"] forKey:@"selectedContainer"];
    
    NSArray* bookmarks = appInfo[@"bookmarks"];
    NSMutableArray<NSURL *>* bookmarkedUrls = [NSMutableArray array];
    for(int i = 0; i < bookmarks.count; i++) {
        bool isStale = false;
        NSError* error = nil;
        bookmarkedUrls[i] = [NSURL URLByResolvingBookmarkData:bookmarks[i] options:0 relativeToURL:nil bookmarkDataIsStale:&isStale error:&error];
        [bookmarkedUrls[i] startAccessingSecurityScopedResource];
    }

    return LiveContainerMain(argc, argv);
}

// this is our fake UIApplicationMain called from _xpc_objc_uimain (xpc_main)
__attribute__((visibility("default")))
int UIApplicationMain(int argc, char * argv[], NSString * principalClassName, NSString * delegateClassName) {
    return LiveProcessMain(argc, argv);
}

// NSExtensionMain will load UIKit and call UIApplicationMain, so we need to redirect it to our fake one
static void* (*orig_dlopen)(void* dyldApiInstancePtr, const char* path, int mode);
static void* hook_dlopen(void* dyldApiInstancePtr, const char* path, int mode) {
    const char *UIKitFrameworkPath = "/System/Library/Frameworks/UIKit.framework/UIKit";
    if(path && !strncmp(path, UIKitFrameworkPath, strlen(UIKitFrameworkPath))) {
        // switch back to original dlopen
        performHookDyldApi("dlopen", 2, (void**)&orig_dlopen, orig_dlopen);
        // FIXME: may be incompatible with jailbreak tweaks?
        return RTLD_MAIN_ONLY;
    } else {
        __attribute__((musttail)) return orig_dlopen(dyldApiInstancePtr, path, mode);
    }
}

// Extension entry point
int NSExtensionMain(int argc, char *argv[], char *envp[], char *apple[]) {
    TDConsoleLog(@"[LiveProcess] NSExtensionMain entered");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    method_setImplementation(class_getInstanceMethod(NSClassFromString(@"NSXPCDecoder"), @selector(_validateAllowedClass:forKey:allowingInvocations:)), (IMP)hook_do_nothing);
#pragma clang diagnostic pop
    // hook dlopen UIKit
    performHookDyldApi("dlopen", 2, (void**)&orig_dlopen, hook_dlopen);
    // call the real one
    _envp = envp;
    _apple = apple;
    int (*orig_NSExtensionMain)(int argc, char * argv[]) = dlsym(RTLD_NEXT, "NSExtensionMain");
    return orig_NSExtensionMain(argc, argv);
}
