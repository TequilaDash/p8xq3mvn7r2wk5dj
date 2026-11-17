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


NSString *LCHomeButtonSetting(NSString *key) {
    Class sharedUtils = NSClassFromString(@"LCSharedUtils");
    NSString *groupID = nil;
    if ([sharedUtils respondsToSelector:@selector(appGroupID)]) {
        groupID = ((NSString *(*)(id, SEL))objc_msgSend)(sharedUtils, @selector(appGroupID));
    }
    NSUserDefaults *shared = groupID ? [[NSUserDefaults alloc] initWithSuiteName:groupID] : nil;
    return [shared stringForKey:key];
}

@interface LCHomeButtonController ()
@property (nonatomic, nullable) LCHomeButtonWindow *window;
@property (nonatomic, nullable) LCHomeButtonViewController *buttonController;
@property (nonatomic) LCAppDeparture *departure;
@property (nonatomic) BOOL isLeaving;
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
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(sceneDidActivate:) name:UISceneDidActivateNotification object:nil];
    [center addObserver:self selector:@selector(windowDidBecomeVisible:) name:UIWindowDidBecomeVisibleNotification object:nil];
}

// The button moves to the screen the person is using.
- (void)sceneDidActivate:(NSNotification *)notification {
    if (![notification.object isKindOfClass:UIWindowScene.class]) return;
    UIWindowScene *scene = notification.object;
    if (![self isOwnScreen:scene]) return;
    [self.buttonController reloadSettings];
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
    if (![window isKindOfClass:UIWindow.class] || window == self.window || self.window.windowScene) {
        return;
    }
    UIWindowScene *scene = window.windowScene;
    if (scene && [self isOwnScreen:scene] && (scene.activationState == UISceneActivationStateForegroundActive ||
                  scene.activationState == UISceneActivationStateForegroundInactive)) {
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

- (void)showInScene:(UIWindowScene *)scene {
    @try {
        if (self.window.windowScene == scene || ![self appHasWindowInScene:scene]) {
            return;
        }
        if (self.window) {
            self.window.frame = scene.coordinateSpace.bounds;
            self.window.windowScene = scene;
            self.window.hidden = NO;
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
        LCHomeButtonWindow *window = [[LCHomeButtonWindow alloc] initWithFrame:scene.coordinateSpace.bounds];
        window.windowScene = scene;
        window.windowLevel = UIWindowLevelAlert + 1;
        window.backgroundColor = UIColor.clearColor;
        window.rootViewController = buttonController;
        self.buttonController = buttonController;
        self.window = window;
        window.hidden = NO;
        window.frame = scene.coordinateSpace.bounds;
        buttonController.view.frame = window.bounds;
        [buttonController reloadSettings];
        [buttonController.view setNeedsLayout];
        [buttonController.view layoutIfNeeded];
    } @catch (NSException *exception) {
        NSLog(@"[LC] The Home button couldn't show: %@", exception);
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

- (void)handleEdgeSwipe {
    Class sharedUtils = NSClassFromString(@"LCSharedUtils");
    NSString *groupID = nil;
    if ([sharedUtils respondsToSelector:@selector(appGroupID)]) {
        groupID = ((NSString *(*)(id, SEL))objc_msgSend)(sharedUtils, @selector(appGroupID));
    }
    NSUserDefaults *shared = groupID ? [[NSUserDefaults alloc] initWithSuiteName:groupID] : nil;
    [shared setBool:YES forKey:@"TDPendingOpenSettings"];
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterPostNotification(center, CFSTR("com.kdt.livecontainer.openSettings"), NULL, NULL, true);
    [self goBackToZContainer];
}
- (void)handlePress {
    BOOL always = [LCHomeButtonSetting(@"TDAssistiveTouchMode") isEqualToString:@"always"];
    // 全局显示模式下, 普通全屏启动的应用单击后先确认是否退出.
    if (always && !NSUserDefaults.isLiveProcess) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"退出应用"
                                                                       message:@"退出当前应用并返回 zContainer 主界面？"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        __weak LCHomeButtonController *weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"退出" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [weakSelf goBackToZContainer];
        }]];
        [self.buttonController presentViewController:alert animated:YES completion:nil];
        return;
    }
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
    [self.buttonController fadeOutWithCompletion:^{
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
    }];
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
        return;
    }
    // 始终注册控制器; 具体显示按键或响应侧边下滑由当前 app group 设置决定,
    // 这样从 zContainer 改设置后回到应用不需要重启访客进程.
    [LCHomeButtonController.sharedController start];
}
