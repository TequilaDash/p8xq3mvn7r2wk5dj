#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// LC 主路启动 (LCSharedUtils.m:126 原文链): 写好的 LC 键 ("selected"/
/// "selectedContainer") 已由 Swift 侧落盘, 这里经 LSApplicationWorkspace 把本 App
/// 以同一 bundle id 重新拉起, completion 里主动 SIGKILL 自己 —— 重启后的进程在
/// HostGuestEntry.m 里看到 "selected" 键即进访客 (LC 的「点 App 即启动」主路).
///
/// 反射调用 (NSClassFromString + NSInvocation), 不产生编译期类符号 (house rule).
void TDLaunchGuestRestart(void);

NS_ASSUME_NONNULL_END
