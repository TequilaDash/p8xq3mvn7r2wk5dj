#import "LCHomeButtonController.h"
#import "LCAppDeparture.h"
#import "LCHomeButtonViewController.h"
#import "LCHomeButtonWindow.h"
#import "LCSharedUtils.h"
#import <objc/message.h>
#import "../../LiveContainer/utils.h"

// How long the app gets to finish what it does on entering the background,
// such as saving, before zContainer opens and the app's process ends.
static const NSTimeInterval LCHomeButtonSaveTime = 0.3;
// How long to wait for zContainer to open before giving the app back.
static const NSTimeInterval LCHomeButtonLeaveTimeout = 4;

// scene.coordinateSpace.bounds 在场景刚激活时可能是零/极小值；用它建窗会把
// 按钮算到 (0,0)。退化到主屏幕边界，保证窗口始终是一整屏。
static CGRect LCHomeSceneBounds(UIWindowScene *scene) {
    CGRect bounds = scene.coordinateSpace.bounds;
    if (CGRectIsEmpty(bounds) || CGRectGetWidth(bounds) < 200 || CGRectGetHeight(bounds) < 200) {
        bounds = UIScreen.mainScreen.bounds;
    }
    return bounds;
}


static id LCHomeButtonSettingObject(NSString *key) {
    Class sharedUtils = NSClassFromString(@"LCSharedUtils");
    NSString *groupID = nil;
    if ([sharedUtils respondsToSelector:@selector(appGroupID)]) {
        groupID = ((NSString *(*)(id, SEL))objc_msgSend)(sharedUtils, @selector(appGroupID));
    }
    NSUserDefaults *shared = groupID ? [[NSUserDefaults alloc] initWithSuiteName:groupID] : nil;
    // 宿主刚改完设置时，跨进程 suite 可能还留在旧缓存里。
    if (shared) [shared synchronize];
    id value = shared ? [shared objectForKey:key] : nil;
    if (value != nil) return value;
    // Suite may be unavailable or a pre-hook redirected it; the shared
    // defaults singleton is what iManager itself writes and reads.
    return [NSUserDefaults.lcSharedDefaults objectForKey:key];
}

NSString *LCHomeButtonSetting(NSString *key) {
    id value = LCHomeButtonSettingObject(key);
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return nil;
}

NSNumber *LCHomeButtonNumberSetting(NSString *key) {
    id value = LCHomeButtonSettingObject(key);
    if ([value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSString.class]) return @([value doubleValue]);
    return nil;
}

BOOL LCHomeButtonBoolSetting(NSString *key, BOOL fallback) {
    NSNumber *value = LCHomeButtonNumberSetting(key);
    return value ? value.boolValue : fallback;
}

@interface LCHomeButtonController ()
@property (nonatomic, nullable) LCHomeButtonWindow *window;
@property (nonatomic, nullable) LCHomeButtonViewController *buttonController;
- (void)applyGeometry:(CGRect)bounds inScene:(UIWindowScene *)scene resetPlacement:(BOOL)reset;
- (void)scheduleGeometryCheckInScene:(UIWindowScene *)scene;
- (void)showInActiveScenes;
@property (nonatomic) LCAppDeparture *departure;
@property (nonatomic) BOOL isLeaving;
@property (nonatomic) BOOL started;
@property (nonatomic) NSUInteger showAttempts;
@property (nonatomic, weak, nullable) UITouch *globalEdgeTouch;
@property (nonatomic) CGPoint globalEdgeStart;
@property (nonatomic) BOOL globalEdgeFired;
// Caches the setting between touch events; refreshed when a screen becomes
// active or the overlay is shown, so edge detection doesn't reopen a suite
// and synchronize for every touch.
@property (nonatomic, copy) NSString *sideSwipeSetting;
@end

@implementation LCHomeButtonController

+ (LCHomeButtonController *)sharedController {
    static LCHomeButtonController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        controller = [[LCHomeButtonController alloc] init];
    });
    return controller;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _departure = [[LCAppDeparture alloc] init];
    }
    return self;
}

- (void)start {
    if (self.started) {
        return;
    }
    self.started = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(sceneDidActivate:) name:UISceneDidActivateNotification object:nil];
    [center addObserver:self selector:@selector(windowDidBecomeVisible:) name:UIWindowDidBecomeVisibleNotification object:nil];
    // TweakLoader can be injected after the app's first scene is already active
    // (classic launches, hot reload). Notifications alone then never fire.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self showInActiveScenes];
    });
}

