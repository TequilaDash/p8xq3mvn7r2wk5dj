//
//  main.m
//  LiveProcess
//
//  Created by Duy Tran on 3/5/25.
//

#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#include <stdlib.h>
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

static void finishLiveProcess(int status, NSString *error) __attribute__((noreturn));
static void finishLiveProcess(int status, NSString *error) {
    NSExtensionContext *context = LiveProcessHandler.extensionContext;
    if (error) {
        TDConsoleLog(@"[LiveProcess] %@", error);
        [context cancelRequestWithError:[NSError errorWithDomain:@"LiveProcess" code:status
                                                      userInfo:@{NSLocalizedDescriptionKey: error}]];
    } else {
        TDConsoleLog(@"[LiveProcess] payload finished with code %d", status);
        [context completeRequestReturningItems:@[] completionHandler:nil];
    }
    if (context) {
        // Give the request result a chance to reach the host, but never return
        // through _xpc_objc_uimain: libxpc treats that as a SIGTRAP.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            exit(status);
        });
        CFRunLoopRun();
    }
    exit(status);
}

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
    // Ensure app info is delivered before dereferencing it.
    NSDictionary *appInfo = LiveProcessHandler.retrievedAppInfo;
    if (![appInfo isKindOfClass:NSDictionary.class]) {
        finishLiveProcess(1, @"Failed to retrieve app info.");
    }

    // Check if we received a request to execute a custom payload.
    NSString *customPayloadDylib = appInfo[@"customPayloadDylib"];
    if (customPayloadDylib) {
        if (![customPayloadDylib isKindOfClass:NSString.class] || customPayloadDylib.length == 0) {
            finishLiveProcess(1, @"The custom payload path is not a nonempty string.");
        }
        NSString *customPayloadEntry = appInfo[@"customPayloadEntry"];
        if (![customPayloadEntry isKindOfClass:NSString.class] || customPayloadEntry.length == 0) {
            finishLiveProcess(1, [NSString stringWithFormat:@"Custom payload entry is missing for %@.", customPayloadDylib]);
        }

        dlerror();
        void *handle = dlopen(customPayloadDylib.fileSystemRepresentation, RTLD_LAZY | RTLD_FIRST);
        if (!handle) {
            const char *loaderError = dlerror();
            finishLiveProcess(1, [NSString stringWithFormat:@"Could not load custom payload %@: %s",
                                  customPayloadDylib, loaderError ?: "dlopen failed without an error description"]);
        }

        dlerror();
        int (*payloadEntry)(int, char **, char **, char **) = dlsym(handle, customPayloadEntry.UTF8String);
        if (!payloadEntry) {
            const char *symbolError = dlerror();
            NSString *payloadError = [NSString stringWithFormat:@"Could not resolve custom payload entry %@ in %@: %s",
                                      customPayloadEntry, customPayloadDylib,
                                      symbolError ?: "dlsym returned a null entry without an error description"];
            dlclose(handle);
            finishLiveProcess(1, payloadError);
        }
        int status = payloadEntry(argc, argv, _envp, _apple);
        NSString *payloadError = status == 0 ? nil : [NSString stringWithFormat:@"Custom payload %@ returned code %d.", customPayloadDylib, status];
        finishLiveProcess(status, payloadError);
    }
    
    NSLog(@"Retrieved app info: %@", appInfo);
    // Only carry the host's marker here. The common bootstrap reads the suite
    // and applies the guest's gates after launch-time entitlement and JIT checks.
    if ([appInfo[@"tdGlobalHide"] boolValue]) {
        setenv("TD_GLOBAL_HIDE", "1", 1);
    } else {
        unsetenv("TD_GLOBAL_HIDE");
    }
    setenv("LP_HOME_PATH", getenv("HOME"), 1);
    const char *overrideHomePath = [appInfo[@"lcHomePath"] fileSystemRepresentation];
    if(overrideHomePath) setenv("LC_HOME_PATH", overrideHomePath, 1);
    // ConsoleLog 必须落在 app group 里, 否则扩展进程的日志会留在扩展沙盒,
    // 与宿主进程的日志分家 —— 全屏/多任务两种模式的诊断信息就没法对比.
    {
        NSString *groupID = [LCSharedUtils appGroupID];
        NSURL *groupURL = groupID ? [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:groupID] : nil;
        if (groupURL) {
            NSString *consoleDir = [[groupURL URLByAppendingPathComponent:@"LiveContainer/ConsoleLog"] path];
            [[NSFileManager defaultManager] createDirectoryAtPath:consoleDir
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
            setenv("TD_CONSOLE_LOG_DIR", consoleDir.UTF8String, 1);
        }
    }
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

    int status = LiveContainerMain(argc, argv);
    NSString *launchError = status == 0 ? nil : [NSString stringWithFormat:@"LiveContainerMain returned code %d.", status];
    finishLiveProcess(status, launchError);
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
    dlerror();
    int (*orig_NSExtensionMain)(int argc, char * argv[]) = dlsym(RTLD_NEXT, "NSExtensionMain");
    if (!orig_NSExtensionMain) {
        const char *symbolError = dlerror();
        finishLiveProcess(1, [NSString stringWithFormat:@"Could not resolve the system NSExtensionMain entry: %s",
                              symbolError ?: "dlsym returned a null entry without an error description"]);
    }
    return orig_NSExtensionMain(argc, argv);
}
