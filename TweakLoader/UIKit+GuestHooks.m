@import UIKit;
#import "LCSharedUtils.h"
#import "UIKitPrivate.h"
#import "../LiveContainer/utils.h"
#import "../LiveContainer/Tweaks/Tweaks.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import "Localization.h"
#import "HomeButton/LCHomeButtonController.h"
#include <notify.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <limits.h>
#include <mach-o/dyld.h>
#import <os/lock.h>

UIInterfaceOrientation LCOrientationLock = UIInterfaceOrientationUnknown;
/// One-shot rotation from the stack card's 旋转方向 menu. Lives only for this
/// guest session: the override key is deleted as soon as it is consumed, so
/// the app's permanent 旋转锁定 keeps deciding future launches.
static UIInterfaceOrientationMask LCOrientationOnceMask = UIInterfaceOrientationMaskAll;
NSMutableArray<NSString*>* LCSupportedUrlSchemes = nil;
BOOL launchURLProcessed = NO;

/// Applies the stack card's one-shot rotation to this guest and clears it.
/// dir: 0 default (clear), 1 landscape, 2 portrait, 3 upside-down. The key
/// holds {"uuid": ..., "dir": ...}; a request for another guest is left for
/// its own process, and a consumed request is deleted so a relaunch starts
/// from the app's permanent 旋转锁定 again.
static void LCApplyOnceOrientation(void) {
    NSUserDefaults *defaults = NSUserDefaults.lcSharedDefaults;
    NSDictionary *request = [defaults objectForKey:@"LCPendingOrientationOverride"];
    if(![request isKindOfClass:NSDictionary.class]) return;
    NSString *requestUUID = request[@"uuid"];
    NSString *selfUUID = NSUserDefaults.lcGuestAppId;
    if(requestUUID.length && selfUUID.length && ![requestUUID isEqualToString:selfUUID]) return;
    [defaults removeObjectForKey:@"LCPendingOrientationOverride"];
    [defaults synchronize];
    NSInteger dir = [request[@"dir"] integerValue];
    UIInterfaceOrientationMask mask = UIInterfaceOrientationMaskAll;
    switch (dir) {
        case 1: mask = UIInterfaceOrientationMaskLandscape; break;
        case 2: mask = UIInterfaceOrientationMaskPortrait; break;
        case 3: mask = UIInterfaceOrientationMaskPortraitUpsideDown; break;
        case 0:
        default:
            mask = UIInterfaceOrientationMaskAll;
            break;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        LCOrientationOnceMask = mask;
        if(@available(iOS 16.0, *)) {
            UIWindowScene *scene = nil;
            for (UIScene *connected in UIApplication.sharedApplication.connectedScenes) {
                if([connected isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)connected; break; }
            }
            if(scene) {
                [scene requestGeometryUpdateWithPreferences:
                    [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask]
                    errorHandler:nil];
            }
        }
        [UIViewController attemptRotationToDeviceOrientation];
    });
}

static void LCOrientationNotification(CFNotificationCenterRef center, void *observer,
                                      CFStringRef name, const void *object,
                                      CFDictionaryRef userInfo) {
    LCApplyOnceOrientation();
}

__attribute__((constructor))
static void LCRegisterOrientationOverrideNotification(void) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    LCOrientationNotification,
                                    CFSTR("com.kdt.livecontainer.applyOrientation"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    // A request posted while this guest was launching still applies.
    dispatch_async(dispatch_get_main_queue(), ^{
        LCApplyOnceOrientation();
    });
}

/// Tells zContainer a touch began on this app, in its multitasking window,
/// so the window comes to the front. The notification is named for the app's
/// container: the last part of the home folder it was given.
static void LCPostWindowTouched(void) {
    static char name[256];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *home = getenv("HOME");
        NSString *folder = home ? @(home).lastPathComponent : @"";
        snprintf(name, sizeof(name), "%s%s", LC_WINDOW_TOUCHED_NOTIFICATION_PREFIX, folder.UTF8String);
    });
    notify_post(name);
}

static BOOL LCWindowHasVisibleGuestContent(UIWindow *window);

static IMP gOrigApplicationKeyWindow = NULL;
static IMP gOrigMainBundle = NULL;
static NSBundle *gLCGuestMainBundle = nil;

// 上游 LiveContainer 把访客的主 bundle 指回访客本身（LCBootstrap 里用
// initWithPathForMainBundle: 构造访客 bundle）。我们的容器让访客跑在 LiveProcess
// 扩展进程里（全屏与多任务都是），+[NSBundle mainBundle] 默认是扩展自己的 LiveProcess.appex
// ——检测器拿 mainBundle 与镜像路径一比，访客自己的可执行文件和 framework 全部被判
// "注入的共享库"。这里把 +[NSBundle mainBundle] 换成访客 bundle：真实目录直接由现有
// 掩码逻辑对外呈现，bundlePath 钩子自然给出与镜像一致的伪路径，bundleIdentifier 钩子给访客 id。
typedef const char *(*TDMaskRealPrefixFn)(void);
static TDMaskRealPrefixFn LCGuestMaskRealPrefixFn(void) {
    static TDMaskRealPrefixFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (TDMaskRealPrefixFn)dlsym(RTLD_DEFAULT, "tdv_mask_real_prefix"); });
    return fn;
}

static NSBundle *LCGuestMainBundle(id self, SEL _cmd) {
    if (gLCGuestMainBundle) return gLCGuestMainBundle;
    NSString *guestId = NSUserDefaults.lcGuestAppId;
    if (guestId.length == 0) {
        return ((NSBundle *(*)(id, SEL))gOrigMainBundle)(self, _cmd);
    }
    NSString *realDir = nil;
    TDMaskRealPrefixFn maskFn = LCGuestMaskRealPrefixFn();
    const char *prefix = maskFn ? maskFn() : NULL;
    if (prefix) {
        realDir = @(prefix);
    } else {
        const char *home = getenv("LC_HOME_PATH");
        if (home && home[0]) {
            NSString *dir = [NSString stringWithFormat:@"%s/Documents/Applications/%@.app", home, guestId];
            if (access([dir fileSystemRepresentation], F_OK) == 0) realDir = dir;
        }
    }
    if (!realDir) {
        return ((NSBundle *(*)(id, SEL))gOrigMainBundle)(self, _cmd);
    }
    NSBundle *bundle = [[NSBundle alloc] initWithPathForMainBundle:realDir];
    if (bundle) {
        gLCGuestMainBundle = bundle;
        static dispatch_once_t envOnce;
        dispatch_once(&envOnce, ^{ LCLogEnvView(@"mainBundle-repointed"); });
    }
    return gLCGuestMainBundle ? gLCGuestMainBundle : ((NSBundle *(*)(id, SEL))gOrigMainBundle)(self, _cmd);
}


