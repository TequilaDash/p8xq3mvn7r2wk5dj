#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "LCUtils.h"

typedef NS_ENUM(NSInteger, LCOrientationLock){
    Disabled = 0,
    Landscape = 1,
    Portrait = 2
};

typedef NS_ENUM(NSInteger, MultitaskSpecified){
    MultitaskSpecifiedDefault = 0,
    MultitaskSpecifiedNo = 1,
    MultitaskSpecifiedYes = 2
};


@interface LCAppInfo : NSObject {
    NSMutableDictionary* _info;
    NSMutableDictionary* _infoPlist;
    NSString* _bundlePath;
}
@property NSString* relativeBundlePath;
@property bool isShared;
@property bool isJITNeeded;
@property bool helperProcessesSupport;
@property bool classicMode;
@property (nonatomic, readonly) NSUInteger defaultClassicMode;
@property bool isLocked;
@property bool isHidden;
@property bool doSymlinkInbox;
@property bool hideLiveContainer;
@property bool dontLoadTweakLoader;
@property bool dontInjectTweakLoader;
@property LCOrientationLock orientationLock;
@property MultitaskSpecified multitaskSpecified;
@property bool fixFilePickerNew;
@property bool fixLocalNotification;
@property bool fixBackgroundTaskIdentifiers;
@property bool doUseLCBundleId;
// 本仓适配 (M18, 2026-11-13): 巢中巢兼容开关（实验性）。
// 访客 App 自身是另一个 LiveContainer 时，两套 NSFileManager hooks 会互相成环；
// 打开后跳过本仓的 guest hooks，交给访客自带的那套处理。
@property bool nestedLCCompat;
// 本仓功能 (M22, 2026-11-13): 禁止访客联网（按 App 存，LCAppInfo.plist 键 TDNetBlock）.
@property bool netBlock;
// 本仓功能 (M36): vroot 模式 (TDVRoot: off|path|full)
@property (copy) NSString *vrootMode;
// 本仓功能 (M38/M39): TMPDIR 隔离 / APFS 快照 (CoW), 均 per-app opt-in
@property bool isolateTmpDir;
@property bool cowSnapshot;
// 本仓功能 (隐藏体系 M41+): sysctl 伪值表 / SecTask entitlement 隐藏 /
// csops 伪 CS flags / proc 族伪值, 均 per-app opt-in (audit v2 §四).
@property bool sysctlSpoof;
@property bool secTaskSpoof;
@property bool csopsSpoof;
@property bool procSpoof;
@property NSString* selectedLanguage;
@property NSString* dataUUID;
@property NSString* tweakFolder;
@property NSArray<NSDictionary*>* containerInfo;
@property bool autoSaveDisabled;
@property bool dontSign;
@property bool spoofSDKVersion;
@property (nonatomic, strong) NSString* jitLaunchScriptJs;
@property (nonatomic, strong) NSString* selected32BitEmulator;
@property NSDate* lastLaunched;
@property NSDate* installationDate;
@property NSString* remark;
@property bool is32bit;
@property(readonly) bool is32bitEmulator;
@property UIColor* cachedColor;
@property UIColor* cachedColorDark;
@property UIImage* cachedIcon;
@property UIImage* cachedIconDark;

- (void)setBundlePath:(NSString*)newBundlePath;
- (NSMutableDictionary*)info;
- (UIImage*)iconIsDarkIcon:(BOOL)isDarkIcon;
- (void)clearIconCache;
- (NSString*)displayName;
- (NSString*)bundlePath;
- (NSString*)bundleIdentifier;
- (NSString*)version;
- (NSMutableArray<NSString *>*)urlSchemes;
- (instancetype)initWithBundlePath:(NSString*)bundlePath;
- (UIImage *)generateLiveContainerWrappedIconWithStyle:(GeneratedIconStyle)style;
- (NSDictionary *)generateWebClipConfigWithContainerId:(NSString*)containerId iconStyle:(GeneratedIconStyle)style;
- (void)save;
- (void)patchExecAndSignIfNeedWithCompletionHandler:(void(^)(bool success, NSString* errorInfo))completetionHandler progressHandler:(void(^)(NSProgress* progress))progressHandler  forceSign:(BOOL)forceSign;
@end
