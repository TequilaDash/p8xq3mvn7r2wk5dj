extern const char *TDHostHomeDocumentsPath(void);

//
//  AppSceneView.m
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
#import "AppSceneViewController.h"
#import "DecoratedAppSceneViewController.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "../LiveContainerSwiftUI/Utilities/LCUtils.h"
#import "PiPManager.h"
#import "Localization.h"
#import "LCSharedUtils.h"
#import "utils.h"
#import "UIKitPrivate+MultitaskSupport.h"
#include <errno.h>
#include <signal.h>

@interface AppSceneViewController()
@property int resizeDebounceToken;
@property(nonatomic, readwrite) bool isNativeWindow;
@property NSUUID* identifier;
@end

@interface AppSceneViewController()
@property(nonatomic, weak) UIWindowScene *hostScene;
@property(nonatomic) NSString *settingsDiffKey;
@property(nonatomic) NSString *sceneID;
@property(nonatomic) NSExtension* extension;
@property(nonatomic) bool isAppTerminationCleanUpCalled;
@property(nonatomic, readwrite) BOOL isTerminated;
@property(nonatomic) BOOL observedTerminationExit;
@property(nonatomic) NSUInteger terminationWaitGeneration;
@property(nonatomic, strong) dispatch_source_t terminationExitSource;
@property(nonatomic, copy) void (^terminationCompletion)(NSError *error);
@end

@implementation AppSceneViewController


