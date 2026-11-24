//
//  LCStatusBarManager.m
//  LiveContainer
//
//  Created by Duy Tran on 20/2/26.
//
#import "LCStatusBarManager.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "VirtualWindowsHostView.h"

@implementation LCStatusBarManager
- (void)handleTapAction:(UIAction *)action {
    AppSceneViewController *native = self.nativeWindowViewController;
    UIView *view = native.viewIfLoaded;
    if (native.isAppRunning && view.window && !view.window.hidden && !view.hidden && view.alpha >= 0.01 && view.window.windowScene.statusBarManager == self) {
        [native handleStatusBarTapAction:action];
        return;
    }
    VirtualWindowsHostView *host = MultitaskDockManager.shared.windowHostingView;
    BOOL handledByVirtualWindow = host.window.windowScene.statusBarManager == self && [host handleStatusBarTapAction:action];
    if(!handledByVirtualWindow) {
        [super handleTapAction:action];
    }
}
@end

@implementation UIApplication(LiveContainer)
+ (Class)_statusBarManagerClass {
    if (@available(iOS 16.0, *)) {
        return LCStatusBarManager.class;
    } else {
        return UIStatusBarManager.class;
    }
}
@end
