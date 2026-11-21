//
//  UIKitHooks.m
//  LiveContainer
//
//  Created by Duy Tran on 25/6/26.
//
@import ObjectiveC;
#import "utils.h"
#import "UIKitPrivate+MultitaskSupport.h"
#import "AppSceneViewController.h"


UIEdgeInsets LCUIEdgeInsetsRotateToOrientation(UIEdgeInsets insets, UIInterfaceOrientation orientation) {
    switch(orientation) {
        case UIInterfaceOrientationLandscapeLeft:
            return UIEdgeInsetsMake(insets.left, insets.bottom, insets.right, insets.top);
        case UIInterfaceOrientationLandscapeRight:
            return UIEdgeInsetsMake(insets.right, insets.top, insets.left, insets.bottom);
        case UIInterfaceOrientationPortraitUpsideDown:
            return UIEdgeInsetsMake(insets.bottom, insets.right, insets.top, insets.left);
        default:
            return insets;
    }
}

// The viewport is the actual remote surface (so coordinate conversion also
// accounts for its scale), not the application's key window or screen. The
// container contributes only its explicitly reserved controls; inherited
// UIView safe areas can be stale after a sibling-host/split transition. The
// window supplies the physical cutouts, intersected without double clearance.
UIEdgeInsets LCGuestSceneSafeAreaInsets(UIView *viewport, UIView *container, UIEdgeInsets additionalInsets) {
    UIWindow *window = viewport.window;
    CGRect bounds = viewport.bounds;
    if (!window || container.window != window || CGRectIsEmpty(bounds)) {
        return UIEdgeInsetsZero;
    }
    CGRect displaySafe = [viewport convertRect:UIEdgeInsetsInsetRect(window.bounds, window.safeAreaInsets) fromView:window];
    UIEdgeInsets controls = additionalInsets;
    CGRect contentSafe = [viewport convertRect:UIEdgeInsetsInsetRect(container.bounds, controls) fromView:container];
    CGFloat top = MIN(MAX(MAX(CGRectGetMinY(displaySafe), CGRectGetMinY(contentSafe)) - CGRectGetMinY(bounds), 0), bounds.size.height);
    CGFloat left = MIN(MAX(MAX(CGRectGetMinX(displaySafe), CGRectGetMinX(contentSafe)) - CGRectGetMinX(bounds), 0), bounds.size.width);
    CGFloat bottom = MIN(MAX(CGRectGetMaxY(bounds) - MIN(CGRectGetMaxY(displaySafe), CGRectGetMaxY(contentSafe)), 0), bounds.size.height - top);
    CGFloat right = MIN(MAX(CGRectGetMaxX(bounds) - MIN(CGRectGetMaxX(displaySafe), CGRectGetMaxX(contentSafe)), 0), bounds.size.width - left);
    return UIEdgeInsetsMake(top, left, bottom, right);
}

void LCApplyGuestSceneSafeAreaInsets(UIMutableApplicationSceneSettings *settings, UIEdgeInsets insets) {
    UIEdgeInsets portrait = LCUIEdgeInsetsRotateToOrientation(insets, settings.interfaceOrientation);
    settings.peripheryInsets = insets;
    settings.safeAreaInsetsPortrait = portrait;
    settings.safeAreaInsetsPortraitUpsideDown = UIEdgeInsetsMake(portrait.bottom, portrait.right, portrait.top, portrait.left);
    settings.safeAreaInsetsLandscapeLeft = UIEdgeInsetsMake(portrait.right, portrait.top, portrait.left, portrait.bottom);
    settings.safeAreaInsetsLandscapeRight = UIEdgeInsetsMake(portrait.left, portrait.bottom, portrait.right, portrait.top);
    if (@available(iOS 19.0, *)) {
        settings.safeAreaEdgeInsets = insets;
    }
}

