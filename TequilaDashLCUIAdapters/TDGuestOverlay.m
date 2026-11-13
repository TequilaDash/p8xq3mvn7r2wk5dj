#import "TDGuestOverlay.h"
#import "DecoratedAppSceneViewController.h"
#import "LiveContainerSwiftUI-Swift.h"

/// 透明覆盖窗口：只有落在访客窗口内的触摸才拦截，其余穿透给宿主.
@interface TDGuestOverlayWindow : UIWindow
@end

@implementation TDGuestOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit || hit == self.rootViewController.view) {
        return nil;
    }
    // 命中点若不在任何访客控制器视图内，也放行（容器背景透明）.
    for (UIView *view in self.rootViewController.view.subviews) {
        UIViewController *owner = nil;
        UIResponder *responder = view.nextResponder;
        while (responder && !owner) {
            if ([responder isKindOfClass:[UIViewController class]]) {
                owner = (UIViewController *)responder;
            }
            responder = responder.nextResponder;
        }
        if ([owner isKindOfClass:[DecoratedAppSceneViewController class]] &&
            CGRectContainsPoint(view.frame, point)) {
            return hit;
        }
    }
    return nil;
}

@end

@implementation TDGuestOverlay

static TDGuestOverlayWindow *gWindow = nil;
static UIViewController *gContainer = nil;

+ (UIWindowScene *)hostScene {
    UIWindowScene *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (!fallback) fallback = ws;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
    }
    return fallback;
}

+ (UIViewController *)guestHostController {
    if (gContainer) return gContainer;
    UIWindowScene *scene = [self hostScene];
    if (!scene) return nil;

    gWindow = [[TDGuestOverlayWindow alloc] initWithWindowScene:scene];
    gWindow.frame = scene.coordinateSpace.bounds;
    gWindow.windowLevel = UIWindowLevelNormal + 1;
    gWindow.backgroundColor = UIColor.clearColor;
    gWindow.hidden = NO;

    gContainer = [UIViewController new];
    gContainer.view.backgroundColor = UIColor.clearColor;
    gWindow.rootViewController = gContainer;
    return gContainer;
}

+ (void)adoptGuestHostingViews {
    UIViewController *container = [self guestHostController];
    if (!container) return;
    // LC 的 dock 会把访客层 windowHostingView 塞进 keyWindow 的 rootVC.view.subviews.first，
    // 本仓沙盒容器在 fullScreenCover 里，那份 subviews.first 在封面之下 —— 访客画面因此
    // 不可见（owner 实测「只有 dock 没有内容」）。这里把它挪进覆盖窗口的容器。
    UIView *host = MultitaskDockManager.shared.windowHostingView;
    host.frame = container.view.bounds;
    host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container.view addSubview:host];
}

+ (void)tearDown {
    for (UIViewController *child in [gContainer.childViewControllers copy]) {
        [child willMoveToParentViewController:nil];
        [child.view removeFromSuperview];
        [child removeFromParentViewController];
    }
    gWindow.hidden = YES;
    gWindow.rootViewController = nil;
    gWindow = nil;
    gContainer = nil;
}

@end