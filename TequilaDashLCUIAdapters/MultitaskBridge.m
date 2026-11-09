#import "MultitaskBridge.h"
#import <UIKit/UIKit.h>
#import "DecoratedAppSceneViewController.h"

/// LC 同款虚拟窗口分支 (见 vendor/LiveContainer/LiveContainerSwiftUI/Utilities/LCUtils.m:82-87):
/// 取宿主 keyWindow 的 rootVC, 建 DecoratedAppSceneViewController 并叠加到宿主窗口.
/// 与上游唯一差异: 不接 PID 回调 (该属性名在镜像里被混淆过, 不碰它, 少一处同步风险).
int TDMultitaskOpenVirtualWindow(NSString *displayName,
                                  NSString *bundleId,
                                  NSString *dataUUID) {
    if (displayName.length == 0 || bundleId.length == 0) {
        return 0;
    }

    UIViewController *rootVC = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow && window.rootViewController) {
                rootVC = window.rootViewController;
                break;
            }
        }
        if (!rootVC && windowScene.windows.count > 0) {
            rootVC = windowScene.windows.firstObject.rootViewController;
        }
        if (rootVC) {
            break;
        }
    }
    if (!rootVC) {
        NSLog(@"[TDMultitask] no host rootViewController, abort");
        return 0;
    }

    DecoratedAppSceneViewController *launcherView =
        [[DecoratedAppSceneViewController alloc] initWindowName:displayName
                                                      bundleId:bundleId
                                                      dataUUID:dataUUID
                                                        rootVC:rootVC];
    if (!launcherView) {
        NSLog(@"[TDMultitask] DecoratedAppSceneViewController init returned nil");
        return 0;
    }
    launcherView.view.autoresizingMask = UIViewAutoresizingFlexibleTopMargin |
                                         UIViewAutoresizingFlexibleLeftMargin |
                                         UIViewAutoresizingFlexibleRightMargin |
                                         UIViewAutoresizingFlexibleBottomMargin;
    launcherView.view.center = rootVC.view.center;
    return 1;
}