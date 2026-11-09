//
//  LaunchGuest.m
//  TequilaDash
//
//  LC 主路启动的最后一跳 (LCSharedUtils.m:126-170 同链): LSApplicationWorkspace
//  openApplicationWithBundleIdentifier:configuration:completionHandler: 把本 App
//  重启, completion 里 svc+SIGKILL 自杀交出进程. 键 ("selected" 等) 由 Swift 侧先落盘.
//
//  全程反射调用私有类 LSApplicationWorkspace / 私有常量自备 (LC 同款),
//  不产生编译期链接符号 (本仓既定手法, SupervisedHelpers.swift:24-25).
//

#import "LaunchGuest.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// LC 同款私有常量 (LCSharedUtils.m:11), 不链接系统符号
static NSString * const TDFBSOpenApplicationOptionKeyActivateAsClassic = @"__ActivateAsClassic";

void TDLaunchGuestRestart(NSString * _Nullable pendingMarkerPath) {
    // 启动进行中标记 (本仓适配): 落文件 + 记住绝对路径. 重启后 LCBootstrap 在临门一脚前删它;
    // 下次宿主启动若文件仍在 = 上次崩在启动阶段. 无 app group 时扩展容器与本进程不共享
    // suite, 这是唯一可靠的失败信号. 写失败不拦路 (只是少一条诊断).
    if (pendingMarkerPath.length > 0) {
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createFileAtPath:pendingMarkerPath contents:[NSData data] attributes:nil];
        NSUserDefaults *hostDefaults = [NSUserDefaults standardUserDefaults];
        [hostDefaults setObject:pendingMarkerPath forKey:@"TDGuestLaunchMarker"];
        [hostDefaults synchronize];
    }
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL wsSel = NSSelectorFromString(@"defaultWorkspace");
    if (!wsClass || ![(id)wsClass respondsToSelector:wsSel]) {
        return;
    }
    id workspace = [(id)wsClass performSelector:wsSel];

    SEL openSel = NSSelectorFromString(@"openApplicationWithBundleIdentifier:configuration:completionHandler:");
    if (![workspace respondsToSelector:openSel]) {
        return;
    }

    // 私有配置类 _LSOpenConfiguration (LC: PrivClass(_LSOpenConfiguration))
    Class cfgClass = NSClassFromString(@"_LSOpenConfiguration");
    id configuration = cfgClass ? [[cfgClass alloc] init] : nil;

    // ActivateAsClassic 注入 (LC: configuration 的 FBSOpenApplicationOptionKey 键值对;
    // 私有键无编译期符号, KVC 写入)
    if (configuration) {
        @try {
            [configuration setValue:TDFBSOpenApplicationOptionKeyActivateAsClassic
                             forKey:@"__ActivateAsClassic"];
        } @catch (NSException *__) {
            // 键名变化时照旧裸重启, 不拦路
        }
    }

    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;

    void (^completion)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
        // LC 同款: completion 里主动杀自己 (LCSharedUtils.m:129-134) ——
        // 新实例已起, 旧进程活着会抢容器目录与 NSUserDefaults
        __asm__ __volatile__ ("mov x0, #31\n" "mov x16, #26\n" "svc #0x80");
        raise(SIGKILL);
    };

    NSMethodSignature *sig = [workspace methodSignatureForSelector:openSel];
    if (!sig) {
        return;
    }
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:workspace];
    [inv setSelector:openSel];
    __unsafe_unretained NSString *bidArg = bundleID;
    __unsafe_unretained id cfgArg = configuration;
    __unsafe_unretained void (^compArg)(BOOL, NSError *) = completion;
    [inv setArgument:&bidArg atIndex:2];
    [inv setArgument:&cfgArg atIndex:3];
    [inv setArgument:&compArg atIndex:4];
    [inv invoke];

    // 双发重试 (LC: tries = 2, 首次冷启动偶发失败): 首发已 invoke, 这里隔 0.4s 补一发.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [inv invoke];
    });
}
