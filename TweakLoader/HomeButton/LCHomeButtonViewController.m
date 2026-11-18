#import "LCHomeButtonViewController.h"
#import "LCHomeButtonPlacement.h"
#import "LCHomeButtonView.h"
#import <objc/message.h>

NSString *LCHomeButtonSetting(NSString *key);

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
// 侧边下滑时跟随手指的整屏快照.
@property (nonatomic, nullable) UIView *edgeSnapshot;
@property (nonatomic, weak, nullable) UIPanGestureRecognizer *edgeGesture;
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

    LCHomeButtonView *button = [[LCHomeButtonView alloc] initWithFrame:CGRectZero];
    [button addTarget:self action:@selector(buttonTouchedDown) forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(buttonPressed) forControlEvents:UIControlEventTouchUpInside];
    [button addTarget:self action:@selector(buttonLetGo) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(buttonDragged:)]];
    [self.view addSubview:button];
    [self addEdgeSwipeHandles];
    [self reloadSettings];
}

// 左右边缘各一条窄热区; 只在开启侧边下滑时存在, 不影响中间区域的触摸.
- (void)addEdgeSwipeHandles {
    if (self.view.subviews.count > 1) return;
    for (NSNumber *edge in @[@(UIRectEdgeLeft), @(UIRectEdgeRight)]) {
        UIView *handle = [[UIView alloc] initWithFrame:CGRectZero];
        handle.backgroundColor = UIColor.clearColor;
        handle.tag = edge.integerValue;
        // 系统边缘手势识别器 + 普通 pan 双保险；两个同时触发时由 edgeGesture 去重。
        UIScreenEdgePanGestureRecognizer *screenPan = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(edgePanned:)];
        screenPan.edges = edge.integerValue;
        screenPan.delegate = self;
        screenPan.cancelsTouchesInView = NO;
        screenPan.delaysTouchesBegan = NO;
        [handle addGestureRecognizer:screenPan];

        UIPanGestureRecognizer *plainPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(edgePanned:)];
        plainPan.delegate = self;
        plainPan.cancelsTouchesInView = NO;
        plainPan.delaysTouchesBegan = NO;
        [handle addGestureRecognizer:plainPan];
        [self.view insertSubview:handle belowSubview:self.button];
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    return self.edgeSwipeEnabled && !self.edgeSnapshot && !self.cover && !self.isDragging;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithOtherGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // 边缘热区在独立窗口里; 允许应用自身手势继续工作, 我们只在满足下滑阈值时接管.
    return YES;
}

- (void)edgePanned:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        if (self.edgeGesture && gesture != self.edgeGesture) return;
        self.edgeGesture = gesture;
        // 快照只是视觉反馈；拿不到应用窗口时也必须让返回动作生效。
        if (!self.edgeSnapshot) {
            UIWindow *appWindow = self.appWindow;
            UIView *snapshot = appWindow ? [appWindow snapshotViewAfterScreenUpdates:NO] : nil;
            if (snapshot) {
                snapshot.frame = [appWindow convertRect:appWindow.bounds toView:self.view];
                snapshot.userInteractionEnabled = NO;
                [self.view insertSubview:snapshot atIndex:0];
                self.edgeSnapshot = snapshot;
            }
        }
    }
    if (gesture != self.edgeGesture) return;

    if (gesture.state == UIGestureRecognizerStateCancelled || gesture.state == UIGestureRecognizerStateFailed) {
        [self finishEdgeSwipe:NO animated:YES];
        return;
    }
    if (gesture.state != UIGestureRecognizerStateBegan && gesture.state != UIGestureRecognizerStateChanged &&
        gesture.state != UIGestureRecognizerStateEnded) return;

    CGPoint translation = [gesture translationInView:self.view];
    CGFloat travel = MAX(0, translation.y);
    if (self.edgeSnapshot) {
        self.edgeSnapshot.transform = CGAffineTransformMakeTranslation(0, travel);
        self.edgeSnapshot.alpha = 1 - MIN(0.35, travel / MAX(1, self.view.bounds.size.height));
    }
    if (gesture.state == UIGestureRecognizerStateEnded) {
        BOOL dismiss = travel > 80 && translation.y > fabs(translation.x);
        if (!self.edgeSnapshot) {
            self.edgeGesture = nil;
            if (dismiss && self.edgeHandler) self.edgeHandler();
        } else {
            [self finishEdgeSwipe:dismiss animated:YES];
        }
    }
}

