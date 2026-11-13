#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 访客浮窗的承载层.
///
/// 为什么需要它：LC 的 `DecoratedAppSceneViewController` 会在 init 里
/// `[rootVC addChildViewController:self]`。本仓沙盒容器跑在 SwiftUI 的
/// `fullScreenCover` 里，若把 SwiftUI 的 `PresentationHostingController` 当 rootVC，
/// UIKit 的层级检查会抛
/// 「child view controller ... should have parent ... but requested parent is ...」
/// （真机日志 2026-11-13 16:02 实锤，四个 .ips 同一处）。
///
/// 做法：建一个**透明覆盖窗口**（比宿主窗口高一层），窗口自己的 rootViewController
/// 当容器，Decorated 作为它的子控制器就合法；所有访客窗口都放进这一个容器，
/// 便于统一回收，且窗口的 hitTest 只把落在访客窗口范围内的触摸交给访客，
/// 其余触摸穿透到宿主（否则整屏被透明窗口吃掉）。
@interface TDGuestOverlay : NSObject

/// 取得共享容器控制器（首次调用时创建覆盖窗口）. 找不到 windowScene 时返回 nil.
+ (nullable UIViewController *)guestHostController;

/// 把 LC dock 的访客层（windowHostingView）挪进覆盖窗口容器，确保画面在封面之上可见.
+ (void)adoptGuestHostingViews;

/// 回收覆盖窗口（访客全部关闭时调用；再次需要会自动重建）.
+ (void)tearDown;

@end

NS_ASSUME_NONNULL_END