- (instancetype)initWithBundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID delegate:(id<AppSceneViewControllerDelegate>)delegate {
    self = [super initWithNibName:nil bundle:nil];
    self.delegate = delegate;
    self.dataUUID = dataUUID;
    self.bundleId = bundleId;
    self.scaleRatio = 1.0;
    self.isAppTerminationCleanUpCalled = false;
    // The caller chooses the window type per launch, not the current global
    // preference (which may have changed while this guest was running).
    self.isNativeWindow = ![delegate isKindOfClass:DecoratedAppSceneViewController.class];
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIKitFixesInit();
    });
    
    // init extension
    NSError* error = nil;
    _extension = [NSExtension extensionWithIdentifier:LCUtils.liveProcessBundleIdentifier error:&error];
    if(error) {
        [delegate appSceneVC:self didInitializeWithError:error];
        return nil;
    }
    _extension.preferredLanguages = @[];
    
    NSExtensionItem *item = [NSExtensionItem new];
    NSMutableArray* bookmarks = [NSMutableArray array];
    const char *tdHostDocumentsPath = TDHostHomeDocumentsPath();
    NSString *tdGlobalFlagPath = tdHostDocumentsPath ? [[NSString stringWithUTF8String:tdHostDocumentsPath] stringByAppendingPathComponent:@"TDGlobalHide"] : nil;
    BOOL tdGlobalHide = tdGlobalFlagPath && [[NSString stringWithContentsOfFile:tdGlobalFlagPath encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"1"];
    // A dictionary literal throws on a nil value. Host boot can leave the URL
    // scheme unset, and the selected ids are optional, so never pass nil here.
    NSString *hostScheme = NSUserDefaults.lcAppUrlScheme;
    if (!hostScheme) {
        NSArray *schemes = NSBundle.mainBundle.infoDictionary[@"CFBundleURLTypes"][0][@"CFBundleURLSchemes"];
        hostScheme = schemes.firstObject ?: @"livecontainer";
    }
    NSMutableDictionary *userInfo = @{
        @"hostUrlScheme": hostScheme,
        @"selected": _bundleId ?: @"",
        @"selectedContainer": _dataUUID ?: @"",
        @"bookmarks": bookmarks,
        @"lcHomePath": NSHomeDirectory(),
        @"tdGlobalHide": @(tdGlobalHide),
    }.mutableCopy;
    // Keep per-app fields for LiveProcess versions that read them from the
    // request. The common bootstrap reads the installed guest plist itself.
    bool payloadIsSharedApp = false;
    NSBundle *payloadBundle = bundleId ? [LCSharedUtils findBundleWithBundleId:bundleId isSharedAppOut:&payloadIsSharedApp] : nil;
    NSString *payloadInfoPath = payloadBundle ? [payloadBundle.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"] : nil;
    NSDictionary *payloadAppInfo = payloadInfoPath ? [NSDictionary dictionaryWithContentsOfFile:payloadInfoPath] : nil;
    for (NSString *key in @[@"hideLiveContainer", @"sysctlSpoof", @"secTaskSpoof",
                             @"csopsSpoof", @"procSpoof", @"csopsKeepDebugged"]) {
        if ([payloadAppInfo[key] isKindOfClass:NSNumber.class]) {
            userInfo[key] = payloadAppInfo[key];
        }
    }
    
    NSString* launchAppUrlScheme = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    [NSUserDefaults.lcUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
    if(launchAppUrlScheme) {
        [userInfo setValue:launchAppUrlScheme forKey:@"launchAppUrlScheme"];
    }
    
    NSURL *docURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"LCSharePrivateDataWithLiveProcess"]) {
        NSData* bookmarkData = [docURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
        // Bookmark creation returns nil on failure; -addObject:nil throws.
        if (bookmarkData) { [bookmarks addObject:bookmarkData]; }
    } else {
        // when mutlitask with private app, we can restrict its sandbox to only its own container
        if (!payloadIsSharedApp) {
            NSURL *dataURL = [docURL URLByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", dataUUID]];
            NSURL *tweaksURL = [docURL URLByAppendingPathComponent:@"Tweaks"];
            NSData *bundleBm = [payloadBundle.bundleURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
            if (bundleBm) { [bookmarks addObject:bundleBm]; }
            NSData* containerBookmark = [dataURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
            if(containerBookmark) {
                [bookmarks addObject:containerBookmark];
            }
            NSData *tweaksBm = [tweaksURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
            if (tweaksBm) { [bookmarks addObject:tweaksBm]; }
        }
    }
    item.userInfo = userInfo;
    
    __weak typeof(self) weakSelf = self;
    [_extension setRequestCancellationBlock:^(NSUUID *uuid, NSError *error) {
        [weakSelf appTerminationCleanUp];
        if (!weakSelf.isUserTerminating) {
            [weakSelf.delegate appSceneVC:weakSelf didInitializeWithError:error];
        }
    }];
    [_extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        [weakSelf appTerminationCleanUp];
    }];
    [_extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *identifier) {
        if(identifier) {
            // The list of containers in use is changed only on the main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                if(!self.isAppTerminationCleanUpCalled) {
                    [MultitaskManager registerMultitaskContainerWithContainer:self.dataUUID];
                }
            });
            self.identifier = identifier;
            self.pid = [self.extension pidForRequestIdentifier:self.identifier];
            [delegate appSceneVC:self didInitializeWithError:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setUpAppPresenter];
            });
        } else {
            NSError* error = [NSError errorWithDomain:@"LiveProcess" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to start app. Child process has unexpectedly crashed"}];
            [delegate appSceneVC:self didInitializeWithError:error];
        }
    }];
    
    return self;
}

