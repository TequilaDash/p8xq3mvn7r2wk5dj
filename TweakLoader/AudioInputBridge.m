#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import <stdint.h>

#import "../LiveContainer/utils.h"
#import "HomeButton/LCHomeButtonController.h"
static NSString *TDAppGroupID(void);
static NSUserDefaults *TDAppGroupDefaults(void);

// Guest AVAudioSession diagnostics only; no audio samples cross process boundaries.
// The text log lives under the app-group TDAudioBridge directory.
static NSString *TDAudioBridgeLogDir(void) {
    NSString *groupID = TDAppGroupID();
    if (!groupID) return nil;
    NSURL *groupURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:groupID];
    if (!groupURL) return nil;
    NSURL *dir = [groupURL URLByAppendingPathComponent:@"TDAudioBridge"];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir.path;
}

static void TDAudioBridgeLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void TDAudioBridgeLog(NSString *fmt, ...) {
    NSString *dir = TDAudioBridgeLogDir();
    if (!dir) return;
    va_list args;
    va_start(args, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *stamp = [df stringFromDate:[NSDate date]];
    NSString *guest = NSUserDefaults.lcGuestAppId ?: @"-";
    NSString *out = [NSString stringWithFormat:@"[%@] [%@] %@\n", stamp, guest, line];
    NSString *path = [dir stringByAppendingPathComponent:@"bridge.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [out writeToFile:path atomically:YES];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

// 1.1.54 设计（宿主代答）在真机上双重失败：
//   1) 宿主 setActive(true) 会在宿主进程激活它自己的 AVAudioSession，
//      直接打断后台正在播放的 App（用户 QQ 音乐"上次播放被系统中断"）；
//   2) 结果只对宿主进程生效，LiveProcess 扩展进程自己的 session 仍然
//      没激活，输入音频照旧不工作。
// 1.1.55 改为扩展进程直通：LiveProcess 多任务窗口有前台 scene，可以自己
//   setCategory/setActive/requestRecordPermission（TCC 弹窗在多任务窗口
//   前台时正常出现并落库到扩展进程自己的权限记录）。不再有任何跨进程
//   session 操作。钩子保留只做日志；开关(TDAudioInputBridge)只控制是否记日志。

static BOOL TDAudioBridgeEnabled(void) {
    NSNumber *value = LCHomeButtonNumberSetting(@"TDAudioInputBridge");
    return value ? value.boolValue : NO;
}

static NSString *TDAppGroupID(void) {
    Class sharedUtils = NSClassFromString(@"LCSharedUtils");
    if ([sharedUtils respondsToSelector:@selector(appGroupID)]) {
        return ((NSString *(*)(id, SEL))objc_msgSend)(sharedUtils, @selector(appGroupID));
    }
    return nil;
}

static NSUserDefaults *TDAppGroupDefaults(void) {
    NSString *groupID = TDAppGroupID();
    return groupID ? [[NSUserDefaults alloc] initWithSuiteName:groupID] : nil;
}

static IMP orig_setCategoryWithOptionsError;
static IMP orig_setActiveWithOptionsError;
static IMP orig_requestRecordPermission;

static BOOL TD_hook_setCategory_withOptions_error(id self, SEL _cmd, NSString *category, NSUInteger options, NSError **error) {
    BOOL (*orig)(id, SEL, NSString *, NSUInteger, NSError **) = (void *)orig_setCategoryWithOptionsError;
    BOOL ok = orig(self, _cmd, category, options, error);
    if (TDAudioBridgeEnabled()) {
        TDAudioBridgeLog(@"setCategory %@ options=%lu -> %@", category ?: @"nil", (unsigned long)options, ok ? @"ok" : @"fail");
    }
    return ok;
}

static BOOL TD_hook_setActive_withOptions_error(id self, SEL _cmd, BOOL active, NSUInteger options, NSError **error) {
    BOOL (*orig)(id, SEL, BOOL, NSUInteger, NSError **) = (void *)orig_setActiveWithOptionsError;
    BOOL ok = orig(self, _cmd, active, options, error);
    if (TDAudioBridgeEnabled()) {
        TDAudioBridgeLog(@"setActive %d options=%lu -> %@", active, (unsigned long)options, ok ? @"ok" : @"fail");
    }
    return ok;
}

static void TD_hook_requestRecordPermission(id self, SEL _cmd, void (^completion)(BOOL)) {
    void (*orig)(id, SEL, void (^)(BOOL)) = (void *)orig_requestRecordPermission;
    if (TDAudioBridgeEnabled()) {
        TDAudioBridgeLog(@"requestRecordPermission -> direct to current process; result is not captured");
    }
    orig(self, _cmd, completion);
}

__attribute__((constructor))
static void TDAudioInputBridgeInit(void) {
    if (!NSUserDefaults.lcGuestAppId) return; // guests only
    dlopen("/System/Library/Frameworks/AVFAudio.framework/AVFAudio", RTLD_LAZY);
    dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_LAZY);
    Class session = NSClassFromString(@"AVAudioSession");
    if (!session) return;
    Method m1 = class_getInstanceMethod(session, NSSelectorFromString(@"setCategory:withOptions:error:"));
    if (m1) { orig_setCategoryWithOptionsError = method_getImplementation(m1); method_setImplementation(m1, (IMP)TD_hook_setCategory_withOptions_error); }
    Method m2 = class_getInstanceMethod(session, NSSelectorFromString(@"setActive:withOptions:error:"));
    if (m2) { orig_setActiveWithOptionsError = method_getImplementation(m2); method_setImplementation(m2, (IMP)TD_hook_setActive_withOptions_error); }
    Method m3 = class_getInstanceMethod(session, NSSelectorFromString(@"requestRecordPermission:"));
    if (m3) { orig_requestRecordPermission = method_getImplementation(m3); method_setImplementation(m3, (IMP)TD_hook_requestRecordPermission); }
}
