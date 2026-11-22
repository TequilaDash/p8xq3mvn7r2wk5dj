#import <Foundation/Foundation.h>
#import "Tweaks.h"
#import <objc/runtime.h>

@interface NSUserDefaults (LiveContainerGuestID)
+ (NSString *)lcGuestAppId;
@end

@implementation NSString(LiveContainer)
- (NSString *)lc_realpath {
    // stringByResolvingSymlinksInPath does not fully resolve symlink, and some apps will crash without /private prefix
    char result[PATH_MAX];
    realpath(self.fileSystemRepresentation, result);
    return [NSString stringWithUTF8String:result];
}
@end
@implementation NSBundle(LiveContainer)
// Built-in initWith* will strip out the /private prefix, which could crash certain apps
// This initializer replicates +[NSBundle mainBundle] to solve this issue
- (instancetype)initWithPathForMainBundle:(NSString *)path {
    CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:path.lc_realpath];
    id cfBundle = CFBridgingRelease(CFBundleCreate(NULL, url));
    if(!cfBundle) return nil;
    self = [self initWithPath:path];
    object_setIvar(self, class_getInstanceVariable(self.class, "_cfBundle"), cfBundle);
    return self;
}
@end

static IMP origBundleIdentifier = NULL;

static NSString *hook_bundleIdentifier(NSBundle *bundle, SEL _cmd) {
    NSString *guestID = NSUserDefaults.lcGuestAppId;
    if (guestID.length > 0) {
        NSBundle *mainBundle = NSBundle.mainBundle;
        if (bundle == mainBundle || [bundle.bundlePath isEqualToString:mainBundle.bundlePath]) {
            return guestID;
        }
    }
    return ((NSString *(*)(id, SEL))origBundleIdentifier)(bundle, _cmd);
}

static IMP origBundlePath = NULL;

// 镜像枚举对外给的是 /var/containers/Bundle/Application/<uuid>/<App>.app/... 的伪路径。
// NSBundle 必须给同一个视图, 否则检测器把 _dyld_get_image_name 和 bundlePath 一比
// 就是"从可写目录加载的注入镜像"。实现与掩码逻辑在 LiveContainer/Tweaks/Dyld.m。
extern const char *tdv_masked_image_name(const char *realName) __attribute__((weak));

static NSString *hook_bundlePath(NSBundle *bundle, SEL _cmd) {
    NSString *real = ((NSString *(*)(id, SEL))origBundlePath)(bundle, _cmd);
    if (real.length == 0 || !tdv_masked_image_name) {
        return real;
    }
    const char *masked = tdv_masked_image_name(real.UTF8String);
    if (masked && strcmp(masked, real.UTF8String) != 0) {
        return [NSString stringWithUTF8String:masked];
    }
    return real;
}

void NSBundleGuestHooksInit(void) {
    static bool installed = false;
    if (installed) return;
    installed = true;
    Method method = class_getInstanceMethod(NSBundle.class, @selector(bundleIdentifier));
    if (method) {
        origBundleIdentifier = method_getImplementation(method);
        method_setImplementation(method, (IMP)hook_bundleIdentifier);
    }
    Method pathMethod = class_getInstanceMethod(NSBundle.class, @selector(bundlePath));
    if (pathMethod) {
        origBundlePath = method_getImplementation(pathMethod);
        method_setImplementation(pathMethod, (IMP)hook_bundlePath);
    }
}
