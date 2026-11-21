#import "LCHomeButtonViewController.h"
#import "LCHomeButtonPlacement.h"
#import "LCHomeButtonView.h"
#import <objc/message.h>

NSString *LCHomeButtonSetting(NSString *key);
NSNumber *LCHomeButtonNumberSetting(NSString *key);
BOOL LCHomeButtonBoolSetting(NSString *key, BOOL fallback);

// The space between the button and the edges of the screen's safe area.
static const CGFloat LCHomeButtonEdgeMargin = 6;
// How long the button stays bright after a touch before it dims, and how
// bright it is then, like AssistiveTouch's idle opacity.
static const NSTimeInterval LCHomeButtonDimDelay = 3;
static const CGFloat LCHomeButtonDimmedAlpha = 0.4;
// How far a flung button carries on, in seconds of its speed when let go.
static const CGFloat LCHomeButtonFlingCarry = 0.12;

@interface LCHomeButtonViewController () <UIGestureRecognizerDelegate>
@property (nonatomic) LCHomeButtonView *button;
// Where the button was moved to, or nil while it rests in its first place,
// which follows an iPad as it's turned.
@property (nonatomic, nullable) LCHomeButtonPlacement *placement;
// The black view over the app while zContainer opens.
@property (nonatomic, nullable) UIView *cover;
@property (nonatomic) BOOL isDragging;
// Where the finger holds the button, from the button's center.
@property (nonatomic) CGPoint dragOffset;
// Counts touches, so a dimming planned before the last touch doesn't happen.
@property (nonatomic) NSUInteger dimmingGeneration;
// Idle dimming is optional and its final opacity is user-configurable.
@property (nonatomic) BOOL dimEnabled;
@property (nonatomic) CGFloat dimAlpha;
@property (nonatomic) UIScreenEdgePanGestureRecognizer *leftEdgePan;
@property (nonatomic) UIScreenEdgePanGestureRecognizer *rightEdgePan;
@property (nonatomic) BOOL edgeSwipeFired;
// Native single-tap recognition waits for the same double-tap recognizer to
// fail. There is no shorter independent timer that can leave the app first.
- (nullable UIWindow *)appWindow;
@end

@implementation LCHomeButtonViewController

- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    view.backgroundColor = UIColor.clearColor;
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.placement = [LCHomeButtonPlacement firstPlacementForInterfaceOrientation:UIApplication.sharedApplication.statusBarOrientation];

    self.button = [[LCHomeButtonView alloc] initWithFrame:CGRectZero];
    LCHomeButtonView *button = self.button;
    // The view may not get a valid layout pass before the first touch. Give the
    // button its real size and right-edge default immediately instead of
    // leaving it at CGRectZero in the status bar.
    CGPoint defaultCenter = [self.placement centerInArea:self.restingArea];
    button.frame = CGRectMake(defaultCenter.x - LCHomeButtonView.diameter / 2,
                              defaultCenter.y - LCHomeButtonView.diameter / 2,
                              LCHomeButtonView.diameter,
                              LCHomeButtonView.diameter);
    [button addTarget:self action:@selector(buttonTouchedDown) forControlEvents:UIControlEventTouchDown];
    UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(buttonPressed)];
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(buttonDoubleTapped)];
    doubleTap.numberOfTapsRequired = 2;
    [singleTap requireGestureRecognizerToFail:doubleTap];
    [button addGestureRecognizer:singleTap];
    [button addGestureRecognizer:doubleTap];
    [button addTarget:self action:@selector(buttonLetGo) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(buttonDragged:)]];
    [self.view addSubview:button];
    self.leftEdgePan = [self edgePanWithEdge:UIRectEdgeLeft];
    self.rightEdgePan = [self edgePanWithEdge:UIRectEdgeRight];
    [self reloadSettings];
}