- (void)setUpAppPresenter {
    if (self.isUserTerminating || self.isAppTerminationCleanUpCalled) return;
    RBSProcessPredicate* predicate = [PrivClass(RBSProcessPredicate) predicateMatchingIdentifier:@(self.pid)];
    FBProcessManager *manager = [PrivClass(FBProcessManager) sharedInstance];
    // At this point, the process is spawned and we're ready to create a scene to render in our app
    RBSProcessHandle* processHandle = [PrivClass(RBSProcessHandle) handleForPredicate:predicate error:nil];
    [manager registerProcessForAuditToken:processHandle.auditToken];
    UIApplicationSceneSpecification *specification = [UIApplicationSceneSpecification specification];
    
    void (^updateSceneSettings)(id) = ^void(UIMutableApplicationSceneSettings *settings) {
        settings.canShowAlerts = YES;
        settings.cornerRadiusConfiguration = [[PrivClass(BSCornerRadiusConfiguration) alloc] initWithTopLeft:self.view.layer.cornerRadius bottomLeft:self.view.layer.cornerRadius bottomRight:self.view.layer.cornerRadius topRight:self.view.layer.cornerRadius];
        settings.displayConfiguration = UIScreen.mainScreen.displayConfiguration;
        settings.foreground = YES;
        //settings.interruptionPolicy = 2; // reconnect
        settings.level = 1;
        settings.persistenceIdentifier = self.dataUUID;
        settings.statusBarDisabled = !self.isNativeWindow;
        //settings.previewMaximumSize =
        //settings.deviceOrientationEventsEnabled = YES;
        if(!self.usesHostingControllerAPI) {
            settings.safeAreaInsetsPortrait = self.view.safeAreaInsets;
        }
    };
    void (^updateSceneClientSettings)(id) = ^void(UIMutableApplicationSceneClientSettings *clientSettings) {
        clientSettings.interfaceOrientation = UIInterfaceOrientationPortrait;
        clientSettings.statusBarStyle = 0;
    };

    if (@available(iOS 18.0, *)) {
        // Use new API for iOS 18+. While some of these APIs are available since 17.0, we're only interested in fixing event deferring issue
        _UISceneHostingControllerAdvancedConfiguration *config = [[_UISceneHostingControllerAdvancedConfiguration alloc] initWithProcessIdentity:processHandle.identity];
        config.sceneSpecification = specification;
        if (@available(iOS 27.0, *)) {} else {
            // on 27 manually adding this is not need, also setAdditionalExtensions: doesn't exist for some reason
            config.additionalExtensions = [NSOrderedSet orderedSetWithArray:@[
                PrivClass(_UISceneHostingEventDeferringExtension),
            ]];
        }
        self.hostingController = [[_UISceneHostingController alloc] initWithAdvancedConfiguration:config];
        /// !! do NOT use self.hostingController.sceneView here as it breaks keyboard focus on iOS 26 below. I have no idea why this happens even though both return the same object. Maybe sceneView didn't initialize its ViewController properly?
        self.contentView = self.hostingController.sceneViewController.view;
        self.contentView.clipsToBounds = NO;
        // _scenePresenter was a property in 26, but made only ivar in 27
        self.presenter = [self.contentView valueForKey:@"_scenePresenter"];
        self.sceneID = self.presenter.identifier;
        FBScene *scene = self.presenter.scene;
        [scene configureParameters:^(FBSMutableSceneParameters *parameters) {
            [parameters updateSettingsWithBlock:updateSceneSettings];
            [parameters updateClientSettingsWithBlock:updateSceneClientSettings];
        }];
        
        /// Fix keyboard focus by setting up event deferring extension. Previously we worked around it by changing identifier, but that broke other things
        _UISceneEventDeferringHostComponent *deferringComponent = self.hostingController._eventDeferringComponent;
        NSAssert(deferringComponent, @"Unexpectedly nil _UISceneEventDeferringHostComponent");
        if (@available(iOS 27.0, *)) { // _UIKeyboardArbiterUsesDeferringGraph()
            /// UIKitCore`__85-[_UIRemoteViewControllerSceneHostingImpl _viewServiceHostSessionDidConnectToClient:]_block_invoke
            /// iOS 27 requires setting up _UISceneEventDeferringHostComponent for keyboard focus to work
            
            /// Replicate these methods since they are made private
            /// -[_UISceneEventDeferringHostComponent setFirstResponderTrackingSelectionPath:]:
            [deferringComponent setValue:self forKey:@"_firstResponderTrackingSelectionPath"];
            // if (!deferringComponent->_flags.clientIsInChain) return;
            /// -[_UISceneEventDeferringHostComponent becomeFirstResponderIfNecessary]:
            // if (deferringComponent->_flags.maintainHostFirstResponderWhenClientWantsKeyboard)
            
            deferringComponent.grantBehavior = 2;
            deferringComponent.selectionRequestBehavior = 2;
        }
        /// UIKitCore`-[_UISceneHostingController createSceneWithConfiguration:]
        /// Lower iOS uses _UISceneHostingEventDeferringExtension, no further setup needed
        
        // Now it's time to get the initial settings from decorated VC
        [self.delegate appSceneVCWillActivateScene:self];
        [self addChildViewController:self.hostingController.sceneViewController];
        
        // For new API, let FBSSceneObserver send host scene events instead of NSExtensionContext
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center removeObserver:self.extension name:UIApplicationDidBecomeActiveNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillResignActiveNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillEnterForegroundNotification object:UIApp];
    } else {
        self.sceneID = [NSString stringWithFormat:@"sceneID:%@-%@", @"LiveProcess", self.dataUUID];
        FBSMutableSceneDefinition *definition = [PrivClass(FBSMutableSceneDefinition) definition];
        definition.identity = [PrivClass(FBSSceneIdentity) identityForIdentifier:self.sceneID];
        definition.clientIdentity = [PrivClass(FBSSceneClientIdentity) identityForProcessIdentity:processHandle.identity];
        definition.specification = specification;
        
        FBSMutableSceneParameters *parameters = [PrivClass(FBSMutableSceneParameters) parametersForSpecification:specification];
        [parameters updateSettingsWithBlock:updateSceneSettings];
        [parameters updateClientSettingsWithBlock:updateSceneClientSettings];
        FBScene *scene = [[PrivClass(FBSceneManager) sharedInstance] createSceneWithDefinition:definition initialParameters:parameters];
        self.presenter = [scene.uiPresentationManager createPresenterWithIdentifier:self.sceneID];
        [self.presenter modifyPresentationContext:^(UIMutableScenePresentationContext *context) {
            context.appearanceStyle = 2;
        }];
        [self.presenter activate];
        
        self.contentView = [[UIView alloc] init];
        [self.contentView addSubview:self.presenter.presentationView];
    }
    [self.view addSubview:_contentView];
    if (@available(iOS 18.0, *)) {
        [self.hostingController.sceneViewController didMoveToParentViewController:self];
    }
    
    // If we have a staging URL scheme, pass it now
    NSString *launchUrl = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    if(launchUrl) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
        [self openURLScheme:launchUrl];
    }
    
    __weak typeof(self) weakSelf = self;
    [self.extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        [weakSelf appTerminationCleanUp];
    }];
    self.contentView.layer.anchorPoint = CGPointMake(0, 0);
    self.contentView.layer.position = CGPointMake(0, 0);
    
    // Unregister later from the same scene: the view has no window by then. The
    // legacy scene ID repeats for a container, so the key is this window's own.
    self.hostScene = self.view.window.windowScene;
    self.settingsDiffKey = NSUUID.UUID.UUIDString;
    [self.hostScene _registerSettingsDiffActionArray:@[self] forKey:self.settingsDiffKey];
    [NSNotificationCenter.defaultCenter postNotificationName:@"LCMultitaskWindowsChanged" object:self];
}

