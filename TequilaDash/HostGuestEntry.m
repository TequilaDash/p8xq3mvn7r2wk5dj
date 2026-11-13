//
//  HostGuestEntry.m
//  TequilaDash
//
//  双模进程入口 (LC 同款, v0.3.791): TequilaDashApp 去掉 @main 后, 本文件的 main()
//  就是进程唯一入口.
//    · defaults 里有 LC 的 "selected" 键 = 上一次宿主主动重启进访客 (launchToGuest)
//      → setenv LC_HOME_PATH (SandboxApps 根) → LiveContainerMain: hook 顺序块 +
//      NSBundle/CFBundle/ExecPath 覆写 + dlopen_nolock + 跳访客 main (不返回).
//    · 否则 / 访客启动失败 → TDHostBoot() 起正常宿主 UI, 不变砖 (失败原因已在
//      defaults "error", LCBootstrap 写入; 日志面板可查).
//
//  LC 对照: LiveContainer/main.c:9-51 (Release -e _LiveContainerMainC 同语义),
//  LCBootstrap.m:665 LiveContainerMain. 适配: LC_HOME_PATH 先设 (LCBootstrap.m:679
//  的 setenv 是 overwrite=0, 先设先赢).
//

#import <Foundation/Foundation.h>
#import "Engine/TDConsoleLog.h"
#import <UIKit/UIKit.h>

extern int LiveContainerMain(int argc, char *argv[]);
extern void TDHostBoot(void);

// LC 的 C 全局（LCBootstrap.m:23-26 定义）—— TDInitLCGlobals 要赋值它们
extern NSUserDefaults *lcUserDefaults;
extern NSUserDefaults *lcSharedDefaults;
extern NSString *lcAppUrlScheme;
extern NSString *lcAppGroupPath;
extern NSBundle *lcMainBundle;
extern bool isLiveProcess;

// LCSharedUtils 类声明（避免 import 头文件引入桥接头依赖链；
// HostGuestEntry.m 是入口翻译单元，直接 import LCSharedUtils.h 会把
// LCBootstrap.h 的 extern 变量与其它头一起拉进来，顺序脆弱）.
@interface LCSharedUtils : NSObject
+ (NSString *)appGroupID;
@end

// 本仓适配 (v0.3.834): 初始化 LC 的 C 全局 —— 上游在 LiveContainerMain 开头赋值
// （LCBootstrap.m:670-677），但独立宿主走 TDHostBoot 不经过它，导致
// lcAppUrlScheme/lcMainBundle/lcUserDefaults/lcSharedDefaults/lcAppGroupPath 全为 nil：
//   · 多任务启动：AppSceneViewController 字典 @{hostUrlScheme:nil} 崩溃（M6）
//   · 全屏启动：launchToGuestApp 用 lcMainBundle(nil) 崩溃（M7）
//   · 免 JIT 总根因：appGroupID 兜底失败 -> 访客进程读不到证书 -> certificatePassword nil
// 上游 LC 本身就是 guest 启动器（main.c -> LiveContainerMain）所以无此问题 ——
// 这才是「对齐上游」缺的一块（R-LC-19）.
// 本仓适配 (M15, 2026-11-13): 宿主进程的未捕获异常也要留痕。
// 上游的 exceptionHandler 装在 LiveContainerMain 里；宿主走 TDHostBoot 从不经过它
// → 多任务等**宿主进程**崩溃时一个 error 键都不写，下次进入 App 无任何弹窗
// （owner 2026-11-13 实测「手动再次进入一个报错弹窗都不弹出来」）。
static void TDUncaughtExceptionHandler(NSException *exception) {
    NSString *err = [NSString stringWithFormat:@"%@\nCall stack: %@",
                     exception.reason, exception.callStackSymbols];
    [NSUserDefaults.standardUserDefaults setObject:err forKey:@"error"];
    NSUserDefaults *shared = nil;
    @try {
        NSString *group = [NSClassFromString(@"LCSharedUtils") performSelector:@selector(appGroupID)]
                            ? [[NSClassFromString(@"LCSharedUtils") performSelector:@selector(appGroupID)] description] : nil;
        if (group.length) {
            shared = [[NSUserDefaults alloc] initWithSuiteName:group];
            [shared setObject:err forKey:@"lastGuestLaunchError"];
            [shared setDouble:NSProcessInfo.processInfo.systemUptime forKey:@"lastGuestLaunchErrorUptime"];
        }
    } @catch (__unused NSException *e) {}
}

void TDInitLCGlobals(void) {
    NSSetUncaughtExceptionHandler(&TDUncaughtExceptionHandler);
    lcMainBundle = [NSBundle mainBundle];
    lcUserDefaults = NSUserDefaults.standardUserDefaults;
    lcSharedDefaults = [[NSUserDefaults alloc] initWithSuiteName: [LCSharedUtils appGroupID]];
    lcAppUrlScheme = NSBundle.mainBundle.infoDictionary[@"CFBundleURLTypes"][0][@"CFBundleURLSchemes"][0];
    lcAppGroupPath = [[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[NSClassFromString(@"LCSharedUtils") appGroupID]] path];
    isLiveProcess = NO;
}

