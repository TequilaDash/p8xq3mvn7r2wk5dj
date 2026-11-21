@import Foundation;
#import "utils.h"
#import "LCSharedUtils.h"
#import "Tweaks.h"
#include "../../litehook/src/litehook.h"
#include "../LCMachOUtils.h"
#include <dlfcn.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/syslimits.h>
#include "../../iManager/HideShim/TDVRootConfig.h"

typedef TDVGuestFileMapResult (*LCOriginalFileMapper)(const char *, const char *, char *, size_t);
static _Atomic(LCOriginalFileMapper) lcOriginalFileMapper;

// Foundation's libc calls identify Foundation as their caller, not the guest.
// Resolve only exact original-artifact mappings at the public read boundary.
// No stack walk, path guessing, content generation or native task impersonation.
static NSString *lc_original_read_path(NSString *path, void *caller) {
    if (!path.isAbsolutePath || !caller) return path;
    Dl_info info = {0};
    if (!dladdr(caller, &info) || !info.dli_fname ||
        !strstr(info.dli_fname, "/Documents/Applications/")) return path;
    LCOriginalFileMapper mapper = atomic_load(&lcOriginalFileMapper);
    if (!mapper) {
        // NSFM hooks are installed before TweakLoader. A failed early lookup
        // must not permanently cache its absence or add a linker dependency.
        mapper = (LCOriginalFileMapper)dlsym(RTLD_DEFAULT, "TDVGuestMapBundleFile");
        if (!mapper) return path;
        atomic_store(&lcOriginalFileMapper, mapper);
    }
    char original[PATH_MAX];
    if (mapper(path.fileSystemRepresentation, info.dli_fname, original, sizeof(original)) != TDVGuestFileMapTo) return path;
    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:original length:strlen(original)] ?: path;
}

static NSURL *lc_original_read_url(NSURL *url, void *caller) {
    if (!url.isFileURL) return url;
    NSString *path = url.path;
    NSString *original = lc_original_read_path(path, caller);
    return original == path ? url : [NSURL fileURLWithPath:original];
}

static NSFileHandle *(*lc_orig_handle_read_path)(id, SEL, NSString *);
static NSFileHandle *(*lc_orig_handle_read_url)(id, SEL, NSURL *, NSError *__autoreleasing *);
static NSData *(*lc_orig_data_read_path)(id, SEL, NSString *);
static NSData *(*lc_orig_data_read_url)(id, SEL, NSURL *);
static NSData *(*lc_orig_data_read_path_options)(id, SEL, NSString *, NSDataReadingOptions, NSError *__autoreleasing *);
static NSData *(*lc_orig_data_read_url_options)(id, SEL, NSURL *, NSDataReadingOptions, NSError *__autoreleasing *);

static NSFileHandle *lc_handle_read_path(id cls, SEL cmd, NSString *path) {
    return lc_orig_handle_read_path(cls, cmd, lc_original_read_path(path, __builtin_return_address(0)));
}

static NSFileHandle *lc_handle_read_url(id cls, SEL cmd, NSURL *url, NSError *__autoreleasing *error) {
    return lc_orig_handle_read_url(cls, cmd, lc_original_read_url(url, __builtin_return_address(0)), error);
}

static NSData *lc_data_read_path(id cls, SEL cmd, NSString *path) {
    return lc_orig_data_read_path(cls, cmd, lc_original_read_path(path, __builtin_return_address(0)));
}

static NSData *lc_data_read_url(id cls, SEL cmd, NSURL *url) {
    return lc_orig_data_read_url(cls, cmd, lc_original_read_url(url, __builtin_return_address(0)));
}

static NSData *lc_data_read_path_options(id cls, SEL cmd, NSString *path, NSDataReadingOptions options, NSError *__autoreleasing *error) {
    return lc_orig_data_read_path_options(cls, cmd, lc_original_read_path(path, __builtin_return_address(0)), options, error);
}

static NSData *lc_data_read_url_options(id cls, SEL cmd, NSURL *url, NSDataReadingOptions options, NSError *__autoreleasing *error) {
    return lc_orig_data_read_url_options(cls, cmd, lc_original_read_url(url, __builtin_return_address(0)), options, error);
}

@interface NSData (LCOriginalReadInitializers)
- (instancetype)lc_original_initWithContentsOfFile:(NSString *)path __attribute__((objc_method_family(init)));
- (instancetype)lc_original_initWithContentsOfURL:(NSURL *)url __attribute__((objc_method_family(init)));
- (instancetype)lc_original_initWithContentsOfFile:(NSString *)path options:(NSDataReadingOptions)options error:(NSError *__autoreleasing *)error __attribute__((objc_method_family(init)));
- (instancetype)lc_original_initWithContentsOfURL:(NSURL *)url options:(NSDataReadingOptions)options error:(NSError *__autoreleasing *)error __attribute__((objc_method_family(init)));
@end