- (void)terminate {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self terminate]; });
        return;
    }
    // Keep the existing extension termination path, bound to this launch.
    self.isUserTerminating = YES;
    int pid = self.pid;
    if (pid > 0 && (kill(pid, 0) == 0 || errno != ESRCH)) {
        NSUUID *identifier = self.identifier;
        NSExtension *extension = self.extension;
        [extension _kill:SIGTERM];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self.observedTerminationExit && self.pid == pid && [self.identifier isEqual:identifier] && (kill(pid, 0) == 0 || errno != ESRCH)) {
                [extension _kill:SIGKILL];
            }
        });
    } else if (pid > 0) {
        [self appTerminationCleanUp];
    }
}

- (void)finishTerminationWithError:(NSError *)error {
    void (^completion)(NSError *) = self.terminationCompletion;
    self.terminationCompletion = nil;
    ++self.terminationWaitGeneration;
    if (self.terminationExitSource) {
        dispatch_source_cancel(self.terminationExitSource);
        self.terminationExitSource = nil;
    }
    // Delegate/Dock cleanup queued by appTerminationCleanUp runs first.
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
}

- (void)finishTerminationIfPossible {
    if (self.terminationCompletion && self.observedTerminationExit && self.isTerminated) {
        [self finishTerminationWithError:nil];
    }
}

