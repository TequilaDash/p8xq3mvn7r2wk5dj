@import Darwin;
@import MachO;
@import UIKit;
@import UniformTypeIdentifiers;
@import Security;
#if TARGET_OS_MACCATALYST || TARGET_OS_OSX
#import <IOKit/IOKitLib.h>
#endif

#import "LCUtils.h"
#import "LCSharedUtils.h"  // 本仓适配: 裸名由 HEADER_SEARCH_PATHS 解析
#import "LCAppInfo.h"
#import "DecoratedAppSceneViewController.h"  // 本仓适配: 裸名由 HEADER_SEARCH_PATHS 解析
#import "TDGuestOverlay.h"

extern void TDSandboxLogAppend(const char *message);
#import "zsigner.h"  // 本仓适配: 裸名由 HEADER_SEARCH_PATHS 解析
#import "LiveContainerSwiftUI-Swift.h"

// make SFSafariView happy and open data: URLs
@implementation NSURL(hack)
- (BOOL)safari_isHTTPFamilyURL {
    // Screw it, Apple
    return YES;
}
@end

@implementation LCUtils
#pragma mark Certificate & password

+ (NSData *)certificateData {
    NSUserDefaults* nud = [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];
    if(!nud) {
        nud = NSUserDefaults.standardUserDefaults;
    }
    return [nud objectForKey:@"LCCertificateData"];
}


+ (void)setCertificatePassword:(NSString *)certPassword {
    [NSUserDefaults.standardUserDefaults setObject:certPassword forKey:@"LCCertificatePassword"];
    [[[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]] setObject:certPassword forKey:@"LCCertificatePassword"];
}


#pragma mark Multitasking
 + (NSString *)liveProcessBundleIdentifier {
     // 本仓适配 (2026-11-09): 上游硬编码 "LiveProcess.appex", 本仓扩展产物名是
     // TequilaDashLiveProcess.appex (project.yml PRODUCT_NAME), 直接找会返回 nil,
     // 多任务启动即报 "LiveProcess extension not found".
     // 顺序: 上游名 -> 扫 PlugIns 里 bundleId 以 .liveprocess 结尾的 appex -> 上游 LC1 猜测链.
     NSString *pluginsPath = NSBundle.mainBundle.builtInPlugInsPath;
     NSBundle *upstreamBundle = [NSBundle bundleWithPath:
         [pluginsPath stringByAppendingPathComponent:@"LiveProcess.appex"]];
     if (upstreamBundle) {
         return upstreamBundle.bundleIdentifier;
     }
     NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:pluginsPath error:nil];
     for (NSString *entry in entries) {
         if (![entry hasSuffix:@".appex"]) continue;
         NSBundle *candidate = [NSBundle bundleWithPath:[pluginsPath stringByAppendingPathComponent:entry]];
         NSString *bundleId = candidate.bundleIdentifier;
         if ([bundleId.lowercaseString hasSuffix:@".liveprocess"]) {
             return bundleId;
         }
     }
     NSString *bundleID = [NSString stringWithFormat:@"com.kdt.livecontainer.%@.LiveProcess", LCSharedUtils.teamIdentifier];
     if([NSExtension extensionWithIdentifier:bundleID error:nil]) {
         return bundleID;
     }
     return nil;
 }

