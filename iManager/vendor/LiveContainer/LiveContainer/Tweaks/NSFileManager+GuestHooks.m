@import Foundation;
#import "utils.h"
#import "LCSharedUtils.h"
#import "Tweaks.h"
#include "../../litehook/src/litehook.h"
#include "../LCMachOUtils.h"
#include <dlfcn.h>

BOOL isolateAppGroup = NO;
// 本仓适配 (M16): 真实 createDirectoryAtPath 实现（防巢中巢双层 hook 互指成环）
typedef BOOL (*TDCreateDirectoryIMP)(id, SEL, NSString *, BOOL, NSDictionary<NSFileAttributeKey,id> *, NSError **);
static TDCreateDirectoryIMP gOrigCreateDirectoryIMP = NULL;
static NSString *extensionParentContainerPath;
void* webKitHeader = 0;
void NSFMGuestExtensionHooksInit(NSString *parentContainerPath) {
    extensionParentContainerPath = parentContainerPath;
    isolateAppGroup = [NSUserDefaults.guestContainerInfo[@"isolateAppGroup"] boolValue];
    swizzle(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:), @selector(hook_containerURLForSecurityApplicationGroupIdentifier:));
}

void NSFMGuestHooksInit(void) {
    NSDictionary* infoDict = [NSUserDefaults guestContainerInfo];
    isolateAppGroup = [infoDict[@"isolateAppGroup"] boolValue];
    swizzle(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:), @selector(hook_containerURLForSecurityApplicationGroupIdentifier:));
    
    /// To fix https://github.com/LiveContainer/LiveContainer/issues/888 i.e. WebKit being unable to save cookie issue, we have to hook -[NSFileManager createDirectoryAtPath:withIntermediateDirectories:attributes:error:] so that WebKit still creates bookmark for the symlinked lc's cookies folder, which is resolved by the kernel to the app's cookies folder
    /// see https://github.com/apple-oss-distributions/WebKit/blob/0c8cf3581e5c01d970ea411128007c9325ba2d48/Source/WebKit/Shared/Cocoa/SandboxExtensionCocoa.mm#L159 and https://github.com/apple-oss-distributions/WebKit/blob/0c8cf3581e5c01d970ea411128007c9325ba2d48/Source/WebKit/UIProcess/WebsiteData/WebsiteDataStore.cpp#L2225
    /// WebKit::WebsiteDataStore::createHandleFromResolvedPathIfPossible requires WebKit::WebsiteDataStore::resolvedCookieStorageDirectory to return a non-empty path to create a bookmark, which is possible when WebKit::resolveAndCreateReadWriteDirectoryForSandboxExtension is non-empty. However if -[NSFileManager createDirectoryAtPath:withIntermediateDirectories:attributes:error:] returns false for cookies folder since it's a symlink, resolveAndCreateReadWriteDirectoryForSandboxExtension will return empty value. So that com.apple.WebKit.Networking process does not receive the bookmark and is unable to access the cookies folder.
    /// So the hook is simple, we just check if the path is lc's cookies folder and return YES. For performance, we check if caller's address falls in WebKit+0 to WebKit+32M
    /// If you have a better solution, please let us know.
    void* dscPtr = getDSCAddr();
    webKitHeader = getCachedSymbol(@"webKitHeader", dscPtr);
    
    if(!webKitHeader) {
        dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_GLOBAL);
        webKitHeader = LCGetLoadedImageHeader(0, "/System/Library/Frameworks/WebKit.framework/WebKit");
        saveCachedSymbol(@"webKitHeader", dscPtr, webKitHeader-dscPtr);
    }
    
    // 本仓适配 (M16, 2026-11-13): 保存 createDirectoryAtPath 的**真实**实现，
    // hook 内直接调用该 IMP，而不是 [self hook_...]。
    // 根因（owner .ips 实证）：访客 App 自身若是另一个 LiveContainer（巢中巢），
    // 它会在这之后再次 method_exchangeImplementations 同一个 selector。两套 category
    // 同名方法互相当「原实现」→ 彼此指向对方 → 无限递归（depth 10678，递归帧
    // imageIndex 全是访客的 LiveContainerShared）。持有真实 IMP 后链条必然终止。
    {
        Method origMethod = class_getInstanceMethod(NSFileManager.class, @selector(createDirectoryAtPath:withIntermediateDirectories:attributes:error:));
        if (origMethod) {
            gOrigCreateDirectoryIMP = (TDCreateDirectoryIMP)method_getImplementation(origMethod);
        }
        // iOS 26+ 的另一重风险：该 selector 的真实实现是 Swift 桥，
        // 桥可能回调同一 selector 造成单 hook 自递归。该 hook 只服务老 WebKit
        // cookie 问题（issues/888），iOS 26+ 直接不装，稳定性优先。
        if (@available(iOS 26.0, *)) {
            NSLog(@"[NSFMGuestHooks] iOS 26+ 跳过 createDirectoryAtPath hook");
        } else {
            swizzle(NSFileManager.class, @selector(createDirectoryAtPath:withIntermediateDirectories:attributes:error:), @selector(hook_createDirectoryAtPath:withIntermediateDirectories:attributes:error:));
        }
    }
}