- (void)terminateWithCompletion:(void (^)(NSError *))completion {
    if (!completion) {
        [self terminate];
        return;
    }
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self terminateWithCompletion:completion]; });
        return;
    }
    if (self.terminationCompletion || self.pid <= 0) {
        NSString *message = self.terminationCompletion ? @"该应用正在结束，请勿重复重新启动" : @"应用仍在启动，无法确认要结束的进程";
        completion([NSError errorWithDomain:@"LCAppTermination" code:1 userInfo:@{NSLocalizedDescriptionKey: message}]);
        return;
    }
    int pid = self.pid;
    NSUInteger generation = ++self.terminationWaitGeneration;
    self.terminationCompletion = completion;
    self.observedTerminationExit = NO;
    if (kill(pid, 0) == -1 && errno == ESRCH) {
        self.isUserTerminating = YES;
        self.observedTerminationExit = YES;
        [self appTerminationCleanUp];
        [self finishTerminationIfPossible];
        return;
    }
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
    if (!source) {
        [self finishTerminationWithError:[NSError errorWithDomain:@"LCAppTermination" code:2 userInfo:@{NSLocalizedDescriptionKey: @"无法确认该应用是否退出，未重新启动"}]];
        return;
    }
    self.terminationExitSource = source;
    // This source retains the controller even when closing its card/window
    // removes its last UI owner. Only an exit event (or ESRCH) proves exit.
    dispatch_source_set_event_handler(source, ^{
        if (self.terminationWaitGeneration != generation || !self.terminationExitSource) return;
        if (dispatch_source_get_data(self.terminationExitSource) & DISPATCH_PROC_EXIT) {
            self.observedTerminationExit = YES;
            [self appTerminationCleanUp];
            [self finishTerminationIfPossible];
        }
    });
    dispatch_source_set_registration_handler(source, ^{
        if (self.terminationWaitGeneration == generation && kill(pid, 0) == -1 && errno == ESRCH) {
            self.observedTerminationExit = YES;
            [self appTerminationCleanUp];
            [self finishTerminationIfPossible];
        }
    });
    dispatch_resume(source);
    NSLog(@"[LC][Multitask] waiting for selected guest exit bundle=%@ container=%@ pid=%d", self.bundleId, self.dataUUID, pid);
    // closeWindow may already have sent SIGTERM; observe that same close
    // rather than sending a second signal/escalation sequence.
    if (!self.isUserTerminating) [self terminate];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || self.terminationWaitGeneration != generation || !self.terminationCompletion) return;
        NSString *message = [NSString stringWithFormat:@"等待应用进程退出超时（PID %d），未重新启动以避免重复运行", pid];
        [self finishTerminationWithError:[NSError errorWithDomain:@"LCAppTermination" code:3 userInfo:@{NSLocalizedDescriptionKey: message}]];
    });
}

- (void)_performActionsForUIScene:(UIScene *)scene withUpdatedFBSScene:(id)fbsScene settingsDiff:(FBSSceneSettingsDiff *)diff fromSettings:(UIApplicationSceneSettings *)settings transitionContext:(id)context lifecycleActionType:(uint32_t)actionType {
    if(!self.isAppRunning) {
        [self appTerminationCleanUp];
    }
    if(!diff) return;
    
    UIMutableApplicationSceneSettings *baseSettings = [diff settingsByApplyingToMutableCopyOfSettings:settings];
    UIApplicationSceneTransitionContext *newContext = [context copy];
    newContext.actions = nil;
    [self.delegate appSceneVC:self didUpdateFromSettings:baseSettings transitionContext:newContext lifecycleActionType:actionType];
}

