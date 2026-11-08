//
//  main.m
//  TequilaDashLiveProcess
//
//  访客进程宿主扩展入口 (LiveContainer LiveProcess 的等价物).
//  方案: C:/Users/xcrad/.omp/work/reports/m5-extension-target-plan.md (S1 + S5 阶段).
//
//  职责边界 (本阶段):
//    · 提供一个独立 .appex 进程与 extension request 处理骨架;
//    · NSXPCDecoder 校验旁路 (纯 ObjC runtime, 可移植);
//    · UIApplicationMain / NSExtensionMain 替身照 LC 同形就位.
//    · **不跳访客** (S8): dlopen hook 需要 performHookDyldApi 等价物 (dyld4 内部
//      LibSystemHelpers vtable 改写 + adrp/ldr 模拟, LC 在 Tweaks/Dyld.m:199-235/459-520),
//      属于方案第 6.1 节登记的 S8 前置缺口 —— 缺口落地前 hook 装不上, UIKit 会被
//      正常加载, UIApplicationMain 替身不会被绑定, 扩展走系统普通 extension 流程.
//
//  LC 对照: ref/lc_rev/LiveProcess/main.m (键名/结构逐段标注行号).
//

#import <dlfcn.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 访客参数键名

// 宿主经 NSExtensionItem.userInfo 传入的五个键.
// 与主 App 侧 TequilaDash/Engine/LiveProcessDebugLauncher.m 逐字对齐;
// 刻意不用 LC 的键名 (hostUrlScheme/selected/...), 防止与真实 LC 混跑时串味 (方案 6.2).
static NSString * const TDLPHostSchemeKey    = @"TequilaDashHostScheme";
static NSString * const TDLPGuestBundleIDKey = @"TequilaDashGuestBundleID";
static NSString * const TDLPContainerUUIDKey = @"TequilaDashContainerUUID";
static NSString * const TDLPHomePathKey      = @"TequilaDashHomePath";
static NSString * const TDLPBookmarksKey     = @"TequilaDashBookmarks";

#pragma mark - 扩展处理类

// 系统在 extension request 进来时实例化 (Info.plist NSExtensionPrincipalClass 指名).
// 实现 NSExtensionRequestHandling: 存下 context / userInfo 后收口 runloop ——
// 与 LC LiveProcess/main.m:28-33 同形, 让 TequilaDashLiveProcessMain 的 CFRunLoopRun 返回.
@interface TequilaDashLiveProcessHandler : NSObject <NSExtensionRequestHandling>
@end

@implementation TequilaDashLiveProcessHandler

static NSExtensionContext *_tdlpExtensionContext;
static NSDictionary *_tdlpRetrievedAppInfo;

+ (NSExtensionContext *)extensionContext {
    return _tdlpExtensionContext;
}

+ (NSDictionary *)retrievedAppInfo {
    return _tdlpRetrievedAppInfo;
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    _tdlpExtensionContext = context;
    _tdlpRetrievedAppInfo = context.inputItems.firstObject.userInfo;
    // LC 同款 (main.m:32): 控制权交回 LiveProcessMain 等价物
    CFRunLoopStop(CFRunLoopGetMain());
}

@end

#pragma mark - 进程主体

static char **_tdlpEnvp, **_tdlpApple = NULL;

// S5 阶段: 不跳访客 —— 拿到 userInfo 打日志, 然后如实取消请求
// (cancel 是真话: 访客启动还没接线; 等真正跳访客时这里换成 LCBootstrap 等价链路).
static int TequilaDashLiveProcessMain(int argc, char *argv[]) {
    // 等 NSExtensionContext 初始化完成 (beginRequest 里 CFRunLoopStop 收口)
    CFRunLoopRun();

    NSDictionary *appInfo = [TequilaDashLiveProcessHandler retrievedAppInfo];
    NSLog(@"[TequilaDashLiveProcess] argc=%d userInfo=%@", argc, appInfo);

    NSExtensionContext *context = [TequilaDashLiveProcessHandler extensionContext];
    if (appInfo && context) {
        NSArray<NSString *> *keys = @[TDLPHostSchemeKey, TDLPGuestBundleIDKey,
                                      TDLPContainerUUIDKey, TDLPHomePathKey, TDLPBookmarksKey];
        for (NSString *key in keys) {
            NSLog(@"[TequilaDashLiveProcess] %@ = %@", key, appInfo[key] ?: @"<缺失>");
        }
        // 访客启动未接线 (S8): 如实取消, 不假装成功
        [context cancelRequestWithError:
            [NSError errorWithDomain:@"TequilaDashLiveProcess" code:1
                            userInfo:@{NSLocalizedDescriptionKey:
                                       @"访客启动未接线 (S8 未实施), 本次扩展请求仅用于链路验证"}]];
    }
    return 0;
}

#pragma mark - 入口替身

// UIApplicationMain 替身 (LC main.m:104-107 同形): 由 _xpc_objc_uimain 调到.
// 生效前提 = dlopen hook 把 UIKit 挡在门外 (RTLD_MAIN_ONLY 技巧, main.m:111-121);
// 该 hook 依赖 performHookDyldApi 等价物 (S8 前置缺口) —— 缺口落地前本符号不会被绑到.
__attribute__((visibility("default")))
int UIApplicationMain(int argc, char *argv[], NSString *principalClassName, NSString *delegateClassName) {
    return TequilaDashLiveProcessMain(argc, argv);
}

// NSXPCDecoder 校验旁路用的空函数 (LC 的 hook_do_nothing 等价物, Tweaks.h:34).
static void _tdlpHookDoNothing(void) {
}

// 扩展入口 (LC main.m:124-136 同形, 去掉 dyld 内部 hook —— 同前置缺口).
// dlsym(RTLD_NEXT) 取 Foundation 的真实现; 本二进制的定义在前, 系统解析先命中我们.
int NSExtensionMain(int argc, char *argv[], char *envp[], char *apple[]) {
    _tdlpEnvp = envp;
    _tdlpApple = apple;

    // NSXPCDecoder._validateAllowedClass 校验旁路: S8 往返 bookmark (NSArray<NSData>)
    // 时系统校验会拒非白名单类, LC 的处理就是把这个方法换成空实现 (main.m:127).
    // 可移植 (纯 ObjC runtime, 无 dyld 内部依赖), 本阶段就装.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    Method decoderMethod = class_getInstanceMethod(NSClassFromString(@"NSXPCDecoder"),
                                                   @selector(_validateAllowedClass:forKey:allowingInvocations:));
#pragma clang diagnostic pop
    if (decoderMethod) {
        method_setImplementation(decoderMethod, (IMP)_tdlpHookDoNothing);
    }

    NSLog(@"[TequilaDashLiveProcess] NSExtensionMain entry, argc=%d", argc);
    int (*orig_NSExtensionMain)(int argc, char *argv[]) = dlsym(RTLD_NEXT, "NSExtensionMain");
    if (!orig_NSExtensionMain) {
        NSLog(@"[TequilaDashLiveProcess] dlsym(RTLD_NEXT, NSExtensionMain) 失败");
        return 1;
    }
    return orig_NSExtensionMain(argc, argv);
}