- (UIScreenEdgePanGestureRecognizer *)edgePanWithEdge:(UIRectEdge)edge {
    UIScreenEdgePanGestureRecognizer *pan = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(edgePanned:)];
    pan.edges = edge;
    pan.cancelsTouchesInView = NO;
    pan.delegate = self;
    return pan;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if ([gestureRecognizer isKindOfClass:UIScreenEdgePanGestureRecognizer.class]) {
        return self.edgeSwipeEnabled && self.edgeHandler != nil;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)edgePanned:(UIScreenEdgePanGestureRecognizer *)pan {
    if (!self.edgeSwipeEnabled) return;
    if (pan.state == UIGestureRecognizerStateBegan) self.edgeSwipeFired = NO;
    if (pan.state != UIGestureRecognizerStateChanged && pan.state != UIGestureRecognizerStateEnded) return;
    CGPoint travel = [pan translationInView:self.view];
    if (!self.edgeSwipeFired && travel.y > 80 && travel.y > fabs(travel.x)) {
        self.edgeSwipeFired = YES;
        if (self.edgeHandler) self.edgeHandler();
    }
}




- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self reloadSettings];
    self.placement = [LCHomeButtonPlacement firstPlacementForInterfaceOrientation:self.currentInterfaceOrientation];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    [self dimSoon];
}

- (void)reloadSettings {
    NSString *mode = LCHomeButtonSetting(@"TDAssistiveTouchMode");
    BOOL always = [mode isEqualToString:@"always"];
    BOOL legacyShow = getenv("TD_SHOW_HOME_BUTTON_IN_APPS") && atoi(getenv("TD_SHOW_HOME_BUTTON_IN_APPS")) == 1;
    // “保持现状”沿用原有主屏按键开关；只有“始终显示”才无视原有开关。
    self.buttonHidden = always ? NO : !legacyShow;
    self.edgeSwipeEnabled = [LCHomeButtonSetting(@"TDSideSwipeMode") isEqualToString:@"always"];
    BOOL dimEnabled = LCHomeButtonBoolSetting(@"TDAssistiveTouchIdleDim", YES);
    NSNumber *alpha = LCHomeButtonNumberSetting(@"TDAssistiveTouchIdleAlpha");
    CGFloat dimAlpha = alpha ? MAX(0.15, MIN(1.0, alpha.doubleValue)) : LCHomeButtonDimmedAlpha;
    BOOL dimChanged = self.dimEnabled != dimEnabled || self.dimAlpha != dimAlpha;
    self.dimEnabled = dimEnabled;
    self.dimAlpha = dimAlpha;
    self.button.hidden = self.buttonHidden;
    // A clear handle in the overlay still wins hit testing and swallows every
    // guest touch in its strip. Observe the real app window instead, so taps
    // and nonmatching swipes continue to reach the guest's own views.
    UIWindow *appWindow = self.appWindow;
    if (self.leftEdgePan.view != appWindow) {
        [self.leftEdgePan.view removeGestureRecognizer:self.leftEdgePan];
        [appWindow addGestureRecognizer:self.leftEdgePan];
    }
    if (self.rightEdgePan.view != appWindow) {
        [self.rightEdgePan.view removeGestureRecognizer:self.rightEdgePan];
        [appWindow addGestureRecognizer:self.rightEdgePan];
    }
    self.leftEdgePan.enabled = self.edgeSwipeEnabled;
    self.rightEdgePan.enabled = self.edgeSwipeEnabled;
    if (dimChanged) {
        [self brighten];
        [self dimSoon];
    }
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

- (void)resetPlacementToDefault {
    if (!self.isViewLoaded) return;
    self.placement = [LCHomeButtonPlacement firstPlacementForInterfaceOrientation:self.currentInterfaceOrientation];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 窗口几何还没就绪时不要布局；否则按钮会被算到 (0,0) 并卡在状态栏。
    if (CGRectIsEmpty(self.view.bounds) || CGRectIsEmpty(self.view.frame) ||
        CGRectGetWidth(self.view.bounds) < 100 || CGRectGetHeight(self.view.bounds) < 100) {
        return;
    }
    if (!self.isDragging) {
        // Keep the button's own size fixed even if a stale zero frame survived
        // from a previous layout pass.
        self.button.bounds = CGRectMake(0, 0, LCHomeButtonView.diameter, LCHomeButtonView.diameter);
        CGRect area = self.restingArea;
        CGPoint center = [self.currentPlacement centerInArea:area];
        // A near-zero center is just as broken as (0,0): the button lands under
        // the status bar and cannot be tapped. Reset to the default right edge.
        if (!isfinite(center.x) || !isfinite(center.y) ||
            center.x < 1 || center.y < 1 ||
            center.x > CGRectGetMaxX(self.view.bounds) - 1 ||
            center.y > CGRectGetMaxY(self.view.bounds) - 1) {
            self.placement = [LCHomeButtonPlacement firstPlacementForInterfaceOrientation:self.currentInterfaceOrientation];
            center = [self.currentPlacement centerInArea:area];
        }
        self.button.center = center;
    }
}

// Turning an iPad all the way round keeps the view's size, so it isn't laid
// out again on its own, but the first place moves to the other side.
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [self.view setNeedsLayout];
    }];
}