@implementation NSData (LCOriginalReadInitializers)
- (instancetype)lc_original_initWithContentsOfFile:(NSString *)path {
    return [self lc_original_initWithContentsOfFile:lc_original_read_path(path, __builtin_return_address(0))];
}
- (instancetype)lc_original_initWithContentsOfURL:(NSURL *)url {
    return [self lc_original_initWithContentsOfURL:lc_original_read_url(url, __builtin_return_address(0))];
}
- (instancetype)lc_original_initWithContentsOfFile:(NSString *)path options:(NSDataReadingOptions)options error:(NSError *__autoreleasing *)error {
    return [self lc_original_initWithContentsOfFile:lc_original_read_path(path, __builtin_return_address(0)) options:options error:error];
}
- (instancetype)lc_original_initWithContentsOfURL:(NSURL *)url options:(NSDataReadingOptions)options error:(NSError *__autoreleasing *)error {
    return [self lc_original_initWithContentsOfURL:lc_original_read_url(url, __builtin_return_address(0)) options:options error:error];
}
@end

static void lc_install_data_initializer(Class placeholder, SEL selector, SEL alias) {
    Method native = class_getInstanceMethod(placeholder, selector);
    Method wrapper = class_getInstanceMethod(NSData.class, alias);
    if (!native || !wrapper) return;
    const char *types = method_getTypeEncoding(native);
    // NSData is a class cluster: do not exchange an inherited method on every
    // subclass, or add a second hook to an already-installed concrete class.
    if (!class_addMethod(placeholder, alias, method_getImplementation(native), types)) return;
    if (!class_addMethod(placeholder, selector, method_getImplementation(wrapper), types)) {
        method_setImplementation(class_getInstanceMethod(placeholder, selector), method_getImplementation(wrapper));
    }
}

static void lc_install_read_method(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getClassMethod(cls, selector);
    if (!method) return;
    *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
}

static void lc_install_original_file_read_hooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lc_install_read_method(NSFileHandle.class, @selector(fileHandleForReadingAtPath:), (IMP)lc_handle_read_path, (IMP *)&lc_orig_handle_read_path);
        lc_install_read_method(NSFileHandle.class, @selector(fileHandleForReadingFromURL:error:), (IMP)lc_handle_read_url, (IMP *)&lc_orig_handle_read_url);
        lc_install_read_method(NSData.class, @selector(dataWithContentsOfFile:), (IMP)lc_data_read_path, (IMP *)&lc_orig_data_read_path);
        lc_install_read_method(NSData.class, @selector(dataWithContentsOfURL:), (IMP)lc_data_read_url, (IMP *)&lc_orig_data_read_url);
        lc_install_read_method(NSData.class, @selector(dataWithContentsOfFile:options:error:), (IMP)lc_data_read_path_options, (IMP *)&lc_orig_data_read_path_options);
        lc_install_read_method(NSData.class, @selector(dataWithContentsOfURL:options:error:), (IMP)lc_data_read_url_options, (IMP *)&lc_orig_data_read_url_options);
        Class placeholder = object_getClass([NSData alloc]);
        lc_install_data_initializer(placeholder, @selector(initWithContentsOfFile:), @selector(lc_original_initWithContentsOfFile:));
        lc_install_data_initializer(placeholder, @selector(initWithContentsOfURL:), @selector(lc_original_initWithContentsOfURL:));
        lc_install_data_initializer(placeholder, @selector(initWithContentsOfFile:options:error:), @selector(lc_original_initWithContentsOfFile:options:error:));
        lc_install_data_initializer(placeholder, @selector(initWithContentsOfURL:options:error:), @selector(lc_original_initWithContentsOfURL:options:error:));
    });
}