- (void)viewWillLayoutSubviews {
    /// For native window we let iPadOS handle it however it wants, which is usually live resize (autoresizingMask set in appSceneVCWillActivateScene)
    if(_contentView.autoresizingMask != (UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight)) {
        [self updateFrameWithSettingsBlock:nil];
    }
}
- (void)updateFrameWithSettingsBlock:(void (^)(UIMutableApplicationSceneSettings *settings))block {
    __block int currentDebounceToken = ++_resizeDebounceToken;
    dispatch_block_t queueBlock = ^{
        if(currentDebounceToken != self.resizeDebounceToken) {
            return;
        }
        [self updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            settings.deviceOrientation = UIDevice.currentDevice.orientation;
            settings.interfaceOrientation = self.view.window.windowScene.interfaceOrientation;
            CGRect frame = self.view.frame;
            if(!self.usesHostingControllerAPI) {
                frame.size.width /= self.scaleRatio;
                frame.size.height /= self.scaleRatio;
            }
            if(UIInterfaceOrientationIsLandscape(settings.interfaceOrientation)) {
                CGSize size = frame.size;
                frame.size.width = size.height;
                frame.size.height = size.width;
            }
            settings.frame = frame;
            if(block) {
                block(settings);
            }
        }];
    };
    if(_shouldSkipDebounceOnce) {
        _shouldSkipDebounceOnce = NO;
        queueBlock();
    } else {
        dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC));
        dispatch_after(delay, dispatch_get_main_queue(), queueBlock);
    }
}
- (void)updateSettingsWithBlock:(void(^)(UIMutableApplicationSceneSettings *settings))updateSettingsBlock {
    if(_shouldIgnoreSceneUpdates) {
        // Ignore all updates when in PiP mode
        return;
    }
    
    if(!_hostingController && self.contentView) {
        // The legacy presenter has no view-geometry publisher. Apply the
        // viewport's clearance at the end of every update, including resizes.
        [self.presenter.scene updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            updateSettingsBlock(settings);
            if (self.view.window && !CGRectIsEmpty(self.view.bounds)) {
                UIEdgeInsets insets = LCGuestSceneSafeAreaInsets(self.view, self.view, self.additionalSafeAreaInsets);
                CGFloat scale = self.scaleRatio;
                LCApplyGuestSceneSafeAreaInsets(settings, UIEdgeInsetsMake(insets.top / scale, insets.left / scale, insets.bottom / scale, insets.right / scale));
                LCApplyGuestSceneStatusBarFrame(settings, self.view, scale);
            }
        }];
        return;
    }

    FBScene *scene = self.presenter.scene;
    UIMutableApplicationSceneSettings *tempSettings = [scene.settings mutableCopy];
    if(!tempSettings) {
        tempSettings = [UIMutableApplicationSceneSettings new];
    }
    updateSettingsBlock(tempSettings);
    if (self.contentView) {
        // UIKit owns the hosted scene's frame. Size its actual surface to the
        // container instead of feeding a scene frame back into a transformed
        // UIView.frame (which is undefined and shrinks again at non-unit scale).
        CGFloat scale = self.scaleRatio;
        if (!CGRectIsEmpty(self.view.bounds)) {
            CGRect bounds = CGRectMake(0, 0, self.view.bounds.size.width / scale, self.view.bounds.size.height / scale);
            if (!CGRectEqualToRect(self.contentView.bounds, bounds)) self.contentView.bounds = bounds;
            self.contentView.layer.anchorPoint = CGPointZero;
            self.contentView.layer.position = CGPointZero;
        }

        // This method publishes a complete settings object directly. Do not
        // depend on that private FrontBoard path invoking the hosting hook.
        // An attached surface already converts through its scale; only the
        // unattached-container seed needs an explicit scale conversion.
        UIView *viewport = self.contentView.window ? self.contentView : self.view;
        CGFloat viewportScale = viewport == self.contentView ? 1 : scale;
        if (self.view.window && viewport.window == self.view.window && !CGRectIsEmpty(viewport.bounds)) {
            UIEdgeInsets insets = LCGuestSceneSafeAreaInsets(viewport, self.view, self.additionalSafeAreaInsets);
            LCApplyGuestSceneSafeAreaInsets(tempSettings, UIEdgeInsetsMake(insets.top / viewportScale, insets.left / viewportScale, insets.bottom / viewportScale, insets.right / viewportScale));
            LCApplyGuestSceneStatusBarFrame(tempSettings, viewport, viewportScale);
        }
        // Once attached, UIKit owns the hosted scene's display frame. Before
        // attachment its settings may still contain zero or an earlier size:
        // retain the caller's initial viewport instead of replaying that frame.
        CGRect hostedFrame = scene.settings.frame;
        if (self.contentView.window && !CGRectIsEmpty(hostedFrame)) {
            tempSettings.frame = hostedFrame;
        }
        [scene updateSettings:tempSettings withTransitionContext:nil completion:nil];
    } else {
        // Early legacy setup, before a presentation view exists.
        CGRect frame = tempSettings.frame;
        if(UIInterfaceOrientationIsLandscape(tempSettings.interfaceOrientation)) {
            frame = CGRectMake(frame.origin.x, frame.origin.y, frame.size.height, frame.size.width);
        }
        self.view.frame = frame;
    }
}

