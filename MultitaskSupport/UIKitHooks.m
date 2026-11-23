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
#include <math.h>


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

// Occlusion and the device's own bar are two different values and have to be
// transported as two. A legacy guest asks UIApplication.statusBarFrame for the
// device bar so it can lay its whole-view content underneath it. In a deck /
// multitask viewport the surface sits below the host's bar, so the intersection
// is legitimately empty while the reported rect still has to be the full bar
// (59pt on Dynamic Island phones). Baseline published only the intersection,
// so the guest received CGRectZero and started its content at y=0.
static const CFStringRef LCGuestGeometryChangedNotificationName = CFSTR("com.kdt.livecontainer.guestGeometry");
static NSString *const LCGuestPhysicalStatusBarHeightKey = @"LCGuestPhysicalStatusBarHeight";

// The device's bar, independent of where this viewport sits. FrontBoard
// reports a zero frame while the bar is hidden; the island still occupies that
// band, so the host window's top safe area is the measured fallback.
static CGFloat LCHostPhysicalStatusBarHeight(UIWindow *window, UIWindowScene *scene) {
    if (!scene) return 0;
    CGRect bar = scene.statusBarManager ? scene.statusBarManager.statusBarFrame : CGRectZero;
    if (!CGRectIsNull(bar) && !CGRectIsEmpty(bar) && CGRectGetHeight(bar) > 0) return CGRectGetHeight(bar);
    UIEdgeInsets periphery = window ? window.safeAreaInsets : UIEdgeInsetsZero;
    return periphery.top > 0 ? periphery.top : 0;
}

// LiveProcess runs the guest in its own extension process: it cannot see this
// scene's settings object, and this UIApplication is not visible there at all.
// The app-group defaults are shared by both processes -- the same channel the
// one-shot orientation override already uses -- and the Darwin notification
// tells the guest to drop its cached frame and re-read.
static void LCPublishGuestPhysicalStatusBar(CGFloat height) {
    if (height < 0) return;
    static CGFloat lastHeight = -1;
    if (lastHeight >= 0 && fabs(height - lastHeight) < 0.5) return;
    lastHeight = height;
    NSUserDefaults *shared = NSUserDefaults.lcSharedDefaults;
    if (shared) {
        [shared setObject:@(height) forKey:LCGuestPhysicalStatusBarHeightKey];
        [shared synchronize];
    }
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         LCGuestGeometryChangedNotificationName, NULL, NULL, YES);
}

// Rotation, bar visibility and window swaps change the physical height without
// a settings update for every hosted scene (a scene with no surface has no
// viewport to measure).
static void LCPublishGuestPhysicalStatusBarFromHostScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        UISceneActivationState state = windowScene.activationState;
        if (state != UISceneActivationStateForegroundActive && state != UISceneActivationStateForegroundInactive) continue;
        UIWindow *window = windowScene.keyWindow ?: windowScene.windows.firstObject;
        // 0 is a real answer (the bar is hidden in landscape). Publishing it
        // stops a guest from keeping the portrait height after rotation.
        LCPublishGuestPhysicalStatusBar(LCHostPhysicalStatusBarHeight(window, windowScene));
        return;
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
    UIWindowScene *scene = window.windowScene;
    UIStatusBarManager *manager = scene.statusBarManager;
    // Occlusion keeps its baseline semantics: only the part of the physical bar
    // that actually covers this viewport participates in content clearance.
    CGRect overlap = CGRectZero;
    if (window && !CGRectIsEmpty(bounds) && manager &&
        !window.hidden && window.alpha >= 0.01 && !manager.isStatusBarHidden) {
        CGRect bar = [viewport convertRect:manager.statusBarFrame fromCoordinateSpace:scene.coordinateSpace];
        CGRect intersection = CGRectIntersection(bounds, bar);
        if (!CGRectIsNull(intersection) && !CGRectIsEmpty(intersection)) {
            overlap = CGRectMake((intersection.origin.x - bounds.origin.x) / scale, (intersection.origin.y - bounds.origin.y) / scale,
                                 intersection.size.width / scale, intersection.size.height / scale);
        }
    }
    settings.statusBarAvoidanceFrame = overlap;

    CGFloat barHeight = LCHostPhysicalStatusBarHeight(window, scene);
    CGFloat guestHeight = (barHeight > 0 && scale > 0) ? barHeight / scale : 0;
    // UIKit reads this property back as the bar's own thickness. Baseline fed
    // it the occlusion height, which is zero whenever the surface is clear of
    // the bar -- exactly the multitask case.
    if ([settings respondsToSelector:@selector(setStatusBarHeight:)]) settings.statusBarHeight = guestHeight;
    // The transported copy stays in host points: each guest knows its own
    // scaleRatio only through its scene/logical width, so publishing a per-guest
    // scaled value here would make two windows at different 缩放 ratios overwrite
    // each other.
    LCPublishGuestPhysicalStatusBar(barHeight);
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
    // The transported bar height has to follow rotation, status-bar visibility
    // and key-window swaps even when no hosted surface is laid out.
    for (NSNotificationName name in @[UIApplicationDidChangeStatusBarFrameNotification,
                                      UIDeviceOrientationDidChangeNotification,
                                      UIWindowDidBecomeKeyNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            LCPublishGuestPhysicalStatusBarFromHostScene();
        }];
    }
    LCPublishGuestPhysicalStatusBarFromHostScene();
}