int main(int argc, char *argv[]) {
    TDConsoleLogInstall();
    @autoreleasepool {
        // 本仓适配 (v0.3.834): 所有路径（宿主/访客/失败回落）都需要 LC 全局初始化.
        // 访客路径 LiveContainerMain 里会再赋一遍（幂等），这里先保证宿主路径非 nil.
        TDInitLCGlobals();

        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *selected = [defaults stringForKey:@"selected"];

        if (selected) {
            // 防循环守卫（改：窗口内计数，不清键）.
            // 旧逻辑「15 秒内第二次启动就回宿主 UI」会把**访客自己 abort**（例如全能签
            // 检测到注入后自退）后的快速重试误判成崩溃循环，表现为「第二次启动进主界面」。
            // 现在同一 30 秒窗口内最多连试 4 次，超过才回壳；前几次仍然正常进访客。
            double now = NSProcessInfo.processInfo.systemUptime;
            double windowStart = [defaults doubleForKey:@"TDGuestBootWindowStart"];
            NSInteger attempts = [defaults integerForKey:@"TDGuestBootAttempts"];
            if (windowStart <= 0 || (now - windowStart) > 30.0) {
                windowStart = now;
                attempts = 0;
            }
            attempts += 1;
            [defaults setDouble:windowStart forKey:@"TDGuestBootWindowStart"];
            [defaults setInteger:attempts forKey:@"TDGuestBootAttempts"];
            if (attempts > 4) {
                NSLog(@"[TDHost] 30 秒内连续 %ld 次启动访客均失败，回宿主 UI", (long)attempts);
                [defaults removeObjectForKey:@"selected"];
                [defaults removeObjectForKey:@"selectedContainer"];
                [defaults removeObjectForKey:@"TDGuestBootAttempts"];
                [defaults removeObjectForKey:@"TDGuestBootWindowStart"];
                TDHostBoot();
                return 0;
            }

            // 联网管理开关 (联网管理页写入, 键随容器)
            // 联网管理 (M22): 只看 LCAppModel.runApp 写入的 TDGuestNetBlock（按 App 勾选）.
            // 旧的 TDNetBlock-<bundleId> 口径已移除（owner 2026-11-13 要求只保留一套）.
            BOOL netBlock = [defaults boolForKey:@"TDGuestNetBlock"];
            // 以访客自己的 LCAppInfo.plist 为准：不论从 LC 列表、搜索结果还是外部
            // URL 启动，勾选状态都落在这个 plist 里（键 TDNetBlock）。
            // 只信 standardUserDefaults 的话，任何绕过 LCAppModel.runApp 的入口都会漏.
            NSString *guestInfoPath = [[[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
                                        stringByAppendingPathComponent:selected]
                                       stringByAppendingPathComponent:@"LCAppInfo.plist"];
            NSDictionary *guestInfo = [NSDictionary dictionaryWithContentsOfFile:guestInfoPath];
            if (guestInfo[@"TDNetBlock"]) {
                netBlock = [guestInfo[@"TDNetBlock"] boolValue];
            }
            setenv("TD_NET_BLOCK", netBlock ? "1" : "0", 1);
            NSLog(@"[TD-NetBlock] selected=%@ enabled=%d (plist=%@)", selected, netBlock, guestInfoPath);

            // LC_HOME_PATH = **HOME（容器根）**，不是 Documents！
            // 上游 LCBootstrap.m:341 自己拼 `[NSString stringWithFormat:@"%s/Documents",
            // getenv("LC_HOME_PATH")]`；:744 更是直接 `setenv("LC_HOME_PATH", getenv("HOME"), 0)`。
            // 本仓 v0.3.801~0.3.842 误传 Documents -> 拼出 Documents/Documents/Applications
            // -> 全屏启动报 "App bundle not found! Unable to read LCAppInfo.plist"
            // （owner 2026-11-12 真机实证，合入 9d6ea09b05 后暴露）。
            NSString *root = NSHomeDirectory();
            setenv("LC_HOME_PATH", root.UTF8String, 1);

            int ret = LiveContainerMain(argc, argv);

            // 走到这 = 访客没起来（或访客 main 已返回）。
            // ⚠️ 此时进程已被 LCBootstrap 改写：NSBundle / NSUserDefaults / execPath 都被换成
            // 访客的，且**不会回滚**。再跑宿主 UI 会读到访客的 defaults 与缺失的本地化表，
            // 表现为「应用全没了、界面变成变量名、悬浮球变黑」（owner 2026-11-13 真机实测）。
            // 正确做法：直接结束本进程，让用户重新打开 App；宿主在干净进程里启动，
            // 并由 GuestLaunchError 依据 defaults 里的 "error" 弹出失败详情。
            NSLog(@"[TDHost] guest 返回(%d)，进程已被 LC 改写，直接退出以避免脏状态 UI", ret);
            [defaults removeObjectForKey:@"selected"];
            [defaults removeObjectForKey:@"selectedContainer"];
            [defaults synchronize];
            exit(0);
        }

        TDHostBoot();
        return 0;
    }
}