+ (void)launchMultitaskGuestApp:(NSString *)displayName completionHandler:(void (^)(NSNumber *pid, NSError *error))completionHandler {
    if(!self.liveProcessBundleIdentifier) {
        NSError *error = [NSError errorWithDomain:displayName code:2 userInfo:@{NSLocalizedDescriptionKey: @"LiveProcess extension not found. Please reinstall LiveContainer and select Keep Extensions"}];
        if (completionHandler) completionHandler(nil, error);
        return;
    }
    
    NSUserDefaults *lcUserDefaults = NSUserDefaults.standardUserDefaults;
    NSString* bundleId = [lcUserDefaults stringForKey:@"selected"];
    NSString* dataUUID = [lcUserDefaults stringForKey:@"selectedContainer"];
    
    [lcUserDefaults removeObjectForKey:@"selected"];
    [lcUserDefaults removeObjectForKey:@"selectedContainer"];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 16.1, *)) {
            // 本仓适配 (M20, 2026-11-13): 原生多窗口模式在本仓不可用。
            // 上游的多任务装窗靠 SwiftUI 场景 `WindowGroup(id: "appView", for: String.self)`
            // （App/LiveContainerSwiftUIApp.swift:112），而本仓 framework target 把该文件
            // **exclude** 了（宿主入口在 HostGuestEntry.m，不是 SwiftUI App）→
            // MultitaskWindowManager 的 openWindow(id:"appView") 找不到任何场景，
            // 结果只剩 dock 图标、没有访客窗口 = owner 反馈的「多任务根本没起来只是个 UI 功能」。
            // 因此这里强制走虚拟窗口路径（DecoratedAppSceneViewController 直接挂到宿主顶层 VC）。
            static BOOL loggedMultitaskFallback = NO;
            if (!loggedMultitaskFallback) {
                loggedMultitaskFallback = YES;
                NSLog(@"[TD-Multitask] 本仓无 appView SwiftUI 场景，强制虚拟窗口模式（忽略 LCMultitaskMode=%ld）",
                      (long)[NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskMode"]);
            }
            if(NO && UIApplication.sharedApplication.supportsMultipleScenes && [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskMode"] == 1) {
                [MultitaskWindowManager openAppWindowWithDisplayName:displayName dataUUID:dataUUID bundleId:bundleId pidCallback:completionHandler];
                MultitaskDockManager *dock = [MultitaskDockManager shared];
                [dock addRunningApp:displayName appUUID:dataUUID view:nil];
                return;
            }
        }
        
        // 本仓适配 (M19/M24, 2026-11-13): 用**独立覆盖窗口**承载访客浮窗.
        //
        // 为什么不挂 SwiftUI 控制器：LC 的 DecoratedAppSceneViewController 在 init 里
        // 会 `[rootVC addChildViewController:self]`；把 SwiftUI 的
        // PresentationHostingController 当 rootVC，UIKit 层级检查会抛
        // 「child view controller ... should have parent ... but requested parent is ...」
        // （owner 2026-11-13 16:02 四个 .ips 同一处，SIGABRT）。
        // 为什么不用 keyWindow.rootVC：本仓沙盒容器在 fullScreenCover 里，
        // 挂上去落在封面之下 → 只见 dock 不见画面。
        // 覆盖窗口方案两者都避开：容器是普通 UIViewController，窗口比宿主高一层，
        // 且 hitTest 只拦截落在访客窗口内的触摸，其余穿透。
        UIViewController *container = [TDGuestOverlay guestHostController];
        if (!container) {
            NSLog(@"[TD-Multitask] 无法创建覆盖窗口（无 windowScene），放弃启动 %@", displayName);
            if (completionHandler) {
                completionHandler(nil, [NSError errorWithDomain:@"TDMultitask" code:3
                    userInfo:@{NSLocalizedDescriptionKey: @"宿主窗口未就绪"}]);
            }
            return;
        }
        [TDGuestOverlay adoptGuestHostingViews];
        {
            char buf[256];
            snprintf(buf, sizeof(buf), "mount bundle=%s uuid=%s",
                     bundleId.UTF8String ?: "-", dataUUID.UTF8String ?: "-");
            TDSandboxLogAppend(buf);
        }
        NSLog(@"[TD-Multitask] 覆盖窗口挂载 (bundleId=%@, dataUUID=%@, mode=%ld)",
              bundleId, dataUUID,
              (long)[NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskMode"]);
        DecoratedAppSceneViewController *launcherView = [[DecoratedAppSceneViewController alloc] initWindowName:displayName bundleId:bundleId dataUUID:dataUUID rootVC:container];
        // Wire PID callback
        launcherView.pidAvailableHandler = completionHandler;
        launcherView.view.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        launcherView.view.center = container.view.center;
    });
}

#pragma mark Code signing


/// 确保 ZSigner 类可用.
///
/// 本仓适配 (与上游唯一的语义差异): 上游 ZSign 是**独立 dylib**, 必须 dlopen
/// `@executable_path/Frameworks/ZSign.dylib`; 本仓把 ZSign 静态编进主 App
/// (project.yml 主 target sources 含 `ZSign/`), 进程内已有 `ZSigner` 类,
/// 没有也不该有那个 dylib. 所以先查类, 查到即成功; 查不到才回落上游的 dlopen
/// (兼容将来把 ZSign 拆回 dylib 的接法).
+ (void)loadStoreFrameworksWithError2:(NSError **)error {
    static BOOL loaded = NO;
    if (loaded) return;

    // 静态链接路径: ZSigner 已在进程内.
    if (NSClassFromString(@"ZSigner")) {
        loaded = YES;
        return;
    }

    void* handle = dlopen("@executable_path/Frameworks/ZSign.dylib", RTLD_GLOBAL);
    const char* dlerr = dlerror();
    if (!handle || (uint64_t)handle > 0xf00000000000) {
        if (error) {
            NSString* reason = dlerr ? [NSString stringWithUTF8String:dlerr]
                                     : @"ZSigner 类不存在且 ZSign.dylib 不可加载";
            *error = [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"Failed to load ZSign: %@", reason]}];
        }
        NSLog(@"[LC] failed to load ZSign: %s", dlerr ? dlerr : "(no dlerror)");
        return;
    }

    loaded = YES;
}