// Where the button rests: where it was moved to, or else its first place,
// which on an iPad is beside the iPad's Home button as it's turned now.
- (LCHomeButtonPlacement *)currentPlacement {
    return self.placement ?: [LCHomeButtonPlacement firstPlacementForInterfaceOrientation:self.currentInterfaceOrientation];
}

// Which way the screen shows the app now.
- (UIInterfaceOrientation)currentInterfaceOrientation {
    UIWindowScene *scene = self.view.window.windowScene;
    if (!scene) {
        return UIInterfaceOrientationPortrait;
    }
    if (@available(iOS 16.0, *)) {
        return scene.effectiveGeometry.interfaceOrientation;
    }
    return scene.interfaceOrientation;
}

// The area the button's center rests in: the safe area, less the button's
// radius and a small margin.
- (CGRect)restingArea {
    CGRect safeArea = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    CGFloat inset = LCHomeButtonView.diameter / 2 + LCHomeButtonEdgeMargin;
    CGRect area = CGRectInset(safeArea, inset, inset);
    if (CGRectIsNull(area) || CGRectIsEmpty(area)) {
        return CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    return area;
}

#pragma mark Touches

- (void)buttonTouchedDown {
    [self brighten];
}

- (void)buttonLetGo {
    [self dimSoon];
}

- (void)buttonPressed {
    [self dimSoon];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    if (self.pressHandler) self.pressHandler();
}

- (void)buttonDoubleTapped {
    [self dimSoon];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    if (self.doubleTapHandler) self.doubleTapHandler();
}

// Follows the finger, then lets the button settle against the edge nearest
// to where it was going when let go.
- (void)buttonDragged:(UIPanGestureRecognizer *)pan {
    CGPoint finger = [pan locationInView:self.view];
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            self.isDragging = YES;
            self.dragOffset = CGPointMake(self.button.center.x - finger.x, self.button.center.y - finger.y);
            [self brighten];
            break;
        case UIGestureRecognizerStateChanged: {
            CGFloat radius = LCHomeButtonView.diameter / 2;
            CGRect bounds = CGRectInset(self.view.bounds, radius, radius);
            CGFloat x = finger.x + self.dragOffset.x;
            CGFloat y = finger.y + self.dragOffset.y;
            self.button.center = CGPointMake(MIN(MAX(x, CGRectGetMinX(bounds)), CGRectGetMaxX(bounds)),
                                             MIN(MAX(y, CGRectGetMinY(bounds)), CGRectGetMaxY(bounds)));
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            self.isDragging = NO;
            CGPoint velocity = [pan velocityInView:self.view];
            CGPoint heading = CGPointMake(self.button.center.x + velocity.x * LCHomeButtonFlingCarry,
                                          self.button.center.y + velocity.y * LCHomeButtonFlingCarry);
            CGRect area = self.restingArea;
            self.placement = [LCHomeButtonPlacement placementNearestToPoint:heading inArea:area];
            [self.placement save];
            CGPoint target = [self.placement centerInArea:area];
            [UIView animateWithDuration:0.45
                                  delay:0
                 usingSpringWithDamping:0.78
                  initialSpringVelocity:0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                             animations:^{
                self.button.center = target;
            } completion:nil];
            [self dimSoon];
            break;
        }
        default:
            break;
    }
}

