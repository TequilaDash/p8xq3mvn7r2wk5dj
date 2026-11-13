#import "TDGuestOverlay.h"
#import "DecoratedAppSceneViewController.h"
#import "LiveContainerSwiftUI-Swift.h"

extern void TDSandboxLogAppend(const char *message);

/// 透明覆盖窗口：只有落在访客窗口内的触摸才拦截，其余穿透给宿主.
@interface TDGuestOverlayWindow : UIWindow
@end

@implementation TDGuestOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    UIView *root = self.rootViewController.view;
    if (!hit || hit == root) {
        // 落在透明背景上：不拦截，交给下面的宿主窗口。
        // 访客画面在 root 的子视图（VirtualWindowsHostView）里；它自己的 hitTest
        // 已在空白处返回 nil，所以这里只需判断是否命中 root 本身。
        return nil;
    }
    return hit;
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

    // 沙盒容器出现/消失时同步覆盖窗口：容器回来就重新挂载访客层并显示；
    // 容器离开就隐藏覆盖窗口，避免访客浮窗飘在宿主其它界面上.
    static id showObserver = nil;
    static id hideObserver = nil;
    if (!showObserver) {
        showObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:@"TDShowSandboxOverlay" object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification * _Nonnull note) {
            if (!gWindow) return;
            gWindow.hidden = NO;
            [TDGuestOverlay adoptGuestHostingViews];
            NSLog(@"[TD-Multitask] 覆盖窗口随沙盒容器显示");
        }];
    }
    if (!hideObserver) {
        hideObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:@"TDHideSandboxOverlay" object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification * _Nonnull note) {
            if (!gWindow) return;
            gWindow.hidden = YES;
            NSLog(@"[TD-Multitask] 覆盖窗口随沙盒容器隐藏");
        }];
    }

    // 回到前台时若窗口被系统隐掉，重新亮出来（多任务窗口「返回后消失」的兜底）.
    static id activeObserver = nil;
    if (!activeObserver) {
        activeObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification * _Nonnull note) {
            if (gWindow && gWindow.hidden) {
                gWindow.hidden = NO;
                NSLog(@"[TD-Multitask] 覆盖窗口在回到前台时重新显示");
            }
        }];
    }
    return gContainer;
}

+ (void)adoptGuestHostingViews {
    UIViewController *container = [self guestHostController];
    if (!container) return;
    if (CGRectIsEmpty(container.view.bounds) && gWindow) {
        container.view.frame = gWindow.bounds;
    }
    NSLog(@"[TD-Multitask] adopt: container=%@ bounds=%@ window=%@",
          NSStringFromClass(container.class), NSStringFromCGRect(container.view.bounds),
          NSStringFromCGRect(gWindow.bounds));
    {
        char buf[256];
        snprintf(buf, sizeof(buf), "adopt bounds=%.0fx%.0f window=%.0fx%.0f",
                 container.view.bounds.size.width, container.view.bounds.size.height,
                 gWindow.bounds.size.width, gWindow.bounds.size.height);
        TDSandboxLogAppend(buf);
    }
    // LC 的 dock 会把访客层 windowHostingView 塞进 keyWindow 的 rootVC.view.subviews.first，
    // 本仓沙盒容器在 fullScreenCover 里，那份 subviews.first 在封面之下 —— 访客画面因此
    // 不可见（owner 实测「只有 dock 没有内容」）。这里把它挪进覆盖窗口的容器。
    UIView *host = MultitaskDockManager.shared.windowHostingView;
    NSLog(@"[TD-Multitask] adopt: before superview=%@ frame=%@",
          host.superview ? NSStringFromClass(host.superview.class) : @"nil",
          NSStringFromCGRect(host.frame));
    host.frame = container.view.bounds;
    host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container.view addSubview:host];
    NSLog(@"[TD-Multitask] adopt: after superview=%@ subviews=%lu",
          host.superview ? NSStringFromClass(host.superview.class) : @"nil",
          (unsigned long)container.view.subviews.count);

    // dock 自己的 init 会把 windowHostingView 塞回 keyWindow.rootVC.view.subviews.first
    // （在 fullScreenCover 之下），所以在这里补两次延后搬迁，确保最终落在覆盖窗口里.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *c = [TDGuestOverlay guestHostController];
        UIView *h = MultitaskDockManager.shared.windowHostingView;
        if (c && h.superview != c.view) {
            h.frame = c.view.bounds;
            h.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [c.view addSubview:h];
            NSLog(@"[TD-Multitask] adopt(0.5s): re-homed to %@", NSStringFromClass(c.view.class));
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *c = [TDGuestOverlay guestHostController];
        UIView *h = MultitaskDockManager.shared.windowHostingView;
        if (c && h.superview != c.view) {
            h.frame = c.view.bounds;
            h.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [c.view addSubview:h];
            NSLog(@"[TD-Multitask] adopt(1.5s): re-homed to %@", NSStringFromClass(c.view.class));
        }
    });
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