- (BOOL)isAppRunning {
    return _pid > 0 && getpgid(_pid) > 0;
}

- (void)appTerminationCleanUp {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self appTerminationCleanUp]; });
        return;
    }
    // The request-invalidation callback can win the race with the proc
    // source. ESRCH is another exit proof; EPERM must never count as exit.
    if (self.terminationCompletion && self.pid > 0 && kill(self.pid, 0) == -1 && errno == ESRCH) {
        self.observedTerminationExit = YES;
    }
    if(_isAppTerminationCleanUpCalled) {
        [self finishTerminationIfPossible];
        return;
    }
    _isAppTerminationCleanUpCalled = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        if(self.sceneID) {
            [[PrivClass(FBSceneManager) sharedInstance] destroyScene:self.sceneID withTransitionContext:nil];
            self.sceneID = nil;
        }
        if(self.usesHostingControllerAPI) {
            if(@available(iOS 17.0, *)) {
                [self.hostingController invalidate];
                [self.hostingController.sceneViewController removeFromParentViewController];
                self.hostingController = nil;
            }
        } else if(self.presenter){
            [self.presenter deactivate];
            [self.presenter invalidate];
        }
        self.presenter = nil;
        if (self.settingsDiffKey) {
            [self.hostScene _unregisterSettingsDiffActionArrayForKey:self.settingsDiffKey];
            self.hostScene = nil;
            self.settingsDiffKey = nil;
        }
        self.isTerminated = YES;
        [self.delegate appSceneVCAppDidExit:self];
        [MultitaskManager unregisterMultitaskContainerWithContainer:self.dataUUID];
        [NSNotificationCenter.defaultCenter postNotificationName:@"LCMultitaskWindowsChanged" object:self];
        [self finishTerminationIfPossible];
    });
}

- (void)setBackgroundNotificationEnabled:(bool)enabled {
    if(self.usesHostingControllerAPI) {
        /// Issue with new API: FBSSceneObserver takes priority over to send UIApplicationWillResignActiveNotification regressed #942,
        /// so here we make it foreground (UIApplicationDidBecomeActiveNotification) again.
        [self.presenter.scene updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            settings.foreground = YES;
            settings.deactivationReasons = 0;
        }];
        return;
    }
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if(enabled) {
        // Re-add UIApplicationDidEnterBackgroundNotification
        [center addObserver:self.extension selector:@selector(_hostDidEnterBackgroundNote:) name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center addObserver:self.extension selector:@selector(_hostWillResignActiveNote:) name:UIApplicationWillResignActiveNotification object:UIApp];
    } else {
        // Remove UIApplicationDidEnterBackgroundNotification so apps like YouTube can continue playing video
        [center removeObserver:self.extension name:UIApplicationDidEnterBackgroundNotification object:UIApp];
        [center removeObserver:self.extension name:UIApplicationWillResignActiveNotification object:UIApp];
    }
}