+ (NSURL *)storeBundlePath {
    if ([self store] == SideStore) {
        return [LCSharedUtils.appGroupPath URLByAppendingPathComponent:@"Apps/com.SideStore.SideStore/App.app"];
    } else {
        return [LCSharedUtils.appGroupPath URLByAppendingPathComponent:@"Apps/com.rileytestut.AltStore/App.app"];
    }
}

+ (NSString *)storeInstallURLScheme {
    if ([self store] == SideStore) {
        return @"sidestore://install?url=%@";
    } else {
        return @"altstore://install?url=%@";
    }
}

+ (NSProgress *)signAppBundleWithZSign:(NSURL *)path completionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    NSError *error = nil;

    // use zsign as our signer~
    // Load libraries from Documents, yeah
    [self loadStoreFrameworksWithError2:&error];

    if (error) {
        completionHandler(NO, error);
        return nil;
    }

    NSLog(@"[LC] starting signing...");
    
    NSProgress* ans = [NSClassFromString(@"ZSigner") signWithAppPath:[path path] bundleId:NSBundle.mainBundle.bundleIdentifier cert:self.certificateData pass:LCSharedUtils.certificatePassword completionHandler:completionHandler];
    
    return ans;
}

+ (NSProgress *)signFilesWithZSignWithURLs:(NSArray<NSURL*>*)urls completionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    NSError *error = nil;
    [self loadStoreFrameworksWithError2:&error];
    if (error) {
        completionHandler(NO, error);
        return nil;
    }
    NSMutableArray *paths = [NSMutableArray arrayWithCapacity:[urls count]];
    for (NSURL *url in urls) {
        [paths addObject:url.path];
    }
    
    return [NSClassFromString(@"ZSigner") signMachOPathArr:paths bundleId:NSBundle.mainBundle.bundleIdentifier cert:self.certificateData
                                                      pass:LCSharedUtils.certificatePassword completionHandler:completionHandler];
}

+ (NSString*)getCertTeamIdWithKeyData:(NSData*)keyData password:(NSString*)password {
    NSError *error = nil;
    [self loadStoreFrameworksWithError2:&error];
    if (error) {
        return nil;
    }
    NSString* ans = [NSClassFromString(@"ZSigner") getTeamIdWithCert:keyData pass:password];
    return ans;
}

+ (int)validateCertificateWithCompletionHandler:(void(^)(int status, NSDate *expirationDate, NSString *organizationalUnitName, NSString *error))completionHandler {
    NSError *error = nil;
    NSData *certData = [LCUtils certificateData];
    // 上游此处判 `if (error)` 时 error 还没被任何调用赋值, 等于永不触发; 真实意图是
    // 「没有证书就别往下走」. 按意图修正: 证书数据为空直接报 -6 (与上游失败码一致).
    if (!certData) {
        return -6;
    }
    [self loadStoreFrameworksWithError2:&error];
    if (error) {
        return -6;
    }
    int ans = [NSClassFromString(@"ZSigner") checkCert:certData pass:[LCSharedUtils certificatePassword] completionHandler:completionHandler];
    return ans;
}

#pragma mark JIT