// A disabled virtual status bar prevents a second renderer; it does not mean
// the host's real bar cannot cover this viewport. FrontBoard carries that
// separate occlusion rect to legacy guests without treating a notch inset or
// a window-control strip as a status bar.
void LCApplyGuestSceneStatusBarFrame(UIMutableApplicationSceneSettings *settings, UIView *viewport, CGFloat scale) {
    if (![settings statusBarDisabled]) return;
    UIWindow *window = viewport.window;
    CGRect bounds = viewport.bounds;
    if (!window || CGRectIsEmpty(bounds)) return;
    UIWindowScene *scene = window.windowScene;
    UIStatusBarManager *manager = scene.statusBarManager;
    if (!manager) return;
    CGRect overlap = CGRectZero;
    if (!window.hidden && window.alpha >= 0.01 && !manager.isStatusBarHidden) {
        CGRect bar = [viewport convertRect:manager.statusBarFrame fromCoordinateSpace:scene.coordinateSpace];
        CGRect intersection = CGRectIntersection(bounds, bar);
        if (!CGRectIsNull(intersection) && !CGRectIsEmpty(intersection)) {
            overlap = CGRectMake((intersection.origin.x - bounds.origin.x) / scale, (intersection.origin.y - bounds.origin.y) / scale,
                                 intersection.size.width / scale, intersection.size.height / scale);
        }
    }
    settings.statusBarAvoidanceFrame = overlap;
    if ([settings respondsToSelector:@selector(setStatusBarHeight:)]) settings.statusBarHeight = CGRectGetHeight(overlap);
}

// Fix _UIPrototypingMenuSlider not continually updating its value on iOS 17+
API_AVAILABLE(ios(17.0))
@implementation _UIFluidSliderInteraction(Hook)
- (NSInteger)_state {
    return 2;
}
@end

@interface FBScene(hooks)
- (void)hook__performUpdateWithoutActivation:(void (^)(UIMutableApplicationSceneSettings *settings, FBSSceneTransitionContext *context))updateBlock;
@end

/// Only zContainer's own hosted app scenes get geometry overrides. Other
/// FrontBoard scenes (including system sheets) retain UIKit's settings.
API_AVAILABLE(ios(17.0))
void hook_FBScene_performUpdateWithoutActivation(FBScene* self, SEL _cmd, void (^updateBlock)(UIMutableApplicationSceneSettings *, FBSSceneTransitionContext *)) {
    _UISceneHostingController *controller = self.delegate;
    if (![controller isKindOfClass:PrivClass(_UISceneHostingController)]) {
        [self hook__performUpdateWithoutActivation:updateBlock];
        return;
    }
    UIViewController *hostedVC = controller.sceneViewController;
    AppSceneViewController *owner = nil;
    for (UIViewController *parent = hostedVC.parentViewController; parent; parent = parent.parentViewController) {
        if ([parent isKindOfClass:AppSceneViewController.class] && ((AppSceneViewController *)parent).presenter.scene == self) {
            owner = (AppSceneViewController *)parent;
            break;
        }
    }
    UIView *view = hostedVC.viewIfLoaded;
    if (!owner || !view.window) {
        // Initial configuration runs before the surface is attached. Preserve
        // its explicitly supplied insets instead of overwriting them with zero.
        [self hook__performUpdateWithoutActivation:updateBlock];
        return;
    }
    id wrappedBlock = ^(UIMutableApplicationSceneSettings *settings, FBSSceneTransitionContext *context) {
        if (updateBlock) updateBlock(settings, context);
        UIView *container = owner.shouldIgnoreSceneUpdates ? view.superview : owner.view;
        if (container.window != view.window || CGRectIsEmpty(view.bounds)) return;
        UIEdgeInsets additional = owner.shouldIgnoreSceneUpdates ? container.safeAreaInsets : owner.additionalSafeAreaInsets;
        LCApplyGuestSceneSafeAreaInsets(settings, LCGuestSceneSafeAreaInsets(view, container, additional));
        LCApplyGuestSceneStatusBarFrame(settings, view, 1);
    };
    [self hook__performUpdateWithoutActivation:wrappedBlock];
}

void UIKitFixesInit(void) {
    if (@available(iOS 17.0, *)) {
        Class FBSceneClass = PrivClass(FBScene);
        class_addMethod(FBSceneClass, @selector(hook__performUpdateWithoutActivation:), (IMP)hook_FBScene_performUpdateWithoutActivation, "v@:@");
        swizzle(FBSceneClass, @selector(_performUpdateWithoutActivation:), @selector(hook__performUpdateWithoutActivation:));
    }
}