// 上游 LiveContainer 给每个访客独立 scene，keyWindow 天然是访客窗口；我们跑在宿主 scene 里，
// keyWindow 可能指向宿主浮层/设置窗，或者干脆没有 —— 快手注入的 llykwai.dylib 调
// +[MBProgressHUD showHUDAddedTo:animated:] 时拿到的 view 就是 nil，initWithView: 里的
// NSParameterAssert(view) 直接抛 "View must not be nil" 崩掉。这里把"装着访客画面"的窗口
// 优先当 keyWindow，没有访客窗口时回退原实现。
static UIWindow *LCGuestApplicationKeyWindow(UIApplication *self, SEL _cmd) {
    for (UIScene *scene in self.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows.reverseObjectEnumerator) {
            if (LCWindowHasVisibleGuestContent(window)) return window;
        }
    }
    // 1.1.101 实测教训：访客（快手）黑屏时没有任何窗口带"可见访客内容"，上面返回 nil，
    // HUD 兜底又把 nil 传回 MBProgressHUD → 断言照崩。访客自建的 UIWindow 不带我们的
    // 标记，但 iOS 的 scene.keyWindow 一定跟踪得到 —— 第二层兜底用它。
    for (UIScene *scene in self.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UISceneActivationState state = ((UIWindowScene *)scene).activationState;
        if (state != UISceneActivationStateForegroundActive &&
            state != UISceneActivationStateForegroundInactive) continue;
        UIWindow *sceneKey = ((UIWindowScene *)scene).keyWindow;
        if (sceneKey) return sceneKey;
    }
    if (gOrigApplicationKeyWindow) {
        return ((UIWindow *(*)(id, SEL))gOrigApplicationKeyWindow)(self, _cmd);
    }
    return nil;
}

typedef void (*TDConsoleLogFn)(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static TDConsoleLogFn LCGuestConsoleLogFn(void) {
    static TDConsoleLogFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (TDConsoleLogFn)dlsym(RTLD_DEFAULT, "TDConsoleLog"); });
    return fn;
}
static IMP gOrigShowHUDAddedTo = NULL;
static BOOL gLoggedNilHUDView = NO;

// 快手的注入库 llykwai.dylib 在启动数秒后的主队列回调里调
// +[MBProgressHUD showHUDAddedTo:animated:]，传进来的 view 是 nil，
// MBProgressHUD initWithView: 的 NSParameterAssert 抛 NSException → SIGABRT（表现为黑屏）。
// 上游 LiveContainer 给访客独立 scene，它总拿得到窗口；我们把访客画在宿主 scene 的
// 虚拟窗口里，有的取窗口路径仍是 nil。兜底：view 为 nil 时改传访客 keyWindow，
// HUD 语义不变，只是不再把 nil 送进断言。

// Read-only diagnostics (外包第四期). Never creates windows, reparents views,
// sets delegate.window or changes key state; evidence only.
static void LCLogGuestWindows(NSString *event) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ LCLogGuestWindows(event); });
        return;
    }
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableString *text = [NSMutableString stringWithFormat:@"[window-lifecycle] event=%@ pid=%d liveProcess=%d", event, getpid(), NSUserDefaults.isLiveProcess];
    UIWindow *originalKey = gOrigApplicationKeyWindow ? ((UIWindow *(*)(id, SEL))gOrigApplicationKeyWindow)(application, @selector(keyWindow)) : nil;
    id<UIApplicationDelegate> appDelegate = application.delegate;
    UIWindow *delegateWindow = [appDelegate respondsToSelector:@selector(window)] ? appDelegate.window : nil;
    [text appendFormat:@" originalApplicationKey=%p appDelegate=%@ delegateWindow=%p", originalKey, NSStringFromClass([appDelegate class]), delegateWindow];
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *connected in application.connectedScenes) {
        if (![connected isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *scene = (UIWindowScene *)connected;
        id<UIWindowSceneDelegate> delegate = (id)scene.delegate;
        UIWindow *sceneDelegateWindow = [delegate respondsToSelector:@selector(window)] ? delegate.window : nil;
        [text appendFormat:@"\n scene=%@ state=%ld key=%p delegateWindow=%p windows=%lu", scene.session.persistentIdentifier, (long)scene.activationState, scene.keyWindow, sceneDelegateWindow, (unsigned long)scene.windows.count];
        for (UIWindow *window in scene.windows) if (![windows containsObject:window]) [windows addObject:window];
    }
    if (delegateWindow && ![windows containsObject:delegateWindow]) [windows addObject:delegateWindow];
    for (UIWindow *window in windows) {
        UIViewController *root = window.rootViewController;
        UIView *view = root.viewIfLoaded;
        [text appendFormat:@"\n window=%p class=%@ scene=%@ key=%d hidden=%d alpha=%.3f level=%.1f bounds=%@ safe=%@ root=%@ rootBounds=%@ clips=%d masks=%d", window, NSStringFromClass(window.class), window.windowScene.session.persistentIdentifier, window.isKeyWindow, window.hidden, window.alpha, window.windowLevel, NSStringFromCGRect(window.bounds), NSStringFromUIEdgeInsets(window.safeAreaInsets), NSStringFromClass(root.class), NSStringFromCGRect(view.bounds), view.clipsToBounds, view.layer.masksToBounds];
    }
    TDConsoleLogFn logFn = LCGuestConsoleLogFn();
    if (logFn) logFn(@"%@", text); else NSLog(@"%@", text);
}


// [env-view] detector-perspective dump (外包纪律: 先取证再修). Prints every
// value a detector typically compares: mainBundle identity/path, executable
// path, dyld image list, csops state. Read-only; no behavior change.
static void LCLogEnvView(NSString *reason) {
    NSMutableString *text = [NSMutableString stringWithFormat:@"[env-view] reason=%@ pid=%d", reason, getpid()];
    NSBundle *main = NSBundle.mainBundle;
    [text appendFormat:@"\n mainBundle.path=%@", main.bundlePath];
    [text appendFormat:@"\n mainBundle.id=%@ exec=%@ displayName=%@", main.bundleIdentifier, main.executablePath, [main objectForInfoDictionaryKey:@"CFBundleDisplayName"]];
    [text appendFormat:@"\n mainBundle.realPath=%@", main.bundlePath.stringByResolvingSymlinksInPath];
    [text appendFormat:@"\n NSProcessInfo.arguments[0]=%@", NSProcessInfo.processInfo.arguments.firstObject];
    char execPath[PATH_MAX]; execPath[0] = 0;
    uint32_t sz = sizeof(execPath);
    if (_NSGetExecutablePath(execPath, &sz) == 0) [text appendFormat:@"\n _NSGetExecutablePath=%s", execPath];
    [text appendFormat:@"\n dyld.imageCount=%u", _dyld_image_count()];
    uint32_t n = _dyld_image_count();
    if (n > 24) n = 24;
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm) [text appendFormat:@"\n dyld[%u]=%s", i, nm];
    }
    int csflags = 0;
    extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
    if (csops(getpid(), 0, &csflags, sizeof(csflags)) == 0) {
        [text appendFormat:@"\n csops.flags=0x%x CS_GET_VALIDATED=%d CS_PLATFORM_BINARY=%d", csflags,
            (csflags & 0x00000010) != 0, (csflags & 0x04000000) != 0];
    }
    TDConsoleLogFn logFn = LCGuestConsoleLogFn();
    if (logFn) logFn(@"%@", text); else NSLog(@"%@", text);
}

static id LCGuestShowHUDAddedTo(id self, SEL _cmd, id view, BOOL animated) {
    if (!view) {
        view = LCGuestApplicationKeyWindow(UIApplication.sharedApplication, @selector(keyWindow));
        if (!gLoggedNilHUDView) {
            gLoggedNilHUDView = YES;
            TDConsoleLogFn logFn = LCGuestConsoleLogFn();
            if (logFn) {
                LCLogGuestWindows(@"nil-HUD-view");
                logFn(@"[LC] MBProgressHUD nil-view fallback result=%p", view);
            } else {
                NSLog(@"[LC] MBProgressHUD nil-view fallback result=%p", view);
            }
        }
    }
    return ((id(*)(id, SEL, id, BOOL))gOrigShowHUDAddedTo)(self, _cmd, view, animated);
}

