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

// 与 TequilaDashLiveProcess/main.m 逐字对齐的六个键 (防串味, 不用 LC 的键名).
static NSString * const TDLPHostSchemeKey      = @"TequilaDashHostScheme";
static NSString * const TDLPGuestFolderNameKey = @"TequilaDashGuestFolderName";
static NSString * const TDLPGuestBundleIDKey   = @"TequilaDashGuestBundleID";
static NSString * const TDLPContainerUUIDKey   = @"TequilaDashContainerUUID";
static NSString * const TDLPHomePathKey        = @"TequilaDashHomePath";
static NSString * const TDLPBookmarksKey       = @"TequilaDashBookmarks";

NSString * const TequilaDashLiveProcessBundleID = @"com.tequila.dash.liveprocess";

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