- (void)finishEdgeSwipe:(BOOL)dismiss animated:(BOOL)animated {
    UIView *snapshot = self.edgeSnapshot;
    self.edgeGesture = nil;
    if (!snapshot) return;
    if (!animated) {
        // Clear ownership first, so an interrupted completion cannot leave the app.
        self.edgeSnapshot = nil;
        [snapshot.layer removeAllAnimations];
        [snapshot removeFromSuperview];
        return;
    }
    CGFloat travel = MAX(snapshot.transform.ty, self.view.bounds.size.height * 0.3);
    __weak LCHomeButtonViewController *weakSelf = self;
    [UIView animateWithDuration:dismiss ? 0.3 : 0.25
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction |
                                (dismiss ? UIViewAnimationOptionCurveEaseIn : UIViewAnimationOptionCurveEaseOut)
                     animations:^{
        snapshot.transform = dismiss ? CGAffineTransformMakeTranslation(0, travel) : CGAffineTransformIdentity;
        snapshot.alpha = dismiss ? 0 : 1;
    } completion:^(BOOL finished) {
        [snapshot removeFromSuperview];
        LCHomeButtonViewController *controller = weakSelf;
        if (controller.edgeSnapshot != snapshot) return;
        controller.edgeSnapshot = nil;
        if (dismiss && finished && controller.edgeHandler) controller.edgeHandler();
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [self finishEdgeSwipe:NO animated:NO];
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
    self.buttonHidden = ![LCHomeButtonSetting(@"TDAssistiveTouchMode") isEqualToString:@"always"];
    self.edgeSwipeEnabled = [LCHomeButtonSetting(@"TDSideSwipeMode") isEqualToString:@"always"];
    self.button.hidden = self.buttonHidden;
    for (UIView *subview in self.view.subviews) {
        if (subview == self.button || subview == self.cover) continue;
        if (subview.tag == UIRectEdgeLeft || subview.tag == UIRectEdgeRight) {
            subview.hidden = !self.edgeSwipeEnabled;
        }
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
    for (UIView *subview in self.view.subviews) {
        if (subview == self.button || subview == self.cover) continue;
        if (subview.tag == UIRectEdgeLeft) {
            subview.frame = CGRectMake(0, 0, 24, self.view.bounds.size.height);
            subview.hidden = !self.edgeSwipeEnabled;
        } else if (subview.tag == UIRectEdgeRight) {
            subview.frame = CGRectMake(self.view.bounds.size.width - 24, 0, 24, self.view.bounds.size.height);
            subview.hidden = !self.edgeSwipeEnabled;
        }
    }
}

// Turning an iPad all the way round keeps the view's size, so it isn't laid
// out again on its own, but the first place moves to the other side.
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [self finishEdgeSwipe:NO animated:NO];
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
    if (self.pressHandler) {
        self.pressHandler();
    }
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
    __weak LCHomeButtonViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LCHomeButtonDimDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LCHomeButtonViewController *controller = weakSelf;
        if (!controller || controller.dimmingGeneration != generation || controller.isDragging || controller.button.isTracking) {
            return;
        }
        [UIView animateWithDuration:0.5
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            controller.button.alpha = LCHomeButtonDimmedAlpha;
        } completion:nil];
    });
}

#pragma mark Going back to zContainer

- (void)fadeOutWithCompletion:(void (^)(void))completion {
    [self finishEdgeSwipe:NO animated:NO];
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
