//
//  LiveProcessDebugLauncher.m
//  TequilaDash
//
//  S6 调试拉起 LiveProcess 扩展. 只在 DEBUG 构建的沙盒容器详情页暴露 (SandboxAppDetailView).
//  全程反射调用私有类 NSExtension —— 不产生编译期类符号引用, 避免链接期
//  _OBJC_CLASS_$_NSExtension Undefined (本仓既定手法, SupervisedHelpers.swift:24-25 同一条纪律).
//

#import "LiveProcessDebugLauncher.h"
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

#include <stdlib.h>

// 与 TequilaDashLiveProcess/main.m 逐字对齐的六个键 (防串味, 不用 LC 的键名).
static NSString * const TDLPHostSchemeKey      = @"TequilaDashHostScheme";
static NSString * const TDLPGuestFolderNameKey = @"TequilaDashGuestFolderName";
static NSString * const TDLPGuestBundleIDKey   = @"TequilaDashGuestBundleID";
static NSString * const TDLPContainerUUIDKey   = @"TequilaDashContainerUUID";
static NSString * const TDLPHomePathKey        = @"TequilaDashHomePath";
static NSString * const TDLPBookmarksKey       = @"TequilaDashBookmarks";
// vroot (Tier A): 与 TequilaDashLiveProcess/main.m 的 TDLPVRoot*Key 逐字对齐.
// per-app 开关存在 LCAppInfo.plist 的 TDVRoot / TDVRootPath, 这里翻译成载荷键.
static NSString * const TDLPVRootPathKey        = @"tdVRoot";
static NSString * const TDLPVRootModeKey        = @"tdVRootMode";

NSString * const TequilaDashLiveProcessBundleID = @"com.tequila.dash.liveprocess";