BOOL isolateAppGroup = NO;
void* webKitHeader = 0;
void NSFMGuestHooksInit(void) {
    NSDictionary* infoDict = [NSUserDefaults guestContainerInfo];
    isolateAppGroup = [infoDict[@"isolateAppGroup"] boolValue];
    lc_install_original_file_read_hooks();
    swizzle(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:), @selector(hook_containerURLForSecurityApplicationGroupIdentifier:));
    
    /// To fix https://github.com/LiveContainer/LiveContainer/issues/888 i.e. WebKit being unable to save cookie issue, we have to hook -[NSFileManager createDirectoryAtPath:withIntermediateDirectories:attributes:error:] so that WebKit still creates bookmark for the symlinked lc's cookies folder, which is resolved by the kernel to the app's cookies folder
    /// see https://github.com/apple-oss-distributions/WebKit/blob/0c8cf3581e5c01d970ea411128007c9325ba2d48/Source/WebKit/Shared/Cocoa/SandboxExtensionCocoa.mm#L159 and https://github.com/apple-oss-distributions/WebKit/blob/0c8cf3581e5c01d970ea411128007c9325ba2d48/Source/WebKit/UIProcess/WebsiteData/WebsiteDataStore.cpp#L2225
    /// WebKit::WebsiteDataStore::createHandleFromResolvedPathIfPossible requires WebKit::WebsiteDataStore::resolvedCookieStorageDirectory to return a non-empty path to create a bookmark, which is possible when WebKit::resolveAndCreateReadWriteDirectoryForSandboxExtension is non-empty. However if -[NSFileManager createDirectoryAtPath:withIntermediateDirectories:attributes:error:] returns false for cookies folder since it's a symlink, resolveAndCreateReadWriteDirectoryForSandboxExtension will return empty value. So that com.apple.WebKit.Networking process does not receive the bookmark and is unable to access the cookies folder.
    /// So the hook is simple, we just check if the path is lc's cookies folder and return YES. For performance, we check if caller's address falls in WebKit+0 to WebKit+32M
    /// If you have a better solution, please let us know.
    void* dscPtr = getDSCAddr();
    webKitHeader = getCachedSymbol(@"webKitHeader", dscPtr);
    
    if(!webKitHeader) {
        dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_GLOBAL);
        webKitHeader = LCGetLoadedImageHeader(0, "/System/Library/Frameworks/WebKit.framework/WebKit");
        saveCachedSymbol(@"webKitHeader", dscPtr, webKitHeader-dscPtr);
    }
    
    swizzle(NSFileManager.class, @selector(createDirectoryAtPath:withIntermediateDirectories:attributes:error:), @selector(hook_createDirectoryAtPath:withIntermediateDirectories:attributes:error:));
    
}

// NSFileManager simulate app group
@implementation NSFileManager(LiveContainerHooks)

- (nullable NSURL *)hook_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    if([groupIdentifier isEqualToString:[NSClassFromString(@"LCSharedUtils") appGroupID]]) {
        // The host can have no usable app group. Preserve the API's nil result.
        NSString *appGroupPath = NSUserDefaults.lcAppGroupPath;
        return appGroupPath.length > 0 ? [NSURL fileURLWithPath:appGroupPath] : nil;
    }
    NSURL *result;
    if(isolateAppGroup) {
        result = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%s/LCAppGroup/%@", getenv("HOME"), groupIdentifier]];
    } else if (NSUserDefaults.lcAppGroupPath){
        result = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/LiveContainer/Data/AppGroup/%@", NSUserDefaults.lcAppGroupPath, groupIdentifier]];
    } else {
        result = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%s/Documents/Data/AppGroup/%@", getenv("LC_HOME_PATH"), groupIdentifier]];
    }
    [NSFileManager.defaultManager createDirectoryAtURL:[result URLByAppendingPathComponent:@"Library/Caches"] withIntermediateDirectories:YES attributes:nil error:nil];
    return result;
}

- (bool)hook_createDirectoryAtPath:(NSString *)path withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary<NSFileAttributeKey,id> *)attributes error:(NSError *__autoreleasing  _Nullable *)error {
    bool ans = [self hook_createDirectoryAtPath:path withIntermediateDirectories:createIntermediates attributes:attributes error:error];
    void* callerAddr = __builtin_return_address(0);
    if(callerAddr > webKitHeader && callerAddr < (webKitHeader + (32 << 20) )) {
        if([path hasSuffix:@"Library/Cookies"]) {
            // symlink Cookies folder
            // https://github.com/apple-oss-distributions/WebKit/blob/0c8cf3581e5c01d970ea411128007c9325ba2d48/Source/WebKit/Shared/Cocoa/SandboxUtilities.mm#L56
            // unfortunately we cannot hook sandbox_container_path_for_pid, so we symlink Cookies folder in normal mode
            // see NSFileManager+GuestHooks.m for more info
            NSFileManager *fm = NSFileManager.defaultManager;
            const char *lcHomePath = getenv(NSUserDefaults.isLiveProcess ? "LP_HOME_PATH" : "LC_HOME_PATH");
            NSString *libraryPath = [@(lcHomePath) stringByAppendingPathComponent:@"Library"];
            NSString *cookies2Path = [libraryPath stringByAppendingPathComponent:@"Cookies2"];
            NSString *cookiesPath = [libraryPath stringByAppendingPathComponent:@"Cookies"];
            NSString* appCookiesPath = [@(getenv("HOME")) stringByAppendingPathComponent:@"Library/Cookies"];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:cookies2Path isDirectory:&isDir]) {
                if([fm fileExistsAtPath:cookiesPath isDirectory:&isDir]) {
                    [fm moveItemAtPath:cookiesPath toPath:cookies2Path error:nil];
                } else {
                    [fm createDirectoryAtPath:cookies2Path withIntermediateDirectories:YES attributes:nil error:nil];
                }
            }
            remove(cookiesPath.UTF8String);
            symlink(appCookiesPath.UTF8String, cookiesPath.UTF8String);
            return YES;
        }
    }
    return ans;
}

@end