+ (BOOL)isTXMScriptRequired {
    if (@available(iOS 19.0, *)) {
        // 本仓适配 (2026-11-09): 上游链接 MacOSX SDK 的 IOKit.framework (project.pbxproj:188)
        // 以支持 Catalyst/Mac 变体; 本仓只编 iOS, iOS SDK 无公开 IOKit 头.
        // 上游原样留 vendor/LiveContainer/, 此文件是编译用的适配副本.
#if TARGET_OS_MACCATALYST || TARGET_OS_OSX
        io_registry_entry_t memory_map = IORegistryEntryFromPath(0, "IODeviceTree:/chosen/memory-map");
        if (memory_map == IO_OBJECT_NULL)
            return NO;
        NSArray *keys = (__bridge NSArray *)IORegistryEntryCreateCFProperty(memory_map, CFSTR(kIORegistryEntryPropertyKeysKey), 0, 0);
        IOObjectRelease(memory_map);
        return keys && [keys containsObject:@"TXM"];
#else
        return NO;
#endif
    }
    return NO;
}

+ (NSString *)base64EncodedUniversalJITScript {
    static dispatch_once_t onceToken;
    static NSString *script;
    dispatch_once(&onceToken, ^{
        NSData *data = [NSData dataWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"universal" ofType:@"js"]];
        script = [data base64EncodedStringWithOptions:0];
    });
    return script;
}

#pragma mark Setup

+ (Store) store {
    static Store ans;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // use uttype to accurately detect store
        if([UTType typeWithIdentifier:[NSString stringWithFormat:@"io.sidestore.Installed.%@", NSBundle.mainBundle.bundleIdentifier]]) {
            ans = SideStore;
        } else if ([UTType typeWithIdentifier:[NSString stringWithFormat:@"io.altstore.Installed.%@", NSBundle.mainBundle.bundleIdentifier]]) {
            ans = AltStore;
        } else {
            ans = Unknown;
        }
        
        if(ans != Unknown) {
            return;
        }
        
        if([[LCSharedUtils appGroupID] containsString:@"AltStore"] && ![[LCSharedUtils appGroupID] isEqualToString:@"group.com.rileytestut.AltStore"]) {
            ans = AltStore;
        } else if ([[LCSharedUtils appGroupID] containsString:@"SideStore"] && ![[LCSharedUtils appGroupID] isEqualToString:@"group.com.SideStore.SideStore"]) {
            ans = SideStore;
        } else if (![[LCSharedUtils appGroupID] containsString:@"Unknown"] ) {
            ans = ADP;
        } else {
            ans = Unknown;
        }
    });
    return ans;
}

+ (NSString *)appUrlScheme {
    return NSBundle.mainBundle.infoDictionary[@"CFBundleURLTypes"][0][@"CFBundleURLSchemes"][0];
}

+ (BOOL)isAppGroupAltStoreLike {
    return [LCSharedUtils.appGroupID containsString:@"SideStore"] || [LCSharedUtils.appGroupID containsString:@"AltStore"];
}

+ (void)changeMainExecutableTo:(NSString *)exec error:(NSError **)error {
    NSURL *infoPath = [LCSharedUtils.appGroupPath URLByAppendingPathComponent:@"Apps/com.kdt.livecontainer/App.app/Info.plist"];
    NSMutableDictionary *infoDict = [NSMutableDictionary dictionaryWithContentsOfURL:infoPath];
    if (!infoDict) return;

    infoDict[@"CFBundleExecutable"] = exec;
    [infoDict writeToURL:infoPath error:error];
}

+ (void)validateJITLessSetupWithCompletionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    // Verify that the certificate is usable
    // Create a test app bundle
    NSString *path = NSTemporaryDirectory();
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *tmpLibPath = [path stringByAppendingPathComponent:@"TestJITLess.dylib"];
    [NSFileManager.defaultManager copyItemAtPath:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TestJITLess.dylib"] toPath:tmpLibPath error:nil];

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block bool signSuccess = false;
    __block NSError* signError = nil;
    
    // Sign the test app bundle

    [LCUtils signFilesWithZSignWithURLs:@[[NSURL fileURLWithPath:tmpLibPath]]
                  completionHandler:^(BOOL success, NSError *_Nullable error) {
        signSuccess = success;
        signError = error;
        dispatch_semaphore_signal(sema);
    }];

    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if(!signSuccess) {
            completionHandler(NO, signError);
        } else if (checkCodeSignature([tmpLibPath UTF8String])) {
            completionHandler(YES, signError);
        } else {
            completionHandler(NO, [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:2 userInfo:@{NSLocalizedDescriptionKey: @"lc.signer.latestCertificateInvalidErr"}]);
        }
        [NSFileManager.defaultManager removeItemAtPath:tmpLibPath error:nil];
    });
}