// 从 per-app LCAppInfo.plist 读 vroot 开关:
//   TDVRoot     = "off" | "path" | "full"; 写成绝对路径时等价于 path + 该路径
//   TDVRootPath = 可选, 显式覆盖 vroot 根 (默认 <LC_HOME_PATH>/Documents/rootfs)
// 返回 YES 时 *outPath/*outMode 均非空; 关闭或 plist 不存在返回 NO.
static BOOL TDReadVRootSwitch(NSDictionary *payload, NSString **outPath, NSString **outMode) {
    NSString *guestFolder = payload[TDLPGuestFolderNameKey];
    if (![guestFolder isKindOfClass:NSString.class] || guestFolder.length == 0) {
        return NO;
    }
    NSString *home = payload[TDLPHomePathKey];
    if (![home isKindOfClass:NSString.class] || home.length == 0) {
        const char *envHome = getenv("LC_HOME_PATH");
        home = (envHome && envHome[0] == '/') ? [NSString stringWithUTF8String:envHome] : nil;
    }
    if (home.length == 0) {
        home = NSHomeDirectory();
    }
    NSString *plistPath = [[[home stringByAppendingPathComponent:@"Documents"]
        stringByAppendingPathComponent:@"Applications"]
        stringByAppendingPathComponent:guestFolder];
    plistPath = [plistPath stringByAppendingPathComponent:@"LCAppInfo.plist"];
    NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (![appInfo isKindOfClass:NSDictionary.class]) {
        return NO;
    }

    NSString *mode = nil;
    NSString *path = nil;
    id rawMode = appInfo[@"TDVRoot"];
    if ([rawMode isKindOfClass:NSString.class] && [(NSString *)rawMode length] > 0) {
        NSString *raw = (NSString *)rawMode;
        if ([raw hasPrefix:@"/"]) {
            path = raw; // 写作绝对路径 = 打开 path 模式并指定根
            mode = @"path";
        } else {
            mode = raw;
        }
    } else if ([rawMode isKindOfClass:NSNumber.class]) {
        mode = [(NSNumber *)rawMode boolValue] ? @"path" : @"off";
    }
    id rawPath = appInfo[@"TDVRootPath"];
    if ([rawPath isKindOfClass:NSString.class] && [(NSString *)rawPath hasPrefix:@"/"]) {
        path = rawPath;
    }
    if (mode.length == 0) {
        return NO;
    }
    mode = [mode lowercaseString];
    if ([mode isEqualToString:@"off"]) {
        return NO;
    }
    if (![mode isEqualToString:@"path"] && ![mode isEqualToString:@"full"]) {
        // 未知模式 fail-closed: 不向下传, 避免拼错反而打开映射.
        return NO;
    }
    if (path.length == 0) {
        // M37c: 默认根用 roothide 式随机后缀 —— 每个 App+容器组合一个稳定随机目录名,
        // 避免 "Documents/rootfs" 这种固定模式被扫出来. 来源 = SHA256(guestFolder|containerUUID).
        NSString *seed = [NSString stringWithFormat:@"%@|%@", guestFolder,
                          (payload[TDLPContainerUUIDKey] ?: @"")];
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(seed.UTF8String, (CC_LONG)seed.lengthOfBytesUsingEncoding:NSUTF8StringEncoding, digest);
        NSMutableString *hex = [NSMutableString stringWithCapacity:16];
        for (int i = 0; i < 8; i++) {
            [hex appendFormat:@"%02x", digest[i]];
        }
        path = [[home stringByAppendingPathComponent:@"Documents"]
            stringByAppendingPathComponent:[NSString stringWithFormat:@".jbroot-%@", hex]];
        // root 必须存在, full 模式会把 HOME 指过来; 幂等创建.
        [[NSFileManager defaultManager] createDirectoryAtPath:path
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }
    if (![path hasPrefix:@"/"]) {
        return NO;
    }
    *outPath = path;
    *outMode = mode;
    return YES;
}

NSString *TequilaDashLiveProcessDebugLaunch(NSDictionary<NSString *, id> *userInfo) {
    static dispatch_once_t onceToken;
    static NSString *hostScheme = nil;
    dispatch_once(&onceToken, ^{
        // 宿主 scheme 取主 App 自己的 CFBundleURLTypes[0][0] (S4 加的那份).
        // LCBootstrap 等价代码将来也读 [0][0] 判宿主身份 (LCBootstrap.m:670-672), 两条路必须一致.
        NSArray *urlTypes = NSBundle.mainBundle.infoDictionary[@"CFBundleURLTypes"];
        NSArray *schemes = [urlTypes.firstObject objectForKey:@"CFBundleURLSchemes"];
        hostScheme = schemes.firstObject ?: @"";
    });

    NSMutableDictionary *payload = [userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
    if (![payload objectForKey:TDLPHostSchemeKey]) {
        payload[TDLPHostSchemeKey] = hostScheme;
    }
    // vroot (Tier A, 默认关): per-app LCAppInfo.plist 开关 -> 载荷键; main.m 落成
    // TD_VROOT/TD_VROOT_MODE, LCBootstrap + TDVRootShim 消费. 没配就不写 (env 保持干净).
    NSString *vrootPath = nil;
    NSString *vrootMode = nil;
    if (TDReadVRootSwitch(payload, &vrootPath, &vrootMode)) {
        payload[TDLPVRootPathKey] = vrootPath;
        payload[TDLPVRootModeKey] = vrootMode;
    }

    // ── 定位扩展: [NSExtension extensionWithIdentifier:error:] (反射, 不链接) ──
    Class extClass = NSClassFromString(@"NSExtension");
    SEL factorySel = NSSelectorFromString(@"extensionWithIdentifier:error:");
    if (!extClass || ![(id)extClass respondsToSelector:factorySel]) {
        return @"NSExtension 类不可用 (系统未提供或扩展点未注册)";
    }
    NSMethodSignature *factorySig = [(id)extClass methodSignatureForSelector:factorySel];
    NSInvocation *factoryInv = [NSInvocation invocationWithMethodSignature:factorySig];
    [factoryInv setTarget:extClass];
    [factoryInv setSelector:factorySel];
    __unsafe_unretained NSString *bundleID = TequilaDashLiveProcessBundleID;
    [factoryInv setArgument:&bundleID atIndex:2];
    NSError * __autoreleasing factoryError = nil;
    NSError * __autoreleasing *factoryErrorPtr = &factoryError;
    [factoryInv setArgument:&factoryErrorPtr atIndex:3];
    [factoryInv invoke];
    __unsafe_unretained id extVoid = nil;
    [factoryInv getReturnValue:&extVoid];
    id extension = extVoid;
    if (!extension) {
        return [NSString stringWithFormat:@"扩展未定位到 (%@): %@",
                TequilaDashLiveProcessBundleID,
                factoryError.localizedDescription ?: @"未知错误"];
    }

    // ── 拉起: beginExtensionRequestWithInputItems:completion: ──
    SEL beginSel = NSSelectorFromString(@"beginExtensionRequestWithInputItems:completion:");
    if (![extension respondsToSelector:beginSel]) {
        return @"NSExtension 不响应 beginExtensionRequestWithInputItems:completion:";
    }

    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = payload;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block int outPid = -1;
    __block NSString *outErrorText = nil;

    __weak id weakExtension = extension;
    void (^completion)(NSUUID *) = ^(NSUUID *identifier) {
        if (!identifier) {
            // LC 同款失败语义 (AppSceneViewController.m:112-115)
            outErrorText = @"Failed to start app. Child process has unexpectedly crashed";
            dispatch_semaphore_signal(sem);
            return;
        }
        SEL pidSel = NSSelectorFromString(@"pidForRequestIdentifier:");
        id strongExtension = weakExtension;
        if (strongExtension && [strongExtension respondsToSelector:pidSel]) {
            NSMethodSignature *pidSig = [strongExtension methodSignatureForSelector:pidSel];
            NSInvocation *pidInv = [NSInvocation invocationWithMethodSignature:pidSig];
            [pidInv setTarget:strongExtension];
            [pidInv setSelector:pidSel];
            NSUUID * __unsafe_unretained uuidArg = identifier;
            [pidInv setArgument:&uuidArg atIndex:2];
            [pidInv invoke];
            int pid = 0;
            [pidInv getReturnValue:&pid];
            if (pid > 0) {
                outPid = pid;
            } else {
                outErrorText = @"pidForRequestIdentifier: 返回 0";
            }
        } else {
            outErrorText = @"NSExtension 不响应 pidForRequestIdentifier:";
        }
        dispatch_semaphore_signal(sem);
    };

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [extension performSelector:beginSel withObject:item withObject:completion];
#pragma clang diagnostic pop

    // 调试入口: 10s 内没回执按失败处理, 不无限等 (LC 无超时 —— 它是常驻多任务宿主, 我们是 smoke)
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10LL * NSEC_PER_SEC)) != 0) {
        return @"beginExtensionRequest 10s 无回执 (超时)";
    }

    if (outErrorText) {
        return outErrorText;
    }
    return [NSString stringWithFormat:@"pid=%d", outPid];
}