__attribute__((constructor))
static void UIKitGuestHooksInit() {
    if(!NSUserDefaults.lcGuestAppId) return;
    {
        Class hudClass = NSClassFromString(@"MBProgressHUD");
        if (hudClass) {
            Method hudMethod = class_getClassMethod(hudClass, @selector(showHUDAddedTo:animated:));
            if (hudMethod) {
                gOrigShowHUDAddedTo = method_getImplementation(hudMethod);
                method_setImplementation(hudMethod, (IMP)LCGuestShowHUDAddedTo);
            }
        }
    }
    {
        Method mainBundleMethod = class_getClassMethod(NSBundle.class, @selector(mainBundle));
        if (mainBundleMethod) {
            gOrigMainBundle = method_getImplementation(mainBundleMethod);
            method_setImplementation(mainBundleMethod, (IMP)LCGuestMainBundle);
        }
    }
    {
        Method keyWindowMethod = class_getInstanceMethod(UIApplication.class, @selector(keyWindow));
        if (keyWindowMethod) {
            gOrigApplicationKeyWindow = method_getImplementation(keyWindowMethod);
            method_setImplementation(keyWindowMethod, (IMP)LCGuestApplicationKeyWindow);
        }
    }
    for (NSString *name in @[UISceneDidActivateNotification, UISceneWillDeactivateNotification,
                             UIWindowDidBecomeKeyNotification, UIWindowDidBecomeVisibleNotification,
                             UIWindowDidBecomeHiddenNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            NSString *event = note.name;
            dispatch_async(dispatch_get_main_queue(), ^{ LCLogGuestWindows(event); });
        }];
    }
    {
        static dispatch_once_t envOnce;
        dispatch_once(&envOnce, ^{ LCLogEnvView(@"tweakloader-init"); });
    }
    swizzle(UIApplication.class, @selector(_applicationOpenURLAction:payload:origin:), @selector(hook__applicationOpenURLAction:payload:origin:));
    swizzle(UIApplication.class, @selector(_connectUISceneFromFBSScene:transitionContext:), @selector(hook__connectUISceneFromFBSScene:transitionContext:));
    swizzle(UIApplication.class, @selector(openURL:options:completionHandler:), @selector(hook_openURL:options:completionHandler:));
    swizzle(UIApplication.class, @selector(canOpenURL:), @selector(hook_canOpenURL:));
    swizzle(UIApplication.class, @selector(setDelegate:), @selector(hook_setDelegate:));
    swizzle(UIScene.class, @selector(scene:didReceiveActions:fromTransitionContext:), @selector(hook_scene:didReceiveActions:fromTransitionContext:));
    swizzle(UIScene.class, @selector(openURL:options:completionHandler:), @selector(hook_openURL:options:completionHandler:));
    // The edge-swipe fallback must see events in both classic and
    // multitasking launches; window-touched notification stays LiveProcess-only.
    swizzle(UIApplication.class, @selector(sendEvent:), @selector(hook_sendEvent:));
    NSInteger LCOrientationLockDirection = [NSUserDefaults.guestAppInfo[@"LCOrientationLock"] integerValue];
    if(LCOrientationLockDirection != 0 && [UIDevice.currentDevice userInterfaceIdiom] == UIUserInterfaceIdiomPhone) {
        switch (LCOrientationLockDirection) {
            case 1:
                LCOrientationLock = UIInterfaceOrientationLandscapeRight;
                break;
            case 2:
                LCOrientationLock = UIInterfaceOrientationPortrait;
                break;
            default:
                break;
        }
        if(!NSUserDefaults.isLiveProcess && LCOrientationLock != UIInterfaceOrientationUnknown) {
//            swizzle(UIApplication.class, @selector(_handleDelegateCallbacksWithOptions:isSuspended:restoreState:), @selector(hook__handleDelegateCallbacksWithOptions:isSuspended:restoreState:));
            swizzle(FBSSceneParameters.class, @selector(initWithXPCDictionary:), @selector(hook_initWithXPCDictionary:));
            swizzle(UIViewController.class, @selector(__supportedInterfaceOrientations), @selector(hook___supportedInterfaceOrientations));
            swizzle(UIViewController.class, @selector(shouldAutorotateToInterfaceOrientation:), @selector(hook_shouldAutorotateToInterfaceOrientation:));
            swizzle(UIWindow.class, @selector(setAutorotates:forceUpdateInterfaceOrientation:), @selector(hook_setAutorotates:forceUpdateInterfaceOrientation:));
        }

    }
}

NSString* findDefaultContainerWithBundleId(NSString* bundleId) {
    // find app's default container
    NSString *appGroupPath = [NSUserDefaults lcAppGroupPath];
    NSString* appGroupFolder = [appGroupPath stringByAppendingPathComponent:@"LiveContainer"];
    
    NSString* bundleInfoPath = [NSString stringWithFormat:@"%@/Applications/%@/LCAppInfo.plist", appGroupFolder, bundleId];
    NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfFile:bundleInfoPath];
    if(!infoDict) {
        NSString* lcDocFolder = [[NSString stringWithUTF8String:getenv("LC_HOME_PATH")] stringByAppendingPathComponent:@"Documents"];
        
        bundleInfoPath = [NSString stringWithFormat:@"%@/Applications/%@/LCAppInfo.plist", lcDocFolder, bundleId];
        infoDict = [NSDictionary dictionaryWithContentsOfFile:bundleInfoPath];
    }
    
    return infoDict[@"LCDataUUID"];
}

void forEachInstalledNotCurrentLC(BOOL isFree, void (^block)(NSString* scheme, BOOL* isBreak)) {
    for(NSString* scheme in [NSClassFromString(@"LCSharedUtils") lcUrlSchemes]) {
        if([scheme isEqualToString:NSUserDefaults.lcAppUrlScheme]) {
            continue;
        }
        BOOL isInstalled = [UIApplication.sharedApplication canOpenURL:[NSURL URLWithString: [NSString stringWithFormat: @"%@://", scheme]]];
        if(!isInstalled) {
            continue;
        }
        BOOL isBreak = false;
        if(isFree && [NSClassFromString(@"LCSharedUtils") isLCSchemeInUse:scheme]) {
            continue;
        }
        block(scheme, &isBreak);
        if(isBreak) {
            return;
        }
    }
}