- (void)showInActiveScenes {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || ![self isOwnScreen:(UIWindowScene *)scene]) {
            continue;
        }
        if (scene.activationState == UISceneActivationStateForegroundActive ||
            scene.activationState == UISceneActivationStateForegroundInactive) {
            [self showSoonInScene:(UIWindowScene *)scene];
        }
    }
}

// The button moves to the screen the person is using.
- (void)sceneDidActivate:(NSNotification *)notification {
    if (![notification.object isKindOfClass:UIWindowScene.class]) return;
    UIWindowScene *scene = notification.object;
    if (![self isOwnScreen:scene]) return;
    [self.buttonController reloadSettings];
    [self refreshSideSwipeSetting];
    if (self.window.windowScene == scene) {
        [self applyGeometry:LCHomeSceneBounds(scene) inScene:scene resetPlacement:NO];
    }
    [self showSoonInScene:scene];
}

// Whether a scene is on the iPhone's or iPad's own screen, rather than an
// external display an app shows video or slides on, where the button would
// leave the iPhone with no way back to zContainer.
- (BOOL)isOwnScreen:(UIWindowScene *)scene {
    return [scene.session.role isEqualToString:UIWindowSceneSessionRoleApplication];
}

// Screens often come up before the app has put its window on them, so the
// button waits for the app's first window before it shows.
- (void)windowDidBecomeVisible:(NSNotification *)notification {
    UIWindow *window = notification.object;
    if (![window isKindOfClass:UIWindow.class] || window == self.window) {
        return;
    }
    UIWindowScene *scene = window.windowScene;
    if (scene && [self isOwnScreen:scene] &&
        scene.activationState != UISceneActivationStateUnattached &&
        self.window.windowScene != scene) {
        [self showSoonInScene:scene];
    }
}

// Shows the button once the app is done with the change it is making to its
// windows, rather than in the middle of it.
- (void)showSoonInScene:(UIWindowScene *)scene {
    __weak LCHomeButtonController *weakSelf = self;
    __weak UIWindowScene *weakScene = scene;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *laterScene = weakScene;
        if (laterScene) {
            [weakSelf showInScene:laterScene];
        }
    });
}

// Whether the app has put a window with content on the screen. The button's
// window takes its orientation and status bar from that window. The windows
// UIKit keeps for the keyboard sit far above the app's and don't count.
- (BOOL)appHasWindowInScene:(UIWindowScene *)scene {
    for (UIWindow *window in scene.windows) {
        if (window != self.window && !window.hidden && window.rootViewController &&
            window.windowLevel < UIWindowLevelStatusBar) {
            return YES;
        }
    }
    return NO;
}

- (void)applyGeometry:(CGRect)bounds inScene:(UIWindowScene *)scene resetPlacement:(BOOL)reset {
    LCHomeButtonWindow *window = self.window;
    if (!window || !self.buttonController) return;
    BOOL broken = CGRectGetWidth(window.bounds) < 200 || CGRectGetHeight(window.bounds) < 200;
    if (window.windowScene != scene) window.windowScene = scene;
    window.frame = bounds;
    self.buttonController.view.frame = window.bounds;
    [self.buttonController reloadSettings];
    if (reset || broken) [self.buttonController resetPlacementToDefault];
    [self.buttonController.view setNeedsLayout];
    [self.buttonController.view layoutIfNeeded];
}

- (void)showInScene:(UIWindowScene *)scene {
    @try {
        if (![self appHasWindowInScene:scene]) {
            // The scene can become active before the app has installed its first
            // window. Notifications are not guaranteed to repeat, so retry a few
            // times instead of permanently giving up on the overlay.
            if (scene.activationState != UISceneActivationStateUnattached && self.showAttempts++ < 40) {
                __weak LCHomeButtonController *weakSelf = self;
                __weak UIWindowScene *weakScene = scene;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (weakScene) {
                        [weakSelf showInScene:weakScene];
                    }
                });
            }
            return;
        }
        self.showAttempts = 0;
        CGRect bounds = LCHomeSceneBounds(scene);
        if (self.window.windowScene == scene) {
            [self applyGeometry:bounds inScene:scene resetPlacement:NO];
            return;
        }
        if (self.window) {
            self.window.hidden = NO;
            [self applyGeometry:bounds inScene:scene resetPlacement:YES];
            [self scheduleGeometryCheckInScene:scene];
            return;
        }

        LCHomeButtonViewController *buttonController = [[LCHomeButtonViewController alloc] init];
        __weak LCHomeButtonController *weakSelf = self;
        buttonController.pressHandler = ^{
            [weakSelf handlePress];
        };
        buttonController.edgeHandler = ^{
            [weakSelf handleEdgeSwipe];
        };
        LCHomeButtonWindow *window = [[LCHomeButtonWindow alloc] initWithFrame:bounds];
        window.windowScene = scene;
        window.windowLevel = UIWindowLevelAlert + 1;
        window.backgroundColor = UIColor.clearColor;
        window.rootViewController = buttonController;
        self.buttonController = buttonController;
        self.window = window;
        window.hidden = NO;
        [self applyGeometry:bounds inScene:scene resetPlacement:YES];
        [self scheduleGeometryCheckInScene:scene];
    } @catch (NSException *exception) {
        NSLog(@"[LC] The Home button couldn't show: %@", exception);
    }
}

