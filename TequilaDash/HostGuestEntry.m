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
void TDInitLCGlobals(void) {
    lcMainBundle = [NSBundle mainBundle];
    lcUserDefaults = NSUserDefaults.standardUserDefaults;
    lcSharedDefaults = [[NSUserDefaults alloc] initWithSuiteName: [LCSharedUtils appGroupID]];
    lcAppUrlScheme = NSBundle.mainBundle.infoDictionary[@"CFBundleURLTypes"][0][@"CFBundleURLSchemes"][0];
    lcAppGroupPath = [[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[NSClassFromString(@"LCSharedUtils") appGroupID]] path];
    isLiveProcess = NO;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // 本仓适配 (v0.3.834): 所有路径（宿主/访客/失败回落）都需要 LC 全局初始化.
        // 访客路径 LiveContainerMain 里会再赋一遍（幂等），这里先保证宿主路径非 nil.
        TDInitLCGlobals();

        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *selected = [defaults stringForKey:@"selected"];

        if (selected) {
            // 防循环守卫: 15 秒内第二次尝试进访客 = 上一次崩了, 清键回壳不变砖.
            double now = NSProcessInfo.processInfo.systemUptime;
            double last = [defaults doubleForKey:@"TDGuestBootAt"];
            if (last > 0 && (now - last) < 15.0) {
                [defaults removeObjectForKey:@"selected"];
                [defaults removeObjectForKey:@"selectedContainer"];
                [defaults removeObjectForKey:@"TDGuestBootAt"];
                TDHostBoot();
                return 0;
            }
            [defaults setDouble:now forKey:@"TDGuestBootAt"];

            // 联网管理开关 (联网管理页写入, 键随容器)
            NSString *netBlockKey = [NSString stringWithFormat:@"TDNetBlock-%@", selected];
            NSString *bundleId = [defaults stringForKey:@"TDLastGuestBundleId"];
            if (bundleId) netBlockKey = [NSString stringWithFormat:@"TDNetBlock-%@", bundleId];
            setenv("TD_NET_BLOCK",
                   [defaults boolForKey:netBlockKey] ? "1" : "0", 1);

            // LC_HOME_PATH = 容器根. v0.3.801 起与 LC 上游 `LCPath.docPath` 对齐为
            // `Documents/`（原先多一层 SandboxApps/, 导致 LC 原生 UI 与访客看不同目录）.
            // 其下 Applications/<name>.app + Data/Application/<UUID> 与 LC 惯例逐层一致.
            NSString *root = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
            setenv("LC_HOME_PATH", root.UTF8String, 1);

            int ret = LiveContainerMain(argc, argv);

            // 走到这 = 访客没起来: 清键回宿主 UI, 不变砖 (错误串在 defaults "error").
            [defaults removeObjectForKey:@"selected"];
            [defaults removeObjectForKey:@"selectedContainer"];
            TDHostBoot();
            return ret;
        }

        TDHostBoot();
        return 0;
    }
}