void LCShowSwitchAppConfirmation(NSURL *url, NSString* bundleId, bool isSharedApp) {
    NSURLComponents* newUrlComp = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    
    // check if there's any free LiveContainer to run the app
    if(isSharedApp) {
        __block BOOL anotherLCLaunched = false;
        forEachInstalledNotCurrentLC(YES, ^(NSString * scheme, BOOL* isBreak) {
            newUrlComp.scheme = scheme;
            [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
            *isBreak = YES;
            anotherLCLaunched = YES;
            return;
        });
        if(anotherLCLaunched) {
            return;
        }
    }
    
    // if LCSwitchAppWithoutAsking is enabled we directly open the app in current lc
    // In the app group, so apps in multitasking windows, which run in the
    // LiveProcess extension, read it too.
    if ([NSUserDefaults.lcSharedDefaults boolForKey:@"LCSwitchAppWithoutAsking"]) {
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithURL:url];
        return;
    }

    NSString *message = [@"lc.guestTweak.appSwitchTip %@" localizeWithFormat:bundleId];
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"zContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithURL:url];
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    
    if(isSharedApp) {
        forEachInstalledNotCurrentLC(NO, ^(NSString * scheme, BOOL* isBreak) {
            UIAlertAction* openlcAction = [UIAlertAction actionWithTitle:[@"lc.guestTweak.openInLc %@" localizeWithFormat:scheme] style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
                newUrlComp.scheme = scheme;
                [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
                window.windowScene = nil;
            }];
            [alert addAction:openlcAction];
        });
    }
    
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"lc.common.cancel".loc style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = UIApplication.sharedApplication.windows.lastObject.windowLevel + 1;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void LCShowAlert(NSString* message) {
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"zContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = UIApplication.sharedApplication.windows.lastObject.windowLevel + 1;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void LCShowAppNotFoundAlert(NSString* bundleId) {
    LCShowAlert([@"lc.guestTweak.error.bundleNotFound %@" localizeWithFormat: bundleId]);
}

void openUniversalLink(NSString* decodedUrl) {
    NSURL* urlToOpen = [NSURL URLWithString: decodedUrl];
    if(![urlToOpen.scheme isEqualToString:@"https"] && ![urlToOpen.scheme isEqualToString:@"http"]) {
        NSData *data = [decodedUrl dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
        
        NSString* finalUrl = [NSString stringWithFormat:@"%@://open-url?url=%@", NSUserDefaults.lcAppUrlScheme, encodedUrl];
        NSURL* url = [NSURL URLWithString: finalUrl];
        
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        return;
    }
    
    UIActivityContinuationManager* uacm = [[UIApplication sharedApplication] _getActivityContinuationManager];
    NSUserActivity* activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
    activity.webpageURL = urlToOpen;
    NSDictionary* dict = @{
        @"UIApplicationLaunchOptionsUserActivityKey": activity,
        @"UICanvasConnectionOptionsUserActivityKey": activity,
        @"UIApplicationLaunchOptionsUserActivityIdentifierKey": NSUUID.UUID.UUIDString,
        @"UINSUserActivitySourceApplicationKey": @"com.apple.mobilesafari",
        @"UIApplicationLaunchOptionsUserActivityTypeKey": NSUserActivityTypeBrowsingWeb,
        @"_UISceneConnectionOptionsUserActivityTypeKey": NSUserActivityTypeBrowsingWeb,
        @"_UISceneConnectionOptionsUserActivityKey": activity,
        @"UICanvasConnectionOptionsUserActivityTypeKey": NSUserActivityTypeBrowsingWeb
    };
    
    [uacm handleActivityContinuation:dict isSuspended:nil];
}

void LCOpenWebPage(NSString* webPageUrlString, NSString* originalUrl) {
    if ([NSUserDefaults.lcSharedDefaults boolForKey:@"LCOpenWebPageWithoutAsking"]) {
        openUniversalLink(webPageUrlString);
        return;
    }
    
    NSURLComponents* newUrlComp = [NSURLComponents componentsWithString:originalUrl];
    __block BOOL anotherLCLaunched = false;
    forEachInstalledNotCurrentLC(YES, ^(NSString * scheme, BOOL* isBreak) {
        newUrlComp.scheme = scheme;
        [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
        *isBreak = YES;
        anotherLCLaunched = YES;
        return;
    });
    if(anotherLCLaunched) {
        return;
    }
    
    NSString *message = @"lc.guestTweak.openWebPageTip".loc;
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"zContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        [NSClassFromString(@"LCSharedUtils") setWebPageUrlForNextLaunch:webPageUrlString];
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithClassicMode:0];
    }];
    [alert addAction:okAction];
    UIAlertAction* openNowAction = [UIAlertAction actionWithTitle:@"lc.guestTweak.openInCurrentApp".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        openUniversalLink(webPageUrlString);
        window.windowScene = nil;
    }];

    forEachInstalledNotCurrentLC(NO, ^(NSString * scheme, BOOL* isBreak) {
        UIAlertAction* openlc2Action = [UIAlertAction actionWithTitle:[@"lc.guestTweak.openInLc %@" localizeWithFormat:scheme] style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            newUrlComp.scheme = scheme;
            [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
            window.windowScene = nil;
        }];
        [alert addAction:openlc2Action];
    });
    
    [alert addAction:openNowAction];
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"lc.common.cancel".loc style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = UIApplication.sharedApplication.windows.lastObject.windowLevel + 1;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    

}

void authenticateUser(void (^completion)(BOOL success, NSError *error)) {
    LAContext *context = [[LAContext alloc] init];
    NSError *error = nil;

    if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error]) {
        NSString *reason = @"lc.utils.requireAuthentication".loc;

        // Evaluate the policy for both biometric and passcode authentication
        [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
                localizedReason:reason
                          reply:^(BOOL success, NSError * _Nullable evaluationError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    completion(YES, nil);
                } else {
                    completion(NO, evaluationError);
                }
            });
        }];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            if([error code] == LAErrorPasscodeNotSet) {
                completion(YES, nil);
            } else {
                completion(NO, error);
            }
        });
    }
}

void handleLiveContainerLaunch(NSString* bundleName, NSString* containerFolderName, NSURL* url) {
    // check if there are other LCs is running this app
        NSString* runningLC = [NSClassFromString(@"LCSharedUtils") getContainerUsingLCSchemeWithFolderName:containerFolderName];
        // the app is running in an lc, that lc is not me, also is not my avatar
        if(runningLC) {
            if([runningLC hasSuffix:@"liveprocess"]) {
                runningLC = runningLC.stringByDeletingPathExtension;
            }
            NSString* urlStr = [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=%@&container-folder-name=%@", runningLC, bundleName, containerFolderName];
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:urlStr] options:@{} completionHandler:nil];
            return;
        }
        
        bool isSharedApp = false;
        NSBundle* bundle = [NSClassFromString(@"LCSharedUtils") findBundleWithBundleId: bundleName isSharedAppOut:&isSharedApp];
        NSDictionary* lcAppInfo;
        if(bundle) {
            lcAppInfo = [NSDictionary dictionaryWithContentsOfURL:[bundle URLForResource:@"LCAppInfo" withExtension:@"plist"]];
        }
        
        if(!bundle || ([lcAppInfo[@"isHidden"] boolValue] && [NSUserDefaults.lcSharedDefaults boolForKey:@"LCStrictHiding"])) {
            LCShowAppNotFoundAlert(bundleName);
        } else if ([lcAppInfo[@"isLocked"] boolValue]) {
            // need authentication
            authenticateUser(^(BOOL success, NSError *error) {
                if (success) {
                    LCShowSwitchAppConfirmation(url, bundleName, isSharedApp);
                } else {
                    if ([error.domain isEqualToString:LAErrorDomain]) {
                        if (error.code != LAErrorUserCancel) {
                            NSLog(@"[LC] Authentication Error: %@", error.localizedDescription);
                        }
                    } else {
                        NSLog(@"[LC] Authentication Error: %@", error.localizedDescription);
                    }
                }
            });
        } else {
            LCShowSwitchAppConfirmation(url, bundleName, isSharedApp);
        }
    
}