+ (NSURL *)archiveIPAWithBundleName:(NSString*)newBundleName includingExtraInfoDict:(NSDictionary *)extraInfoDict error:(NSError **)error {
    if (*error) return nil;

    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *bundlePath = NSBundle.mainBundle.bundleURL;

    NSURL *tmpPath = manager.temporaryDirectory;

    NSURL *tmpPayloadPath = [tmpPath URLByAppendingPathComponent:@"LiveContainer2/Payload"];
    [manager removeItemAtURL:tmpPayloadPath error:nil];
    [manager createDirectoryAtURL:tmpPayloadPath withIntermediateDirectories:YES attributes:nil error:error];
    if (*error) return nil;
    
    NSURL *tmpIPAPath = [tmpPath URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.ipa", newBundleName]];
    

    [manager copyItemAtURL:bundlePath toURL:[tmpPayloadPath URLByAppendingPathComponent:@"App.app"] error:error];
    if (*error) return nil;
    
    NSURL *infoPath = [tmpPayloadPath URLByAppendingPathComponent:@"App.app/Info.plist"];
    NSMutableDictionary *infoDict = [NSMutableDictionary dictionaryWithContentsOfURL:infoPath];
    if (!infoDict) return nil;

    infoDict[@"CFBundleDisplayName"] = newBundleName;
    infoDict[@"CFBundleName"] = newBundleName;
    infoDict[@"CFBundleIdentifier"] = [NSString stringWithFormat:@"com.kdt.%@", newBundleName];
    infoDict[@"CFBundleURLTypes"][0][@"CFBundleURLSchemes"][0] = [newBundleName lowercaseString];
    while([infoDict[@"CFBundleURLTypes"] count] > 1) {
        [infoDict[@"CFBundleURLTypes"] removeLastObject];
    }
    [infoDict removeObjectForKey:@"UTExportedTypeDeclarations"];
    infoDict[@"CFBundleIconName"] = @"AppIconGrey";
    if (infoDict[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconName"]) {
        infoDict[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconName"] = @"AppIconGrey";
    }
    infoDict[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"][0] = @"AppIconGrey60x60";
    
    if (infoDict[@"CFBundleIcons~ipad"][@"CFBundlePrimaryIcon"][@"CFBundleIconName"]) {
        infoDict[@"CFBundleIcons~ipad"][@"CFBundlePrimaryIcon"][@"CFBundleIconName"] = @"AppIconGrey";
    }
    infoDict[@"CFBundleIcons~ipad"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"][0] = @"AppIconGrey60x60";
    infoDict[@"CFBundleIcons~ipad"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"][1] = @"AppIconGrey76x76";
    [infoDict addEntriesFromDictionary:extraInfoDict];
    
    // reset a executable name so they don't look the same on the log
    NSURL* appBundlePath = [tmpPayloadPath URLByAppendingPathComponent:@"App.app"];
    
    NSURL* execFromPath = [appBundlePath URLByAppendingPathComponent:infoDict[@"CFBundleExecutable"]];
    infoDict[@"CFBundleExecutable"] = newBundleName;
    NSURL* execToPath = [appBundlePath URLByAppendingPathComponent:infoDict[@"CFBundleExecutable"]];
    
    // MARK: patch main executable
    // we remove the teamId after app group id so it can be correctly signed by AltSign.
    NSString* entitlementXML = getExecutableEntitlementXML(NSBundle.mainBundle.executablePath);
    NSData *plistData = [entitlementXML dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *dict = [NSPropertyListSerialization propertyListWithData:plistData
                                                                          options:NSPropertyListMutableContainers
                                                                           format:nil
                                                                            error:error];
    if(*error) {
        return nil;
    }
    
    NSString* teamId = dict[@"com.apple.developer.team-identifier"];
    if(![teamId isKindOfClass:NSString.class]) {
        *error = [NSError errorWithDomain:@"archiveIPAWithBundleName" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"com.apple.developer.team-identifier is not a string!"}];
        return nil;
    }
    infoDict[@"PrimaryLiveContainerTeamId"] = teamId;
    NSArray* appGroupsToFind = @[
        @"group.com.SideStore.SideStore",
        @"group.com.rileytestut.AltStore",
    ];
    
    // remove the team id prefix in app group id added by SideStore/AltStore
    for(NSString* appGroup in appGroupsToFind) {
        NSUInteger appGroupCount = [dict[@"com.apple.security.application-groups"] count];
        for(int i = 0; i < appGroupCount; ++i) {
            NSString* targetAppGroup = [NSString stringWithFormat:@"%@.%@", appGroup, teamId];
            if([dict[@"com.apple.security.application-groups"][i] isEqualToString:targetAppGroup]) {
                dict[@"com.apple.security.application-groups"][i] = appGroup;
            }
        }
    }
    
    // set correct application-identifier
    dict[@"application-identifier"] = [NSString stringWithFormat:@"%@.%@", teamId, infoDict[@"CFBundleIdentifier"]];
    
    // For TrollStore
    NSString* containerId = dict[@"com.apple.private.security.container-required"];
    if(containerId) {
        dict[@"com.apple.private.security.container-required"] = infoDict[@"CFBundleIdentifier"];
    }
    
    
    // We have to change executable's UUID so iOS won't consider 2 executables the same
    NSString* errorChangeUUID = LCParseMachO([execFromPath.path UTF8String], false, ^(const char *path, struct mach_header_64 *header, int fd, void* filePtr) {
        LCChangeMachOUUID(header);
    });
    if (errorChangeUUID) {
        NSMutableDictionary* details = [NSMutableDictionary dictionary];
        [details setValue:errorChangeUUID forKey:NSLocalizedDescriptionKey];
        // populate the error object with the details
        *error = [NSError errorWithDomain:@"world" code:200 userInfo:details];
        NSLog(@"[LC] %@", errorChangeUUID);
        return nil;
    }
    
    NSData* newEntitlementData = [NSPropertyListSerialization dataWithPropertyList:dict format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    [LCUtils loadStoreFrameworksWithError2:error];
    BOOL adhocSignSuccess = [NSClassFromString(@"ZSigner") adhocSignMachOAtPath:execFromPath.path bundleId:infoDict[@"CFBundleIdentifier"] entitlementData:newEntitlementData];
    if (!adhocSignSuccess) {
        *error = [NSError errorWithDomain:@"archiveIPAWithBundleName" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"Failed to adhoc sign main executable!"}];
        return nil;
    }
    
    // MARK: archive bundle
    
    [manager moveItemAtURL:execFromPath toURL:execToPath error:error];
    if (*error) {
        NSLog(@"[LC] %@", *error);
        return nil;
    }
    
    // we don't care about errors when removing unnecessary files. errors occur probably because the file does not exist
    // we remove the extension
    [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"PlugIns"] error:nil];
    // remove all sidestore stuff
    // 本仓适配 (v0.3.801): 本仓不接 SideStore, `sideStoreExist` 恒 false, 本块永不执行.
    // 保留是防御性的 —— 若访客包是从 SideStore 版 LC 迁移过来的, 里面可能带
    // SideStoreSupport/SideStoreApp.framework 与 intents 元数据, 清掉更干净.
    // 不删这块的理由: 它是"清外来残留"而非"启用 SideStore", 与"不接入 SideStore"不冲突.
    if([NSUserDefaults sideStoreExist]) {
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Frameworks/SideStoreSupport.framework"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Frameworks/SideStore.framework"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Frameworks/SideStoreApp.framework"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Intents.intentdefinition"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"ViewApp.intentdefinition"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Metadata.appintents"] error:nil];
        [infoDict removeObjectForKey:@"INIntentsSupported"];
        [infoDict removeObjectForKey:@"NSUserActivityTypes"];
    }
    
    [infoDict writeToURL:infoPath error:error];
    
    dlopen("/System/Library/PrivateFrameworks/PassKitCore.framework/PassKitCore", RTLD_GLOBAL);
    NSData *zipData = [[NSClassFromString(@"PKZipArchiver") new] zippedDataForURL:tmpPayloadPath.URLByDeletingLastPathComponent];
    if (!zipData) return nil;

    [manager removeItemAtURL:tmpPayloadPath error:error];
    if (*error) return nil;
    
    if([manager fileExistsAtPath:tmpIPAPath.path]) {
        [manager removeItemAtURL:tmpIPAPath error:error];
        if (*error) return nil;
    }

    [zipData writeToURL:tmpIPAPath options:0 error:error];
    if (*error) return nil;

    return tmpIPAPath;
}

+ (NSString *)getVersionInfo {
    return [NSString stringWithFormat:@"Version %@-%@",
            NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"],
            NSBundle.mainBundle.infoDictionary[@"LCVersionInfo"]];
}

+ (NSData*)bookmarkForURL:(NSURL*) url {
    return [url bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
}


@end
