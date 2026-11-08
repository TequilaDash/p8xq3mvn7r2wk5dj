#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// S6 调试拉起 LiveProcess 扩展 (m5-extension-target-plan.md 第 6.1 节 S6).
///
/// 用私有类 NSExtension (extensionWithIdentifier:error:) 定位本 App 的
/// com.tequila.dash.liveprocess 扩展, beginExtensionRequestWithInputItems: 拉起,
/// 再 pidForRequestIdentifier: 取进程号 —— 调用链与 LC AppSceneViewController.m:52-107 同形.
///
/// 同步阻塞最长 10s (内部信号量等 completion), 调试入口可接受.
/// 返回: 成功 = @"pid=<n>"; 失败 = 错误描述 (不抛异常, 不返回 nil).
///
/// userInfo 的六个键必须与 TequilaDashLiveProcess/main.m 的键名逐字一致.
NSString *TequilaDashLiveProcessDebugLaunch(NSDictionary<NSString *, id> *userInfo);

NS_ASSUME_NONNULL_END