BOOL shouldRedirectOpenURLToHost(NSURL* url) {
    NSUserDefaults *ud = NSUserDefaults.lcSharedDefaults;
    return NSUserDefaults.isLiveProcess &&
    [ud boolForKey:@"LCRedirectURLToHost"] &&
    [[ud arrayForKey:@"LCGuestURLSchemes"] containsObject:url.scheme];
}
BOOL canAppOpenItself(NSURL* url) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
        NSArray *urlTypes = [infoDictionary objectForKey:@"CFBundleURLTypes"];
        LCSupportedUrlSchemes = [[NSMutableArray alloc] init];
        for (NSDictionary *urlType in urlTypes) {
            NSArray *schemes = [urlType objectForKey:@"CFBundleURLSchemes"];
            for(NSString* scheme in schemes) {
                [LCSupportedUrlSchemes addObject:[scheme lowercaseString]];
            }
        }
    });
    return [LCSupportedUrlSchemes containsObject:[url.scheme lowercaseString]];
}

// Whether a URL uses one of the schemes zContainer's own Info.plist declares:
// its own and the one Zeus adds when it signs zContainer ("zeus-" and the
// bundle ID), which is how Zeus opens it and sends it requests. Any app can
// declare those schemes too, so Zeus's links carry nothing secret: they only
// name what Zeus left in the app group. Links on those are for zContainer and
// never reach the guest app.
static BOOL LCIsHostOwnURL(NSURL *url) {
    static NSSet<NSString *> *hostSchemes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *bundle = NSUserDefaults.lcMainBundle;
        if([bundle.bundlePath.pathExtension isEqualToString:@"appex"]) {
            NSURL *appURL = bundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
            bundle = [NSBundle bundleWithURL:appURL] ?: bundle;
        }
        NSMutableSet<NSString *> *schemes = [NSMutableSet new];
        id urlTypes = bundle.infoDictionary[@"CFBundleURLTypes"];
        if([urlTypes isKindOfClass:NSArray.class]) {
            for(id urlType in urlTypes) {
                id list = [urlType isKindOfClass:NSDictionary.class] ? urlType[@"CFBundleURLSchemes"] : nil;
                if(![list isKindOfClass:NSArray.class]) {
                    continue;
                }
                for(id scheme in list) {
                    if([scheme isKindOfClass:NSString.class]) {
                        [schemes addObject:[scheme lowercaseString]];
                    }
                }
            }
        }
        hostSchemes = schemes;
    });
    return url.scheme.length > 0 && [hostSchemes containsObject:url.scheme.lowercaseString];
}

typedef NS_ENUM(NSInteger, LCControlAppURLHandling) {
    LCControlAppURLHandlingPassThrough,
    LCControlAppURLHandlingReplaceURL,
    LCControlAppURLHandlingStop,
};

static NSString* LCDecodedURLStringFromControlURL(NSURL *url) {
    NSURLComponents* lcUrl = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString* realUrlEncoded = nil;
    for(NSURLQueryItem *queryItem in lcUrl.queryItems) {
        if([queryItem.name isEqualToString:@"url"]) {
            realUrlEncoded = queryItem.value;
            break;
        }
    }
    if(!realUrlEncoded) {
        realUrlEncoded = lcUrl.queryItems.firstObject.value;
    }
    if(!realUrlEncoded) {
        return nil;
    }
    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:realUrlEncoded options:0];
    if(!decodedData) {
        return nil;
    }
    return [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
}

static void resolveLaunchExtensionFileBookmark(void) {
    NSData* bookmarkData = [NSUserDefaults.lcSharedDefaults dataForKey:@"LCLaunchExtensionFileBookmark"];
    if(!bookmarkData) {
        return;
    }
    BOOL isStale = NO;
    NSError* error = nil;
    NSURL* resolvedURL = [NSURL URLByResolvingBookmarkData:bookmarkData
                                                   options:(1UL << 10)
                                             relativeToURL:nil
                                       bookmarkDataIsStale:&isStale
                                                     error:&error];
    if(!resolvedURL) {
        NSLog(@"[LC] Failed to resolve shared file bookmark: %@", error.localizedDescription);
    }
    [NSUserDefaults.lcSharedDefaults removeObjectForKey:@"LCLaunchExtensionFileBookmark"];
    
}

static LCControlAppURLHandling LCHandleControlAppURL(NSURL *url, NSString** modifiedURLStr) {
    if(!url || url.isFileURL) {
        return LCControlAppURLHandlingPassThrough;
    }

    NSString *lcScheme = NSUserDefaults.lcAppUrlScheme;
    // pass through any url that should not be handled by current lc
    if(![url.scheme isEqualToString:lcScheme] && !LCIsHostOwnURL(url)) {
        return LCControlAppURLHandlingPassThrough;
    }
    NSString* urlHost = url.host;
    
    if([urlHost isEqualToString:@"livecontainer-relaunch"]) {
        return LCControlAppURLHandlingStop;
    }
    
    if([urlHost isEqualToString:@"livecontainer-launch"]) {
        // If it's not current app, then switch, otherwise check if we need to open the url
        NSString* bundleName = nil;
        NSString* openUrl = nil;
        NSString* containerFolderName = nil;
        NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem* queryItem in components.queryItems) {
            if ([queryItem.name isEqualToString:@"bundle-name"]) {
                bundleName = queryItem.value;
            } else if ([queryItem.name isEqualToString:@"open-url"]) {
                NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:queryItem.value options:0];
                openUrl = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
            } else if ([queryItem.name isEqualToString:@"container-folder-name"]) {
                containerFolderName = queryItem.value;
            }
        }
        
        // launch to LiveContainerUI
        if([bundleName isEqualToString:@"ui"]) {
            LCShowSwitchAppConfirmation(url, @"zContainer", false);
            return LCControlAppURLHandlingStop;
        }
        
        NSString* containerId = [NSString stringWithUTF8String:getenv("HOME")].lastPathComponent;
        if(!containerFolderName) {
            containerFolderName = findDefaultContainerWithBundleId(bundleName);
        }
        // current bundlename and container folder name matches
        if ([bundleName isEqualToString:NSBundle.mainBundle.bundlePath.lastPathComponent] && [containerId isEqualToString:containerFolderName]) {
            if(openUrl) {
                if([openUrl hasPrefix:@"file:"]) {
                    resolveLaunchExtensionFileBookmark();
                    *modifiedURLStr = openUrl;
                    return LCControlAppURLHandlingReplaceURL;
                } else {
                    openUniversalLink(openUrl);
                }
            }
        } else {
            handleLiveContainerLaunch(bundleName, containerFolderName, url);
        }
        
        return LCControlAppURLHandlingStop;
    }

    if([urlHost isEqualToString:@"open-web-page"]) {
        NSString *decodedUrl = LCDecodedURLStringFromControlURL(url);
        if(decodedUrl) {
            LCOpenWebPage(decodedUrl, url.absoluteString);
        }
        return LCControlAppURLHandlingStop;
    }

    if([urlHost isEqualToString:@"open-url"]) {
        NSString *decodedUrl = LCDecodedURLStringFromControlURL(url);
        if(!decodedUrl) {
            return LCControlAppURLHandlingStop;
        }
        // it's a Universal link, let's call -[UIActivityContinuationManager handleActivityContinuation:isSuspended:]
        if([decodedUrl hasPrefix:@"https"]) {
            openUniversalLink(decodedUrl);
            return LCControlAppURLHandlingStop;
        }
        *modifiedURLStr = decodedUrl;
        return LCControlAppURLHandlingReplaceURL;
    }

    if([urlHost isEqualToString:@"install"]) {
        LCShowAlert(@"lc.guestTweak.restartToInstall".loc);
        return LCControlAppURLHandlingStop;
    }

    // A certificate link holds a private key, so only zContainer's own
    // screens take it, after asking.
    if([urlHost isEqualToString:@"certificate"]) {
        LCShowAlert(@"zc.guestTweak.restartToImportCertificate".loc);
        return LCControlAppURLHandlingStop;
    }

    // What Zeus sent waits in the app group, and zContainer's Home Screen
    // takes it once it is back, so the link itself has nothing left to do.
    if([urlHost.lowercaseString isEqualToString:@"zeus-request"]) {
        LCShowAlert(@"zc.guestTweak.restartToGetFromZeus".loc);
        return LCControlAppURLHandlingStop;
    }

    return LCControlAppURLHandlingStop;
}

