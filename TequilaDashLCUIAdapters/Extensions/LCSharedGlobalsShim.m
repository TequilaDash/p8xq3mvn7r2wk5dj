//  ShareExtension / LaunchAppExtension 的 LC 全局符号桩.
//
//  为什么需要: 两个扩展是**独立进程**，主 App 里的 LCSharedUtils 类不存在于扩展进程。
//  上游靠 LiveContainerShared.framework（真 dylib，两进程各自加载）解决；
//  本仓把 LC 核心静态编进主 App，所以扩展必须自己带一份 LCSharedUtils.m。
//
//  但 LCBootstrap.m（947 行）不能整个编进扩展 —— 它定义 LiveContainerMain / appMain 等
//  主 App 专用符号。这里只补 LCSharedUtils.m 需要、而扩展自身**没有**提供的部分。
//
//  ⚠️ 分工（避免重复定义，CI 会报 duplicate symbol）:
//    · ShareExtension 的 main.m **已经定义**了 `NSBundle *lcMainBundle` 全局 +
//      `NSUserDefaults(ShareExtension).lcMainBundle` 方法 → 本文件不再定义它们。
//    · LaunchAppExtension 没有 main.m → 由本文件提供 lcMainBundle。
//    · 两者都缺 `lcSharedDefaults` / `lcUserDefaults` / `lcAppUrlScheme` → 本文件提供。
//
//  用 `TD_EXT_HAS_LC_MAIN_BUNDLE` 宏区分（project.yml 里给 ShareExtension 加
//  OTHER_CFLAGS: -DTD_EXT_HAS_LC_MAIN_BUNDLE）。
//
//  语义与 LCBootstrap.m:23-46 的同名定义一致。

#import <Foundation/Foundation.h>
#import "LCSharedUtils.h"

NSUserDefaults *lcUserDefaults;
NSUserDefaults *lcSharedDefaults;
NSString *lcAppUrlScheme;

#ifndef TD_EXT_HAS_LC_MAIN_BUNDLE
/// 只有 LaunchAppExtension 需要：它的桥接头声明了 lcMainBundle 但目录里没有 main.m.
NSBundle *lcMainBundle;
#endif

@implementation NSUserDefaults (LiveContainerExtShim)

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