- (void)scheduleGeometryCheckInScene:(UIWindowScene *)scene {
    __weak LCHomeButtonController *weakSelf = self;
    __weak UIWindowScene *weakScene = scene;
    for (NSNumber *delay in @[@0.15, @0.6]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LCHomeButtonController *controller = weakSelf;
            UIWindowScene *laterScene = weakScene;
            if (!controller || !laterScene || controller.window.windowScene != laterScene) return;
            [controller applyGeometry:LCHomeSceneBounds(laterScene) inScene:laterScene resetPlacement:NO];
        });
    }
}

// LiveProcess 必须保留访客画面和进程，由宿主现有 Dock 动画收纳窗口。
// 普通全屏访客仍通过 launchToGuestAppWithClassicMode 返回并结束进程。
- (void)openHostKeepingExtension {
    NSString *bundleID = NSUserDefaults.lcMainBundle.bundleIdentifier ?: NSBundle.mainBundle.bundleIdentifier;
    NSString *suffix = @".LiveProcess";
    if ([bundleID hasSuffix:suffix]) {
        bundleID = [bundleID substringToIndex:bundleID.length - suffix.length];
    }
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = workspaceClass ? ((id (*)(id, SEL))objc_msgSend)(workspaceClass, @selector(defaultWorkspace)) : nil;
    SEL openSel = NSSelectorFromString(@"openApplicationWithBundleIdentifier:configuration:completionHandler:");
    if (workspace && [workspace respondsToSelector:openSel]) {
        void (^done)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
            NSLog(@"[LC] home button reopened zContainer: success=%d error=%@", success, error);
        };
        ((void (*)(id, SEL, NSString *, id, id))objc_msgSend)(workspace, openSel, bundleID, nil, done);
        return;
    }
    // 回退: 用宿主 URL scheme 交给系统打开.
    NSURL *url = [NSURL URLWithString:@"zcontainer://"];
    UIApplication *application = [NSClassFromString(@"UIApplication") sharedApplication];
    [application openURL:url options:@{} completionHandler:nil];
}

static const CGFloat LCHomeButtonGlobalEdgeWidth = 36;
static const CGFloat LCHomeButtonGlobalEdgeTravel = 80;

- (BOOL)sideSwipeEnabled {
    if (self.buttonController) {
        return self.buttonController.edgeSwipeEnabled;
    }
    // The overlay may not exist yet (or at all); the setting itself still
    // decides whether the event fallback should work. Cache it instead of
    // reopening and synchronizing the suite for every touch event.
    if (!self.sideSwipeSetting) {
        self.sideSwipeSetting = LCHomeButtonSetting(@"TDSideSwipeMode");
    }
    return [self.sideSwipeSetting isEqualToString:@"always"];
}

- (void)refreshSideSwipeSetting {
    self.sideSwipeSetting = LCHomeButtonSetting(@"TDSideSwipeMode");
}

- (void)handleApplicationEvent:(UIEvent *)event {
    if (self.isLeaving || self.globalEdgeFired || ![self sideSwipeEnabled]) {
        return;
    }
    if (event.type != UIEventTypeTouches) return;

    for (UITouch *touch in event.allTouches) {
        UIWindow *window = touch.window;
        UIView *view = touch.view;
        if (!window || !view) continue;

        // Never treat a touch that starts on the overlay controls as a system
        // edge gesture; it belongs to the button/edge recognizer already.
        if ([view isDescendantOfView:self.window.rootViewController.view]) {
            continue;
        }

        CGPoint location = [touch locationInView:window];
        CGFloat width = window.bounds.size.width;
        switch (touch.phase) {
            case UITouchPhaseBegan:
                if (self.globalEdgeTouch || (location.x > LCHomeButtonGlobalEdgeWidth &&
                                             location.x < width - LCHomeButtonGlobalEdgeWidth)) {
                    break;
                }
                self.globalEdgeTouch = touch;
                self.globalEdgeStart = location;
                break;
            case UITouchPhaseMoved:
                if (touch != self.globalEdgeTouch) break;
                CGFloat travel = location.y - self.globalEdgeStart.y;
                CGFloat horizontal = fabs(location.x - self.globalEdgeStart.x);
                if (travel > LCHomeButtonGlobalEdgeTravel && travel > horizontal) {
                    self.globalEdgeFired = YES;
                    self.globalEdgeTouch = nil;
                    [self handleEdgeSwipe];
                    __weak LCHomeButtonController *weakSelf = self;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        LCHomeButtonController *controller = weakSelf;
                        controller.globalEdgeFired = NO;
                        controller.globalEdgeTouch = nil;
                    });
                }
                break;
            case UITouchPhaseEnded:
            case UITouchPhaseCancelled:
                if (touch == self.globalEdgeTouch) {
                    self.globalEdgeTouch = nil;
                }
                break;
            default:
                break;
        }
    }
}