// NSFileManager simulate app group
@implementation NSFileManager(LiveContainerHooks)

- (nullable NSURL *)hook_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    if([groupIdentifier isEqualToString:[NSClassFromString(@"LCSharedUtils") appGroupID]]) {
        // 本仓适配 (M17, 2026-11-13): lcAppGroupPath 可能为 nil。
        // 巢中巢场景（访客自带 LiveContainer）下访客的 LCSharedUtils 会调用本 hook，
        // 而本进程没有 app group entitlement → lcAppGroupPath=nil →
        // +[NSURL fileURLWithPath:nil] 抛 NSInvalidArgumentException → SIGABRT
        // （owner 2026-11-13 132227.ips 实证，崩溃点在 fileURLWithPath: +32）。
        NSString *appGroupPath = NSUserDefaults.lcAppGroupPath;
        if (appGroupPath.length > 0) {
            return [NSURL fileURLWithPath: appGroupPath];
        }
    }
    NSURL *result;
    if(isolateAppGroup) {
        NSString *homePath = extensionParentContainerPath ?: @(getenv("HOME"));
        result = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/LCAppGroup/%@", homePath, groupIdentifier]];
    } else if (NSUserDefaults.lcAppGroupPath){
        result = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/LiveContainer/Data/AppGroup/%@", NSUserDefaults.lcAppGroupPath, groupIdentifier]];
    } else {
        result = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%s/Documents/Data/AppGroup/%@", getenv("LC_HOME_PATH"), groupIdentifier]];
    }
    [NSFileManager.defaultManager createDirectoryAtURL:[result URLByAppendingPathComponent:@"Library/Caches"] withIntermediateDirectories:YES attributes:nil error:nil];
    return result;
}

- (bool)hook_createDirectoryAtPath:(NSString *)path withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary<NSFileAttributeKey,id> *)attributes error:(NSError *__autoreleasing  _Nullable *)error {
    bool ans;
    if (gOrigCreateDirectoryIMP) {
        ans = gOrigCreateDirectoryIMP(self, _cmd, path, createIntermediates, attributes, error);
    } else {
        ans = [self hook_createDirectoryAtPath:path withIntermediateDirectories:createIntermediates attributes:attributes error:error];
    }
    void* callerAddr = __builtin_return_address(0);
    if(callerAddr > webKitHeader && callerAddr < (webKitHeader + (32 << 20) )) {
        if([path hasSuffix:@"Library/Cookies"]) {
            // symlink Cookies folder
            // https://github.com/apple-oss-distributions/WebKit/blob/0c8cf3581e5c01d970ea411128007c9325ba2d48/Source/WebKit/Shared/Cocoa/SandboxUtilities.mm#L56
            // unfortunately we cannot hook sandbox_container_path_for_pid, so we symlink Cookies folder in normal mode
            // see NSFileManager+GuestHooks.m for more info
            NSFileManager *fm = NSFileManager.defaultManager;
            const char *lcHomePath = getenv(NSUserDefaults.isLiveProcess ? "LP_HOME_PATH" : "LC_HOME_PATH");
            NSString *libraryPath = [@(lcHomePath) stringByAppendingPathComponent:@"Library"];
            NSString *cookies2Path = [libraryPath stringByAppendingPathComponent:@"Cookies2"];
            NSString *cookiesPath = [libraryPath stringByAppendingPathComponent:@"Cookies"];
            NSString* appCookiesPath = [@(getenv("HOME")) stringByAppendingPathComponent:@"Library/Cookies"];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:cookies2Path isDirectory:&isDir]) {
                if([fm fileExistsAtPath:cookiesPath isDirectory:&isDir]) {
                    [fm moveItemAtPath:cookiesPath toPath:cookies2Path error:nil];
                } else {
                    [fm createDirectoryAtPath:cookies2Path withIntermediateDirectories:YES attributes:nil error:nil];
                }
            }
            remove(cookiesPath.UTF8String);
            symlink(appCookiesPath.UTF8String, cookiesPath.UTF8String);
            return YES;
        }
    }
    return ans;
}

@end