// Worker-thread queries use the last completed frame. UIKit traversal is
// main-thread-only; never synchronously wait for the main queue.
static __thread BOOL gHookStatusBarFrameEntered = NO;
static os_unfair_lock gStatusBarFrameLock = OS_UNFAIR_LOCK_INIT;
static CGRect gCachedStatusBarFrame = {{0, 0}, {0, 0}};
static BOOL gStatusBarFrameRefreshPending = NO;

static CGRect LCCacheGuestStatusBarFrame(CGRect frame) {
    os_unfair_lock_lock(&gStatusBarFrameLock);
    gCachedStatusBarFrame = frame;
    os_unfair_lock_unlock(&gStatusBarFrameLock);
    return frame;
}

// One line per geometry change, in the same exportable log as the launch
// records: the two launch modes can then be compared without guessing.
static void LCLogStatusBarGeometry(UIWindowScene *scene, UIWindow *window, CGRect reported) {
    static CGRect lastReported = {{0, 0}, {0, 0}};
    static CGRect lastBounds = {{0, 0}, {0, 0}};
    static UIEdgeInsets lastInsets;
    static __weak UIWindowScene *lastScene = nil;
    static __weak UIWindow *lastWindow = nil;
    CGRect bounds = window ? window.bounds : CGRectZero;
    UIEdgeInsets insets = window ? window.safeAreaInsets : UIEdgeInsetsZero;
    if (CGRectEqualToRect(reported, lastReported) && scene == lastScene && window == lastWindow &&
        CGRectEqualToRect(bounds, lastBounds) && UIEdgeInsetsEqualToEdgeInsets(insets, lastInsets)) return;
    lastReported = reported;
    lastBounds = bounds;
    lastInsets = insets;
    lastScene = scene;
    lastWindow = window;
    const char *dir = getenv("TD_CONSOLE_LOG_DIR");
    NSString *directory = (dir && dir[0] == '/') ? [NSString stringWithUTF8String:dir] : nil;
    if (!directory) {
        // Sideloaded installs can lack the app group while still running.
        // Match TDConsoleLog's fallback instead of dropping the diagnostic.
        const char *home = getenv("LC_HOME_PATH");
        if (home && home[0] == '/') {
            directory = [NSString stringWithFormat:@"%s/Documents/ConsoleLog", home];
        }
    }
    if (!directory) return;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]) return;
    NSString *line = [NSString stringWithFormat:
        @"[geometry] mode=%s pid=%d scene=%@ bounds=%@ contentWindow=%@ safeTop=%.1f safeBottom=%.1f statusBar=%@ reported=%@\n",
        getenv("TD_LAUNCH_MODE") ?: "-", getpid(),
        scene.session.persistentIdentifier,
        NSStringFromCGRect(scene.coordinateSpace.bounds),
        window ? NSStringFromCGRect(bounds) : @"(none)",
        window ? insets.top : -1,
        window ? insets.bottom : -1,
        scene.statusBarManager ? NSStringFromCGRect(scene.statusBarManager.statusBarFrame) : @"(none)",
        NSStringFromCGRect(reported)];
    NSString *path = [directory stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"geometry-%d.log", getpid()]];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    if (fd >= 0) { write(fd, data.bytes, data.length); close(fd); }
}

// Overlays and retained/hidden host windows are not guest content, even if a
// scene transition temporarily leaves one as the scene's key window.
static BOOL LCWindowHasVisibleGuestContent(UIWindow *window) {
    if (!window || window.hidden || window.alpha < 0.01 || window.windowLevel >= UIWindowLevelStatusBar) return NO;
    UIView *root = window.rootViewController.viewIfLoaded;
    return root ? (!root.hidden && root.alpha >= 0.01 && root.window == window) : window.subviews.count > 0;
}

// UIWindow's FrontBoard scene accessor is also used by UIKit's visibility
// propagation (documented in LiveContainer's upstream keyboard research).
// Read the scene's transported physical-bar rect, not defaults/file IPC and
// never the safe-area top, which may describe a notch or window controls.
@interface UIApplicationSceneSettings (LCGuestPhysicalStatusBar)
- (BOOL)statusBarDisabled;
- (CGRect)statusBarAvoidanceFrame;
@end

@protocol LCGuestStatusBarScene <NSObject>
- (UIApplicationSceneSettings *)settings;
@end

@interface UIWindow (LCGuestPhysicalStatusBar)
- (id<LCGuestStatusBarScene>)_fbsScene;
@end