- (void)handleEdgeSwipe {
    // “全局应用”只要求返回 zContainer；设置页跳转必须来自设置入口，
    // 不能在这里写 TDPendingOpenSettings / post openSettings 通知。
    [self goBackToZContainer];
}
- (void)handlePress {
    // “始终显示”只有单击回到主界面这一个功能；不再弹确认框。
    [self goBackToZContainer];
}

- (void)goBackToZContainer {
    if (self.isLeaving) return;
    // 多任务分支不依赖 LCSharedUtils: TweakLoader 没有链接 LiveContainerShared,
    // 以前先做 respondsToSelector 判断会直接 return, 导致按键点了没反应.
    if (NSUserDefaults.isLiveProcess) {
        self.isLeaving = YES;
        CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
        CFStringRef name = CFSTR("com.kdt.livecontainer.minimizeAll");
        CFNotificationCenterPostNotification(center, name, NULL, NULL, true);
        [self openHostKeepingExtension];
        self.isLeaving = NO;
        return;
    }
    Class sharedUtils = NSClassFromString(@"LCSharedUtils");
    if (![sharedUtils respondsToSelector:@selector(launchToGuestAppWithClassicMode:)]) {
        return;
    }
    // 普通全屏访客退出时清理选择并通知应用保存，然后打开宿主。
    self.isLeaving = YES;
    __weak LCHomeButtonController *weakSelf = self;
    void (^leave)(void) = ^{
        NSUserDefaults *defaults = NSUserDefaults.lcUserDefaults;
        [defaults removeObjectForKey:@"selected"];
        [defaults removeObjectForKey:@"selectedContainer"];
        [defaults synchronize];
        [weakSelf.departure leave];
        // The app's background work runs on the main queue too, so it gets a
        // turn before zContainer opens.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LCHomeButtonSaveTime * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf openZContainerWith:sharedUtils];
        });
    };
    if (self.buttonController) {
        [self.buttonController fadeOutWithCompletion:leave];
    } else {
        leave();
    }
}

- (void)openZContainerWith:(Class)sharedUtils {
    @try {
        [sharedUtils launchToGuestAppWithClassicMode:0];
    } @catch (NSException *exception) {
        NSLog(@"[LC] zContainer couldn't open: %@", exception);
    }
    __weak LCHomeButtonController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LCHomeButtonLeaveTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LCHomeButtonController *controller = weakSelf;
        controller.isLeaving = NO;
        [controller.departure comeBack];
        [controller.buttonController fadeBackIn];
    });
}

@end

// Shows the Home button in apps zContainer runs itself, once Settings >
// Appearance turns it on for apps, which it isn't until then, unless the app's
// settings turn it off. TweakLoader also loads into zContainer's own screens
// when tweaks are set to load there, which have no app chosen and keep their
// own Home button.
__attribute__((constructor))
static void LCHomeButtonInit(void) {
    if (!NSUserDefaults.lcGuestAppId) {
        // TweakLoader normally loads with the guest already identified, but a
        // hot-loaded/relaunched loader can race the bootstrap globals. Poll a
        // bounded number of times instead of giving up after one attempt.
        __block NSUInteger attempts = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            __block void (^tryAgain)(void) = ^{
                if (NSUserDefaults.lcGuestAppId) {
                    [LCHomeButtonController.sharedController start];
                    return;
                }
                attempts += 1;
                if (attempts >= 10) return;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), tryAgain);
            };
            tryAgain();
        });
        return;
    }
    // 始终注册控制器; 具体显示按键或响应侧边下滑由当前 app group 设置决定,
    // 这样从 zContainer 改设置后回到应用不需要重启访客进程.
    [LCHomeButtonController.sharedController start];
}
