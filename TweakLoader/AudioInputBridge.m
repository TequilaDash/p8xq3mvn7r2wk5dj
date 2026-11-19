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

// 独立音频桥日志：只记本桥的调用（guest 请求 + 宿主代答结果），不与
// ConsoleLog/exploit 日志混用。文件在 app group 根 TDAudioBridge/ 下。
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

// 麦克风 TCC 权限与前台 scene，AVAudioSession 激活/麦克风授权由宿主
// (zContainer) 代答，结果经 app group 回传。音频数据面不动；开关
// (TDAudioInputBridge) 关闭时全部直通原实现。

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

static void TDPostDarwin(NSString *name) {
    notify_post(name.UTF8String);
}

// 通知宿主重放一次同参数的 session 调用（参数经 app group 键传递）。
static void TDRequestHostReplay(NSDictionary *payload) {
    NSUserDefaults *suite = TDAppGroupDefaults();
    if (!suite) return;
    [suite setObject:payload forKey:@"TDAudioBridgeRequest"];
    [suite synchronize];
    TDPostDarwin(@"com.td.audioBridge.request");
}

// 等宿主把结果写回 app group；最多 2 秒。
static BOOL TDWaitHostResult(NSString *key) {
    NSUserDefaults *suite = TDAppGroupDefaults();
    if (!suite) return NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while ([deadline timeIntervalSinceNow] > 0) {
        [suite synchronize];
        NSNumber *done = [suite objectForKey:key];
        if (done) {
            [suite removeObjectForKey:key];
            [suite synchronize];
            return done.boolValue;
        }
        usleep(50 * 1000);
    }
    return NO;
}

static IMP orig_setCategoryWithOptionsError;
static IMP orig_setActiveWithOptionsError;
static IMP orig_requestRecordPermission;

static BOOL TD_hook_setCategory_withOptions_error(id self, SEL _cmd, NSString *category, NSUInteger options, NSError **error) {
    BOOL (*orig)(id, SEL, NSString *, NSUInteger, NSError **) = (void *)orig_setCategoryWithOptionsError;
    BOOL ok = orig(self, _cmd, category, options, error);
    TDAudioBridgeLog(@"setCategory %@ options=%lu -> %@", category ?: @"nil", (unsigned long)options, ok ? @"ok" : @"fail");
    if (!ok && category && TDAudioBridgeEnabled()) {
        TDAudioBridgeLog(@"setCategory fail -> bridge to host");
        TDRequestHostReplay(@{@"kind": @"setCategory", @"category": category, @"options": @(options)});
        if (TDWaitHostResult(@"TDAudioBridgeResult")) {
            ok = orig(self, _cmd, category, options, error);
            TDAudioBridgeLog(@"setCategory after bridge -> %@", ok ? @"ok" : @"fail");
        }
    }
    return ok;
}

static BOOL TD_hook_setActive_withOptions_error(id self, SEL _cmd, BOOL active, NSUInteger options, NSError **error) {
    BOOL (*orig)(id, SEL, BOOL, NSUInteger, NSError **) = (void *)orig_setActiveWithOptionsError;
    BOOL ok = orig(self, _cmd, active, options, error);
    TDAudioBridgeLog(@"setActive %d options=%lu -> %@", active, (unsigned long)options, ok ? @"ok" : @"fail");
    if (!ok && active && TDAudioBridgeEnabled()) {
        TDAudioBridgeLog(@"setActive fail -> bridge to host");
        TDRequestHostReplay(@{@"kind": @"setActive", @"active": @(active), @"options": @(options)});
        if (TDWaitHostResult(@"TDAudioBridgeResult")) {
            ok = orig(self, _cmd, active, options, error);
            TDAudioBridgeLog(@"setActive after bridge -> %@", ok ? @"ok" : @"fail");
        }
    }
    return ok;
}

static void TD_hook_requestRecordPermission(id self, SEL _cmd, void (^completion)(BOOL)) {
    void (*orig)(id, SEL, void (^)(BOOL)) = (void *)orig_requestRecordPermission;
    if (!TDAudioBridgeEnabled()) {
        orig(self, _cmd, completion);
        return;
    }
    NSUserDefaults *suite = TDAppGroupDefaults();
    if (!suite) {
        orig(self, _cmd, completion);
        return;
    }
    [suite removeObjectForKey:@"TDAudioBridgeMicGranted"];
    [suite synchronize];
    TDAudioBridgeLog(@"requestRecordPermission -> bridge to host");
    TDPostDarwin(@"com.td.audioBridge.requestMic");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL granted = NO;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
        while ([deadline timeIntervalSinceNow] > 0) {
            [suite synchronize];
            NSNumber *v = [suite objectForKey:@"TDAudioBridgeMicGranted"];
            if (v) { granted = v.boolValue; break; }
            usleep(100 * 1000);
        }
        TDAudioBridgeLog(@"requestRecordPermission result=%d%@", granted, (granted ? @"" : @" (timeout treated as deny)"));
        if (completion) completion(granted);
    });
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