static CGRect LCGuestStatusBarFrame(UIApplication *application) {
    // UIKit may re-enter before the current frame is known. Don't return a
    // previous scene or rotation's frame to that nested query.
    if (gHookStatusBarFrameEntered) return CGRectZero;
    gHookStatusBarFrameEntered = YES;
    @try {
        if (![NSThread isMainThread]) {
            os_unfair_lock_lock(&gStatusBarFrameLock);
            CGRect frame = gCachedStatusBarFrame;
            BOOL shouldRefresh = !gStatusBarFrameRefreshPending;
            gStatusBarFrameRefreshPending = YES;
            os_unfair_lock_unlock(&gStatusBarFrameLock);
            if (shouldRefresh) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        LCGuestStatusBarFrame(application);
                    } @finally {
                        os_unfair_lock_lock(&gStatusBarFrameLock);
                        gStatusBarFrameRefreshPending = NO;
                        os_unfair_lock_unlock(&gStatusBarFrameLock);
                    }
                });
            }
            return frame;
        }

        UIWindowScene *statusBarScene = nil;
        UIWindow *contentWindow = nil;
        NSInteger bestPriority = -1;
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UISceneActivationState state = scene.activationState;
            if (state != UISceneActivationStateForegroundActive &&
                state != UISceneActivationStateForegroundInactive) continue;
            UIWindowScene *candidateScene = (UIWindowScene *)scene;
            UIWindow *keyWindow = candidateScene.keyWindow;
            BOOL hasContentKeyWindow = LCWindowHasVisibleGuestContent(keyWindow);
            UIWindow *candidateWindow = hasContentKeyWindow ? keyWindow : nil;
            if (!candidateWindow) {
                for (UIWindow *window in candidateScene.windows.reverseObjectEnumerator) {
                    if (LCWindowHasVisibleGuestContent(window)) {
                        candidateWindow = window;
                        break;
                    }
                }
            }
            if (!candidateWindow) continue;
            // Inactive content scenes cover transitions; an overlay-only
            // active scene was excluded above, rather than winning by state.
            NSInteger priority = (state == UISceneActivationStateForegroundActive ? 3 : 0)
                + (hasContentKeyWindow ? 2 : 1);
            if (priority <= bestPriority) continue;
            bestPriority = priority;
            statusBarScene = candidateScene;
            contentWindow = candidateWindow;
            if (state == UISceneActivationStateForegroundActive && hasContentKeyWindow) break;
        }

        // Native scenes use their own manager. A virtual scene disables its
        // renderer, but carries the real host bar's measured viewport overlap
        // separately so legacy/manual-layout apps do not receive a false zero.
        UIStatusBarManager *manager = statusBarScene.statusBarManager;
        CGRect reported = manager ? manager.statusBarFrame : CGRectZero;
        if ([contentWindow respondsToSelector:@selector(_fbsScene)]) {
            id<LCGuestStatusBarScene> scene = [contentWindow _fbsScene];
            UIApplicationSceneSettings *settings = [scene respondsToSelector:@selector(settings)] ? [scene settings] : nil;
            if ([settings respondsToSelector:@selector(statusBarDisabled)] && [settings statusBarDisabled] &&
                [settings respondsToSelector:@selector(statusBarAvoidanceFrame)]) {
                CGRect physical = [settings statusBarAvoidanceFrame];
                reported = CGRectIsNull(physical) || CGRectIsEmpty(physical) ? CGRectZero : physical;
            }
        }
        LCLogStatusBarGeometry(statusBarScene, contentWindow, reported);
        return LCCacheGuestStatusBarFrame(reported);
    } @finally {
        gHookStatusBarFrameEntered = NO;
    }
}

// Handler for AppDelegate
@implementation UIApplication(LiveContainerHook)
/// A touch beginning on the app brings its multitasking window to the front,
/// as a touch on the window's title bar does.
- (void)hook_sendEvent:(UIEvent *)event {
    [self hook_sendEvent:event];
    if (event.type != UIEventTypeTouches) {
        return;
    }
    if (NSUserDefaults.isLiveProcess) {
        for (UITouch *touch in event.allTouches) {
            if (touch.phase == UITouchPhaseBegan) {
                LCPostWindowTouched();
                break;
            }
        }
    }
    [[LCHomeButtonController sharedController] handleApplicationEvent:event];
}

- (void)hook__applicationOpenURLAction:(id)action payload:(NSDictionary *)payload origin:(id)origin {
    NSURL *url = [NSURL URLWithString:payload[UIApplicationLaunchOptionsURLKey]];
    NSString* replacementURLString = nil;
    LCControlAppURLHandling decision = LCHandleControlAppURL(url, &replacementURLString);
    if(decision == LCControlAppURLHandlingStop) {
        return;
    }
    if(decision == LCControlAppURLHandlingReplaceURL) {
        NSMutableDictionary* newPayload = [payload mutableCopy];
        newPayload[UIApplicationLaunchOptionsURLKey] = replacementURLString;
        [self hook__applicationOpenURLAction:action payload:newPayload origin:origin];
        return;
    }
    [self hook__applicationOpenURLAction:action payload:payload origin:origin];
}

- (void)hook__connectUISceneFromFBSScene:(id)scene transitionContext:(UIApplicationSceneTransitionContext*)context {
#if !TARGET_OS_MACCATALYST
    NSString* decodedUrlStr = launchURLProcessed ? nil : NSUserDefaults.lcLaunchURL;
    launchURLProcessed = YES;
    NSString* urlStr;
        
    if(!decodedUrlStr && context.payload && (urlStr = context.payload[UIApplicationLaunchOptionsURLKey])) {
        do {
            if([urlStr hasPrefix:[NSString stringWithFormat: @"%@://open-url", NSUserDefaults.lcAppUrlScheme]]) {
                NSURLComponents* lcUrl = [NSURLComponents componentsWithString:urlStr];
                NSString* realUrlEncoded = lcUrl.queryItems[0].value;
                if(!realUrlEncoded) break;
                // Convert the base64 encoded url into String
                NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:realUrlEncoded options:0];
                decodedUrlStr = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
            } else if([urlStr hasPrefix:NSUserDefaults.lcAppUrlScheme] || LCIsHostOwnURL([NSURL URLWithString:urlStr])) {
                context.payload = nil;
                context.actions = nil;
            }
        } while (0);
    }
    
    do {
        if(!decodedUrlStr) break;
        NSURL* decodedUrl = [NSURL URLWithString:decodedUrlStr];
        if(decodedUrl.isFileURL) {
            resolveLaunchExtensionFileBookmark();
        }
        
        NSMutableDictionary* newDict = [context.payload mutableCopy];
        if(!newDict) newDict = [NSMutableDictionary new];
        newDict[UIApplicationLaunchOptionsURLKey] = decodedUrlStr;
        context.payload = newDict;
        
        
        UIOpenURLAction *urlAction = nil;
        for (id obj in context.actions.allObjects) {
            if ([obj isKindOfClass:UIOpenURLAction.class]) {
                urlAction = obj;
                break;
            }
        }
        
        NSMutableSet *newActions = context.actions.mutableCopy;
        if(newActions && urlAction) {
            [newActions removeObject:urlAction];
        }
        if(!newActions) newActions = [NSMutableSet new];
        
        UIOpenURLAction *newUrlAction = [[UIOpenURLAction alloc] initWithURL:decodedUrl];
        [newActions addObject:newUrlAction];
        context.actions = newActions;
        
    } while(0);
    
#endif
    [self hook__connectUISceneFromFBSScene:scene transitionContext:context];
}

-(BOOL)hook__handleDelegateCallbacksWithOptions:(id)arg1 isSuspended:(BOOL)arg2 restoreState:(BOOL)arg3 {
    BOOL ans = [self hook__handleDelegateCallbacksWithOptions:arg1 isSuspended:arg2 restoreState:arg3];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
//        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            LSApplicationWorkspace* workspace = [objc_lookUpClass("LSApplicationWorkspace") defaultWorkspace];
            [workspace openApplicationWithBundleID:@"com.apple.springboard"];
            [workspace openApplicationWithBundleID:NSUserDefaults.lcMainBundle.bundleIdentifier];
        });

    });


    return ans;
}

- (void)hook_openURL:(NSURL *)url options:(NSDictionary<NSString *,id> *)options completionHandler:(void (^)(_Bool))completion {
    BOOL openSelf = canAppOpenItself(url);
    BOOL redirectToHost = shouldRedirectOpenURLToHost(url);;
    if(openSelf || redirectToHost) {
        NSString* schemeToUse = openSelf ? NSUserDefaults.lcAppUrlScheme : [NSClassFromString(@"LCSharedUtils") hostAppUrlScheme];
        NSData *data = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
        NSString* finalUrlStr = [NSString stringWithFormat:@"%@://open-url?url=%@", schemeToUse, encodedUrl];
        NSURL* finalUrl = [NSURL URLWithString:finalUrlStr];
        [self hook_openURL:finalUrl options:options completionHandler:completion];
    } else {
        [self hook_openURL:url options:options completionHandler:completion];
    }
}
- (BOOL)hook_canOpenURL:(NSURL *) url {
    return canAppOpenItself(url) || shouldRedirectOpenURLToHost(url) || [self hook_canOpenURL:url];
}

