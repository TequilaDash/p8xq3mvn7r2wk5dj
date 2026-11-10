//  ShareExtension 与 LaunchAppExtension 的 LC 全局符号桩.
//
//  为什么需要: 两个扩展是**独立进程**，主 App 里的 LCSharedUtils 类不存在于扩展进程。
//  上游靠 LiveContainerShared.framework（真 dylib，两个进程各自加载）解决；
//  本仓把 LC 核心静态编进主 App，所以扩展必须自己带一份 LCSharedUtils.m。
//
//  但 LCBootstrap.m（947 行）不能整个编进扩展 —— 它定义 LiveContainerMain / appMain 等
//  主 App 专用符号，且带 dyld hook 等一堆无关依赖。这里只提供 LCSharedUtils.m 需要的
//  4 个全局 + 1 个 category（NSUserDefaults(LiveContainer)），
//  与 LCBootstrap.m:23-46 的同名定义**语义一致**。
//
//  注意: 本文件只在扩展 target 编译（见 project.yml 的 sources），主 App 不编，
//  所以不会与 LCBootstrap.m 的全局符号冲突（不同进程，且不同 target）。

#import <Foundation/Foundation.h>
#import "LCSharedUtils.h"

NSUserDefaults *lcUserDefaults;
NSUserDefaults *lcSharedDefaults;
NSString *lcAppUrlScheme;
NSBundle *lcMainBundle;

@implementation NSUserDefaults (LiveContainer)

+ (instancetype)lcUserDefaults {
    if (!lcUserDefaults) {
        lcUserDefaults = [NSUserDefaults standardUserDefaults];
    }
    return lcUserDefaults;
}

+ (instancetype)lcSharedDefaults {
    if (!lcUserDefaults) {
        lcSharedDefaults = [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];
    }
    return lcSharedDefaults;
}

@end
