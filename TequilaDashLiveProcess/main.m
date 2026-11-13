//
//  main.m
//  TequilaDashLiveProcess
//
//  访客进程宿主扩展入口 (LiveContainer LiveProcess 的等价物).
//  方案: C:/Users/xcrad/.omp/work/reports/m5-extension-target-plan.md (S1-S6 + S8).
//
//  本阶段 (S8 已接): beginRequest 收口 runloop 后直接进 LCBootstrap 的
//  LiveContainerMain —— hook 顺序块 / NSBundle+CFBundle+ExecPath 覆写 /
//  dlopen_nolock 载入访客 / 跳进访客 main, 全部走 LC 原文 (LC/ 目录, 整文件搬运).
//  本文件只负责: 收 userInfo → 映射 LC 键 → setenv → 调 LiveContainerMain →
//  失败时把 defaults "error" 如实 cancel 回宿主.
//

#import <dlfcn.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 访客参数键名

// 宿主经 NSExtensionItem.userInfo 传入的六个键.
// 与主 App 侧 TequilaDash/Engine/LiveProcessDebugLauncher.m 与 SandboxAppDetailView 逐字对齐;
// 刻意不用 LC 的键名 (hostUrlScheme/selected/...), 防止与真实 LC 混跑时串味 (方案 6.2).
// 本文件在取值后映射成 LC 的键名喂给 LCBootstrap —— LCBootstrap 原文零改动读它的键.
static NSString * const TDLPHostSchemeKey    = @"TequilaDashHostScheme";
static NSString * const TDLPGuestFolderNameKey = @"TequilaDashGuestFolderName";
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
    // id 上不能走点语法 (CI 实锤: property 'userInfo' not found on id), LC 原文也是方括号 (main.m:30)
    _tdlpRetrievedAppInfo = [context.inputItems.firstObject userInfo];
    // LC 同款 (main.m:32): 控制权交回 LiveProcessMain 等价物
    CFRunLoopStop(CFRunLoopGetMain());
}

@end

#pragma mark - 进程主体

static char **_tdlpEnvp, **_tdlpApple = NULL;

// LCBootstrap 的编排入口 (LC/LCBootstrap.m:665): hook 顺序块 + 覆写 NSBundle/CFBundle/
// ExecPath + dlopen_nolock 载入访客 + getAppEntryPoint + 跳进访客 main.
// 成功时它**不返回** (控制权在访客 main 手里); 返回 = 失败, 错误串已写入 defaults "error".
extern int LiveContainerMain(int argc, char *argv[]);

// S8 阶段: 真·跳访客 —— LC 的 LiveProcess/main.m:38-101 同一条链 (去 SideStore 分支).
static int TequilaDashLiveProcessMain(int argc, char *argv[]) {
    // 等 NSExtensionContext 初始化完成 (beginRequest 里 CFRunLoopStop 收口)
    CFRunLoopRun();

    NSDictionary *appInfo = [TequilaDashLiveProcessHandler retrievedAppInfo];
    NSLog(@"[TequilaDashLiveProcess] argc=%d userInfo=%@", argc, appInfo);
    if (!appInfo) {
        return 1;
    }

    // 家目录环境: LC_HOME_PATH = SandboxApps 根 (LCBootstrap 的 docPath 基准),
    // 访客 HOME 由 LCBootstrap 统一 setenv (LCBootstrap.m:472-473), 这里不抢.
    setenv("LP_HOME_PATH", getenv("HOME"), 1);
    NSString *home = appInfo[TDLPHomePathKey];
    if (home.fileSystemRepresentation) {
        setenv("LC_HOME_PATH", home.fileSystemRepresentation, 1);
    }

    // LC 键映射: LCBootstrap 原文读 selected / selectedContainer / hostUrlScheme.
    //
    // 两处加固 (启动闪退真实成因 + 多任务兼容):
    // 1. `setObject:nil forKey:` 会抛 NSInvalidArgumentException —— 只要宿主少传一个键
    //    (例如 LC 的 MultitaskSupport 只发 selected/selectedContainer) 就整进程崩溃.
    //    逐项判空, 缺键就不写.
    // 2. 同时接受 LC 原键名: MultitaskSupport/AppSceneViewController.m:58-63 走 virtual window
    //    路径时用 LC 键; 本仓自有键优先, 缺失时回落 LC 键.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *mappedHostScheme = appInfo[TDLPHostSchemeKey] ?: appInfo[@"hostUrlScheme"];
    NSString *mappedGuestName  = appInfo[TDLPGuestFolderNameKey] ?: appInfo[@"selected"];
    NSString *mappedContainer  = appInfo[TDLPContainerUUIDKey] ?: appInfo[@"selectedContainer"];
    // 联网管理 (M22): 多任务路径经 userInfo 传标记，扩展进程里落成环境变量.
    if (appInfo[@"tdNetBlock"]) {
        setenv("TD_NET_BLOCK", [appInfo[@"tdNetBlock"] boolValue] ? "1" : "0", 1);
        NSLog(@"[TequilaDashLiveProcess] TD_NET_BLOCK=%s", getenv("TD_NET_BLOCK"));
    }
    if (mappedHostScheme) {
        [defaults setObject:mappedHostScheme forKey:@"hostUrlScheme"];
    }
    if (mappedGuestName) {
        [defaults setObject:mappedGuestName forKey:@"selected"];
    }
    if (mappedContainer) {
        [defaults setObject:mappedContainer forKey:@"selectedContainer"];
    }

    // 跳! (成功 = 不返回)
    int ret = LiveContainerMain(argc, argv);

    // 走到这 = 访客没起来: LCBootstrap 已把错误串写进 defaults "error", 如实取消请求.
    NSString *errorText = [defaults objectForKey:@"error"];
    NSExtensionContext *context = [TequilaDashLiveProcessHandler extensionContext];
    if (context) {
        NSString *message = errorText ?: [NSString stringWithFormat:@"LiveContainerMain 返回 %d", ret];
        [context cancelRequestWithError:
            [NSError errorWithDomain:@"TequilaDashLiveProcess" code:2
                            userInfo:@{NSLocalizedDescriptionKey: message}]];
    }
    return ret;
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