#pragma mark Dimming

- (void)brighten {
    self.dimmingGeneration += 1;
    [UIView animateWithDuration:0.15
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.button.alpha = 1;
    } completion:nil];
}

- (void)dimSoon {
    NSUInteger generation = ++self.dimmingGeneration;
    if (!self.dimEnabled) {
        self.button.alpha = 1;
        return;
    }
    __weak LCHomeButtonViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LCHomeButtonDimDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LCHomeButtonViewController *controller = weakSelf;
        if (!controller || !controller.dimEnabled || controller.dimmingGeneration != generation || controller.isDragging || controller.button.isTracking) {
            return;
        }
        [UIView animateWithDuration:0.5
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            controller.button.alpha = controller.dimAlpha;
        } completion:nil];
    });
}

#pragma mark Going back to zContainer

- (void)fadeOutWithCompletion:(void (^)(void))completion {
    [self.cover removeFromSuperview];
    UIView *cover = [[UIView alloc] initWithFrame:self.view.bounds];
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cover.backgroundColor = UIColor.blackColor;
    cover.alpha = 0;
    [self.view addSubview:cover];
    self.cover = cover;
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        cover.alpha = 1;
    } completion:^(BOOL finished) {
        completion();
    }];
}

- (void)fadeBackIn {
    UIView *cover = self.cover;
    self.cover = nil;
    [UIView animateWithDuration:0.25 animations:^{
        cover.alpha = 0;
    } completion:^(BOOL finished) {
        [cover removeFromSuperview];
    }];
    [self dimSoon];
}

#pragma mark Leaving the screen to the app

// Choose a visible app window in this button's scene, never the button window
// or a key window belonging to a different scene.
- (nullable UIWindow *)appWindow {
    UIWindow *ownWindow = self.viewIfLoaded.window;
    UIWindow *appWindow = nil;
    for (UIWindow *window in ownWindow.windowScene.windows) {
        if (window == ownWindow || window.hidden || window.alpha <= 0 || !window.rootViewController || CGRectIsEmpty(window.bounds) || window.windowLevel > UIWindowLevelNormal) {
            continue;
        }
        if (window.isKeyWindow) {
            appWindow = window;
            break;
        }
        if (!appWindow && window.windowLevel <= UIWindowLevelNormal) {
            appWindow = window;
        }
    }
    return appWindow;
}

// The app's root controller, or the one it presents over everything.
- (nullable UIViewController *)appViewController {
    UIViewController *controller = self.appWindow.rootViewController;
    while (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    return controller == self ? nil : controller;
}

// The view controller that decides the app's orientations, which UIKit finds
// with a private method of the root view controller when it has it.
- (nullable UIViewController *)appOrientationViewController {
    UIWindow *appWindow = self.appWindow;
    UIViewController *controller = appWindow.rootViewController;
    if (!controller) return self.appViewController;
    SEL decider = NSSelectorFromString(@"_viewControllerForSupportedInterfaceOrientations");
    if ([controller respondsToSelector:decider]) {
        id found = ((id (*)(id, SEL))objc_msgSend)(controller, decider);
        if ([found isKindOfClass:UIViewController.class]) {
            controller = found;
        }
    }
    return controller == self ? nil : controller;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIInterfaceOrientationMask orientations = 0;
    @try {
        orientations = self.appOrientationViewController.supportedInterfaceOrientations;
    } @catch (NSException *exception) {
        orientations = 0;
    }
    // UIKit rejects an empty set of orientations.
    return orientations ?: UIInterfaceOrientationMaskAll;
}

- (UIViewController *)childViewControllerForStatusBarStyle {
    return self.appViewController;
}

- (UIViewController *)childViewControllerForStatusBarHidden {
    return self.appViewController;
}

- (UIViewController *)childViewControllerForHomeIndicatorAutoHidden {
    return self.appViewController;
}

- (UIViewController *)childViewControllerForScreenEdgesDeferringSystemGestures {
    return self.appViewController;
}

@end
