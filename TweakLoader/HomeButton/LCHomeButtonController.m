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
    // Bootstrap captures this suite before guest preferences are redirected.
    // Constructing a new suite here can instead resolve inside the guest's
    // container (CFPrefsPlistSource2), shadowing the host's gesture settings.
    // Do not create/synchronize preferences objects on every touch event.
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
@end

static void LCHomeButtonSettingsDidChange(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object,
                                          CFDictionaryRef userInfo) {
    LCHomeButtonController *controller = (__bridge LCHomeButtonController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSUserDefaults.lcSharedDefaults synchronize];
        [controller showInActiveScenes];
    });
}

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
    NSLog(@"[TDHome] guest controls started: liveProcess=%d assistive=%@ sideSwipe=%@",
          NSUserDefaults.isLiveProcess, LCHomeButtonSetting(@"TDAssistiveTouchMode"), LCHomeButtonSetting(@"TDSideSwipeMode"));
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(sceneDidActivate:) name:UISceneDidActivateNotification object:nil];
    [center addObserver:self selector:@selector(windowDidBecomeVisible:) name:UIWindowDidBecomeVisibleNotification object:nil];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    LCHomeButtonSettingsDidChange,
                                    CFSTR("com.kdt.livecontainer.assistiveTouchSettingsChanged"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
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
        scene.activationState != UISceneActivationStateUnattached) {
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

- (UIWindowLevel)overlayLevelInScene:(UIWindowScene *)scene {
    if (![LCHomeButtonSetting(@"TDAssistiveTouchMode") isEqualToString:@"always"]) {
        return UIWindowLevelAlert + 1;
    }
    UIWindowLevel level = UIWindowLevelAlert + 2;
    for (UIWindow *other in scene.windows) {
        if (other != self.window && !other.hidden && other.alpha > 0 && other.rootViewController) {
            level = MAX(level, other.windowLevel + 1);
        }
    }
    return level;
}

- (void)applyGeometry:(CGRect)bounds inScene:(UIWindowScene *)scene resetPlacement:(BOOL)reset {
    LCHomeButtonWindow *window = self.window;
    if (!window || !self.buttonController) return;
    BOOL broken = CGRectGetWidth(window.bounds) < 200 || CGRectGetHeight(window.bounds) < 200;
    if (window.windowScene != scene) window.windowScene = scene;
    window.frame = bounds;
    window.windowLevel = [self overlayLevelInScene:scene];
    self.buttonController.view.frame = window.bounds;
    [self.buttonController reloadSettings];
    if (reset || broken) [self.buttonController resetPlacementToDefault];
    [self.buttonController.view setNeedsLayout];
    [self.buttonController.view layoutIfNeeded];
}

- (void)showInScene:(UIWindowScene *)scene {
    @try {
        // 「始终显示」全局只允许一个按钮：宿主那个单一悬浮窗负责所有界面（经典全屏
        // 访客也跑在宿主进程里），这里一律不建自己的窗口，否则会出现两个按钮。
        if ([LCHomeButtonSetting(@"TDAssistiveTouchMode") isEqualToString:@"always"]) {
            [self.buttonController reloadSettings];
            return;
        }
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
            self.window.hidden = NO;
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
        buttonController.doubleTapHandler = ^{
            [weakSelf handleDoubleTap];
        };
        buttonController.edgeHandler = ^{
            [weakSelf handleEdgeSwipe];
        };
        LCHomeButtonWindow *window = [[LCHomeButtonWindow alloc] initWithFrame:bounds];
        window.windowScene = scene;
        window.windowLevel = [self overlayLevelInScene:scene];
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

// LiveProcess returns to the host without killing any guest window. Opening
// an application is not proof the stack appeared; the host logs attachment.
- (void)openHostKeepingExtension {
    NSString *bundleID = NSUserDefaults.lcMainBundle.bundleIdentifier;
    NSString *suffix = @".LiveProcess";
    if ([bundleID hasSuffix:suffix]) {
        bundleID = [bundleID substringToIndex:bundleID.length - suffix.length];
    }
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = workspaceClass ? ((id (*)(id, SEL))objc_msgSend)(workspaceClass, @selector(defaultWorkspace)) : nil;
    void (^openHostURL)(void) = ^{
        NSString *scheme = NSUserDefaults.lcAppUrlScheme;
        NSURL *url = scheme.length ? [NSURL URLWithString:[scheme stringByAppendingString:@"://"]] : nil;
        if (!url) {
            NSLog(@"[TDHome] cannot activate host: no host URL scheme");
            return;
        }
        // UIApplication's guest URL hook intentionally handles control links
        // locally. Ask the workspace to open the actual host application.
        if ([workspace respondsToSelector:@selector(openURL:)]) {
            BOOL opened = ((BOOL (*)(id, SEL, NSURL *))objc_msgSend)(workspace, @selector(openURL:), url);
            NSLog(@"[TDHome] host URL activation accepted=%d", opened);
        } else {
            UIApplication *application = [NSClassFromString(@"UIApplication") sharedApplication];
            [application openURL:url options:@{} completionHandler:^(BOOL success) {
                NSLog(@"[TDHome] host URL activation accepted=%d", success);
            }];
        }
    };
    SEL openSel = NSSelectorFromString(@"openApplicationWithBundleIdentifier:configuration:completionHandler:");
    if (bundleID.length && [workspace respondsToSelector:openSel]) {
        void (^done)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
            NSLog(@"[TDHome] host activation accepted=%d error=%@", success, error);
            if (!success) dispatch_async(dispatch_get_main_queue(), openHostURL);
        };
        ((void (*)(id, SEL, NSString *, id, id))objc_msgSend)(workspace, openSel, bundleID, nil, done);
    } else {
        openHostURL();
    }
}

static const CGFloat LCHomeButtonGlobalEdgeWidth = 36;
static const CGFloat LCHomeButtonGlobalEdgeTravel = 80;

// Native edge recognizers observe the app window without an intercepting
// overlay. This event-stream fallback also works before the button controller
// has a window, and reads the current host setting when a touch starts at an edge.

- (void)handleApplicationEvent:(UIEvent *)event {
    if (self.isLeaving || self.globalEdgeFired) {
        return;
    }
    if (event.type != UIEventTypeTouches) return;

    for (UITouch *touch in event.allTouches) {
        UIWindow *window = touch.window;
        UIView *view = touch.view;
        if (!window || !view) continue;

        // The button owns its taps and drags. Other views still use this
        // fallback if a downward-only touch never starts a native edge pan.
        if (window == self.window && [view isKindOfClass:UIControl.class]) {
            continue;
        }

        CGPoint location = [touch locationInView:window];
        CGFloat width = window.bounds.size.width;
        switch (touch.phase) {
            case UITouchPhaseBegan: {
                if (self.globalEdgeTouch || (location.x > LCHomeButtonGlobalEdgeWidth &&
                                             location.x < width - LCHomeButtonGlobalEdgeWidth)) {
                    break;
                }
                if (![LCHomeButtonSetting(@"TDSideSwipeMode") isEqualToString:@"always"]) break;
                self.globalEdgeTouch = touch;
                self.globalEdgeStart = location;
                break;
            }
            case UITouchPhaseMoved:
                if (touch != self.globalEdgeTouch) break;
                CGFloat travel = location.y - self.globalEdgeStart.y;
                CGFloat horizontal = fabs(location.x - self.globalEdgeStart.x);
                if (travel > LCHomeButtonGlobalEdgeTravel && travel > horizontal) {
                    self.globalEdgeTouch = nil;
                    [self handleEdgeSwipe];
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
    if (self.isLeaving || self.globalEdgeFired) return;
    self.globalEdgeFired = YES;
    self.globalEdgeTouch = nil;
    NSLog(@"[TDHome] downward edge swipe recognized; requesting host home");
    [self goBackToZContainer];
    __weak LCHomeButtonController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        weakSelf.globalEdgeFired = NO;
    });
}

// Persist the intent before notifying: Darwin delivery alone cannot activate a
// background host, and a classic guest must restart the host process first.
- (void)handleDoubleTap {
    if (self.isLeaving) return;
    // Darwin notifications carry no sender identity. Preserve the leaving
    // LiveProcess container before the host becomes key (several guests share
    // that same host window). The host validates the request age and UUID.
    NSString *container = NSUserDefaults.isLiveProcess ? NSHomeDirectory().lastPathComponent : @"";
    NSDictionary *request = @{@"identifier": NSUUID.UUID.UUIDString,
                              @"timestamp": @(NSDate.date.timeIntervalSince1970),
                              @"container": container ?: @""};
    NSUserDefaults *defaults = NSUserDefaults.lcSharedDefaults;
    [defaults setObject:request forKey:@"LCPendingAppStackRequest"];
    BOOL saved = [defaults synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                        CFSTR("com.kdt.livecontainer.showAppStack"), NULL, NULL, true);
    NSLog(@"[TDHome] double tap requested app stack: request=%@ saved=%d liveProcess=%d",
          request[@"identifier"], saved, NSUserDefaults.isLiveProcess);
    if (NSUserDefaults.isLiveProcess) {
        [self openHostKeepingExtension];
    } else {
        [self goBackToZContainer];
    }
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
        NSUserDefaults *defaults = NSUserDefaults.lcSharedDefaults;
        [defaults setObject:@{@"container": NSHomeDirectory().lastPathComponent ?: @"",
                              @"timestamp": @(NSDate.date.timeIntervalSince1970)}
                     forKey:@"LCRecentGuestDeparture"];
        [defaults synchronize];
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
static void LCHomeButtonStartWhenReady(NSUInteger attemptsRemaining) {
    if (NSUserDefaults.lcGuestAppId) {
        [LCHomeButtonController.sharedController start];
    } else if (attemptsRemaining > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LCHomeButtonStartWhenReady(attemptsRemaining - 1);
        });
    }
}

__attribute__((constructor))
static void LCHomeButtonInit(void) {
    // No self-retaining recursive block, and all UIKit work starts on main.
    dispatch_async(dispatch_get_main_queue(), ^{
        LCHomeButtonStartWhenReady(10);
    });
}
