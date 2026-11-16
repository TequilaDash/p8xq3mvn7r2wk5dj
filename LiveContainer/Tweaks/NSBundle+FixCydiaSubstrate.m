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

void NSBundleGuestHooksInit(void) {
    static bool installed = false;
    if (installed) return;
    installed = true;
    Method method = class_getInstanceMethod(NSBundle.class, @selector(bundleIdentifier));
    if (!method) return;
    origBundleIdentifier = method_getImplementation(method);
    method_setImplementation(method, (IMP)hook_bundleIdentifier);
}
