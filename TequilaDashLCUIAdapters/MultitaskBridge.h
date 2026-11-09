#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 多任务虚拟窗口 public 入口 (LC 默认模式同款: DecoratedAppSceneViewController 手工建窗).
///
/// 为什么不用 Swift 门面 + 模块导入: 主 App `import LiveContainerSwiftUI` 会把 framework 的
/// ObjC 头拉进同一翻译单元, 与主 App 既有桥接头重复定义枚举 (LCUtils.h 的 `Unknown` /
/// LCAppInfo.h 的 `Disabled`, CI run 42657238035 实测), 因此改走纯 C 符号 ——
/// 调用方用 `@_silgen_name` 声明, 无编译期模块依赖 (house rule, 同 TDLaunchGuestRestart).
///
/// 返回 1 = 已建窗并叠加到宿主窗口; 0 = 无宿主 rootVC 或控制器初始化失败.
/// 用 int 而非 bool: Swift 侧 @_silgen_name 声明为 Int32, 免 Bool 的 ABI 口径争论.
int TDMultitaskOpenVirtualWindow(NSString *displayName,
                                  NSString *bundleId,
                                  NSString *dataUUID);

NS_ASSUME_NONNULL_END