- (void)viewDidMoveToWindow:(UIWindow *)newWindow shouldAppearOrDisappear:(BOOL)appear {
    [super viewDidMoveToWindow:newWindow shouldAppearOrDisappear:appear];
    if(!newWindow) {
        if(self.settingsDiffKey) {
            [self.hostScene _unregisterSettingsDiffActionArrayForKey:self.settingsDiffKey];
            self.hostScene = nil;
            self.settingsDiffKey = nil;
        }
        self.delegate = nil;
    }
}

- (void)openURLScheme:(NSString *)urlString {
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        // pull from UserDefaults.standard.setValue(launchURLStr, forKey: "launchAppUrlScheme")
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        NSURL *url = [NSURL URLWithString:urlString];
        context.payload = @{UIApplicationLaunchOptionsURLKey: urlString};
        context.actions = [NSSet setWithObject:[[UIOpenURLAction alloc] initWithURL:url]];
        return context;
    }];
}

- (void)handleStatusBarTapAction:(UIAction *)action {
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        context.actions = [NSSet setWithObject:action];
        return context;
    }];
}

- (BOOL)usesHostingControllerAPI {
    return _hostingController != nil;
}

@end
 

#pragma mark - 多任务最小化

// 访客进程 (LiveProcess) 单击主屏按键时发 Darwin 通知, 宿主把所有多任务窗口
// 收进 Dock, 扩展进程保持存活; 随后 zContainer 被拉到前台.
static void LCMinimizeControllerTree(UIViewController *controller) {
    if (!controller) return;
    if ([controller respondsToSelector:NSSelectorFromString(@"minimizeWindow")]) {
        [(id)controller minimizeWindow];
    }
    for (UIViewController *child in controller.childViewControllers) {
        LCMinimizeControllerTree(child);
    }
    LCMinimizeControllerTree(controller.presentedViewController);
}

static void LCMinimizeAllMultitaskWindows(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object,
                                          CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (NSUserDefaults.lcGuestAppId || NSUserDefaults.isLiveProcess) return;
        NSLog(@"[TDHome] minimizeAll notification received");
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                LCMinimizeControllerTree(window.rootViewController);
            }
        }
    });
}

__attribute__((constructor))
static void LCRegisterMinimizeAllNotification(void) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    LCMinimizeAllMultitaskWindows,
                                    CFSTR("com.kdt.livecontainer.minimizeAll"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

// 双击辅助触控 -> 打开堆叠后台界面(图五). 通知由访客进程里的 Home 按钮发出;
// 堆叠界面属于宿主(只有宿主知道每个访客窗口), 所以在这里接.
static void LCShowAppStackNotification(CFNotificationCenterRef center, void *observer,
                                       CFStringRef name, const void *object,
                                       CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // A fullscreen guest runs inside this process, so its double tap can
        // open the stack over the guest window directly. A multitask guest's
        // LiveProcess has no manager; the host receives this notification.
        // A fullscreen guest posts this and then goes home; delay so the stack
        // opens on the Home Screen instead of racing the guest window.
        BOOL insideGuest = NSUserDefaults.lcGuestAppId != nil || NSUserDefaults.isLiveProcess;
        void (^open)(void) = ^{
            if (@available(iOS 16.0, *)) {
                NSLog(@"[TDHome] app stack request received; opening");
                [MultitaskStackManager.shared present];
            }
        };
        if (insideGuest) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), open);
        } else {
            open();
        }
    });
}

__attribute__((constructor))
static void LCRegisterShowAppStackNotification(void) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    LCShowAppStackNotification,
                                    CFSTR("com.kdt.livecontainer.showAppStack"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    // A classic fullscreen guest restarts this process to return home. Its
    // request must survive that restart, even if the Darwin message arrived
    // before this framework was loaded. The manager reads that request and
    // waits for scene activation instead of presenting on a guest's window.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (NSUserDefaults.lcGuestAppId || NSUserDefaults.isLiveProcess) return;
        if (@available(iOS 16.0, *)) {
            (void)[MultitaskStackManager shared];
        }
    });
}
