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

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *selected = [defaults stringForKey:@"selected"];

        if (selected) {
            // LC_HOME_PATH = SandboxApps 根: 其下 Applications/<name>.app +
            // Data/Application/<UUID> 与 LC 惯例逐层一致 (LCBootstrap docPath 直取).
            NSString *root = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/SandboxApps"];
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
