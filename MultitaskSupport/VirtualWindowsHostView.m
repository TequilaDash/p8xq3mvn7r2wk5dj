//
//  VirtualWindowsHostView.m
//  LiveContainer
//
//  Created by Duy Tran on 22/2/26.
//
#import "DecoratedAppSceneViewController.h"
#import "VirtualWindowsHostView.h"
#import "LCWindowSnapManager.h"

NSNotificationName const LCVirtualWindowsTouchedOutsideNotification = @"LCVirtualWindowsTouchedOutsideNotification";

@implementation VirtualWindowsHostView {
    /// The size the windows were last laid out for.
    CGSize _laidOutSize;
    UIEdgeInsets _laidOutSafeAreaInsets;
}
- (instancetype)init {
    // MultitaskDockManager sizes it to the main window's root view when it puts
    // it there, above the Home Screen. Any connected scene could come first
    // here, which on iPad may not be the main window's, or may have no window
    // at all.
    self = [super initWithFrame:CGRectZero];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.shouldForwardTapAction = YES;
    return self;
}
- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    // Cutout/status-bar changes can leave the viewport size unchanged. The
    // remote scenes still need the new edge clearance in that case.
    UIEdgeInsets insets = self.window ? LCGuestSceneSafeAreaInsets(self, self, UIEdgeInsetsZero) : UIEdgeInsetsZero;
    if (CGSizeEqualToSize(self.bounds.size, _laidOutSize) && UIEdgeInsetsEqualToEdgeInsets(insets, _laidOutSafeAreaInsets)) {
        return;
    }
    _laidOutSize = self.bounds.size;
    _laidOutSafeAreaInsets = insets;
    [LCWindowSnapManager.shared layoutInView:self];
    for (UIView *view in self.subviews) {
        DecoratedAppSceneViewController *window = (id)view._viewDelegate;
        if ([window isKindOfClass:DecoratedAppSceneViewController.class]) {
            if (window.isStashed) [window restash];
            if (window.appSceneVC.presenter) [window.appSceneVC updateFrameWithSettingsBlock:nil];
        }
    }
}

- (void)bringSubviewToFront:(UIView *)view {
    [self raiseSubview:view];
    // A window brought forward from the multitask dock comes back out of the
    // side it's tucked into.
    DecoratedAppSceneViewController *window = (id)view._viewDelegate;
    if ([window isKindOfClass:DecoratedAppSceneViewController.class] && window.isStashed) {
        [window unstashAnimated:YES];
    }
}

- (void)raiseSubview:(UIView *)view {
    [super bringSubviewToFront:view];
    [LCWindowSnapManager.shared keepDividerOnTopInView:self];
}

/// A window that opens goes under the divider between snapped windows.
- (void)didAddSubview:(UIView *)subview {
    [super didAddSubview:subview];
    [LCWindowSnapManager.shared keepDividerOnTopInView:self];
}

- (BOOL)handleStatusBarTapAction:(UIAction *)action {
    if (!self.window || self.window.hidden || self.hidden || self.alpha < 0.01) return NO;
    // On iPad, only after a touch on a window: the Home Screen may be under
    // the status bar. On iPhone a window there covers it, and touches on its
    // app go to the app, past this view, which can't count them.
    if(!self.shouldForwardTapAction && !LCWindowSnapManager.usesPhoneLayout) return NO;
    // The frontmost window showing gets it, past the divider between snapped
    // windows and the black behind an iPhone's split screen. On iPhone, the
    // one under the status bar: the split screen's top half.
    DecoratedAppSceneViewController *target = nil;
    for (UIView *view in self.subviews.reverseObjectEnumerator) {
        DecoratedAppSceneViewController *window = (id)view._viewDelegate;
        if (view.hidden || view.alpha < 0.01 || ![window isKindOfClass:DecoratedAppSceneViewController.class] || window.isStashed) {
            continue;
        }
        if (LCWindowSnapManager.usesPhoneLayout && CGRectGetMinY(view.frame) >= 1) {
            continue;
        }
        target = window;
        break;
    }
    if (!target) {
        return NO;
    }
    if (![target revealWindowControlsForStatusBarTap:action]) {
        [target.appSceneVC handleStatusBarTapAction:action];
    }
    return YES;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView* hitView = [super hitTest:point withEvent:event];
    if(hitView == self) {
        self.shouldForwardTapAction = NO;
        if (event.type == UIEventTypeTouches) {
            [NSNotificationCenter.defaultCenter postNotificationName:LCVirtualWindowsTouchedOutsideNotification object:self];
        }
        return nil;
    } else {
        self.shouldForwardTapAction = YES;
        return hitView;
    }
}
@end