// swizzle() 用的是 method_exchangeImplementations, **不幂等**: 交换两次等于
// 换回原样. UIApplication.setDelegate: 在 App 生命周期里会被调用多次, 每次
// 都执行下面的交换 -> 交换偶数次时 hook 直接失效 (状态栏高度又变成 0, 布局错位).
// 用一次性标记保证每组交换只做一次.
static BOOL gLCLegacyAppHooksInstalled = NO;

- (void)hook_setDelegate:(id<UIApplicationDelegate>)delegate {
    if(!gLCLegacyAppHooksInstalled &&
       ![delegate respondsToSelector:@selector(application:configurationForConnectingSceneSession:options:)]) {
        gLCLegacyAppHooksInstalled = YES;
        // Fix old apps black screen when UIApplicationSupportsMultipleScenes is YES
        swizzle(UIWindow.class, @selector(makeKeyAndVisible), @selector(hook_makeKeyAndVisible));
        swizzle(UIWindow.class, @selector(makeKeyWindow), @selector(hook_makeKeyWindow));
        swizzle(UIWindow.class, @selector(setHidden:), @selector(hook_setHidden:));
        // Bridge the legacy UIApplication getter to the guest's scene status bar.
        swizzle(UIApplication.class, @selector(statusBarFrame), @selector(hook_statusBarFrame));
        // Worker queries may use the last completed frame, but never retain
        // one across a hidden window, scene change or status-bar rotation.
        for (NSNotificationName name in @[UIWindowDidBecomeHiddenNotification, UISceneDidDisconnectNotification,
                                          UISceneDidActivateNotification, UIApplicationDidChangeStatusBarFrameNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *notification) {
                LCCacheGuestStatusBarFrame(CGRectZero);
            }];
        }
    }
    [self hook_setDelegate:delegate];
}

+ (BOOL)_wantsApplicationBehaviorAsExtension {
    // Fix LiveProcess: Make _UIApplicationWantsExtensionBehavior return NO so delegate code runs in the run loop
    return YES;
}

- (CGRect)hook_statusBarFrame {
    return LCGuestStatusBarFrame(self);
}

@end

// Handler for SceneDelegate
@implementation UIScene(LiveContainerHook)
- (void)hook_scene:(id)scene didReceiveActions:(NSSet *)actions fromTransitionContext:(id)context {
    UIOpenURLAction *urlAction = nil;
    for (id obj in actions.allObjects) {
        if ([obj isKindOfClass:UIOpenURLAction.class]) {
            urlAction = obj;
            break;
        }
    }

    if(!urlAction) {
        [self hook_scene:scene didReceiveActions:actions fromTransitionContext:context];
        return;
    }
    NSString* replacementURLString = nil;
    LCControlAppURLHandling decision = LCHandleControlAppURL(urlAction.url, &replacementURLString);
    if(decision == LCControlAppURLHandlingStop) {
        return;
    }
    if(decision == LCControlAppURLHandlingReplaceURL) {
        NSURL* finalURL = [NSURL URLWithString:replacementURLString];
        if(!finalURL) {
            return;
        }
        NSMutableSet *newActions = actions.mutableCopy;
        [newActions removeObject:urlAction];
        UIOpenURLAction *newUrlAction = [[UIOpenURLAction alloc] initWithURL:finalURL];
        [newActions addObject:newUrlAction];
        [self hook_scene:scene didReceiveActions:newActions fromTransitionContext:context];
        return;
    }
    [self hook_scene:scene didReceiveActions:actions fromTransitionContext:context];
}

- (void)hook_openURL:(NSURL *)url options:(UISceneOpenExternalURLOptions *)options completionHandler:(void (^)(BOOL success))completion {
    BOOL openSelf = canAppOpenItself(url);
    BOOL redirectToHost = shouldRedirectOpenURLToHost(url);
    if(openSelf || redirectToHost) {
        NSString* schemeToUse = openSelf ? NSUserDefaults.lcAppUrlScheme : [NSClassFromString(@"LCSharedUtils") hostAppUrlScheme];
        NSData *data = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
        NSString* finalUrlStr = [NSString stringWithFormat:@"%@://open-url?url=%@", schemeToUse, encodedUrl];
        NSURL* finalUrl = [NSURL URLWithString:finalUrlStr];
        [self hook_openURL:finalUrl options:options completionHandler:completion];
    } else {
        [self hook_openURL:url options:options completionHandler:completion];
    }
}
@end

@implementation FBSSceneParameters(LiveContainerHook)
- (instancetype)hook_initWithXPCDictionary:(NSDictionary*)dict {

    FBSSceneParameters* ans = [self hook_initWithXPCDictionary:dict];
    UIMutableApplicationSceneSettings* settings = [ans.settings mutableCopy];
    UIMutableApplicationSceneClientSettings* clientSettings = [ans.clientSettings mutableCopy];
    [settings setInterfaceOrientation:LCOrientationLock];
    [clientSettings setInterfaceOrientation:LCOrientationLock];
    ans.settings = settings;
    ans.clientSettings = clientSettings;
    return ans;
}
@end



@implementation UIViewController(LiveContainerHook)

- (UIInterfaceOrientationMask)hook___supportedInterfaceOrientations {
    if(LCOrientationOnceMask != UIInterfaceOrientationMaskAll) {
        return LCOrientationOnceMask;
    }
    if(LCOrientationLock == UIInterfaceOrientationLandscapeRight) {
        return UIInterfaceOrientationMaskLandscape;
    } else {
        return UIInterfaceOrientationMaskPortrait;
    }
}

- (BOOL)hook_shouldAutorotateToInterfaceOrientation:(NSInteger)orientation {
    return YES;
}

@end

@implementation UIWindow(hook)
- (void)hook_setAutorotates:(BOOL)autorotates forceUpdateInterfaceOrientation:(BOOL)force {
    [self hook_setAutorotates:YES forceUpdateInterfaceOrientation:YES];
}

- (void)hook_makeKeyAndVisible {
    [self updateWindowScene];
    [self hook_makeKeyAndVisible];
}
- (void)hook_makeKeyWindow {
    [self updateWindowScene];
    [self hook_makeKeyWindow];
}
- (void)hook_resignKeyWindow {
    [self updateWindowScene];
    [self hook_resignKeyWindow];
}
- (void)hook_setHidden:(BOOL)hidden {
    // Hiding an unattached host/overlay window must not attach it to the
    // guest scene just to hide it.
    if (!hidden) [self updateWindowScene];
    [self hook_setHidden:hidden];
}
- (void)updateWindowScene {
    if (self.windowScene) return;
    UIWindowScene *target = nil;
    NSInteger bestPriority = -1;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (self.screen != windowScene.screen || ![windowScene.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) continue;
        UISceneActivationState state = windowScene.activationState;
        if (state == UISceneActivationStateBackground) continue;
        NSInteger priority = state == UISceneActivationStateForegroundActive ? 2 : (state == UISceneActivationStateForegroundInactive ? 1 : 0);
        if (priority > bestPriority) {
            target = windowScene;
            bestPriority = priority;
        }
    }
    if (target) self.windowScene = target;
}
@end
