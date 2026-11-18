@import Foundation;
#import "utils.h"
#import "LCSharedUtils.h"
#import "Tweaks.h"
#include "../../litehook/src/litehook.h"
#include "../LCMachOUtils.h"
#include <dlfcn.h>
#include <CommonCrypto/CommonDigest.h>

BOOL isolateAppGroup = NO;
void* webKitHeader = 0;
void NSFMGuestHooksInit(void) {
    NSDictionary* infoDict = [NSUserDefaults guestContainerInfo];
    isolateAppGroup = [infoDict[@"isolateAppGroup"] boolValue];
    swizzle(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:), @selector(hook_containerURLForSecurityApplicationGroupIdentifier:));
    swizzle(NSFileManager.class, @selector(contentsAtPath:), @selector(hook_contentsAtPath:));
    swizzleClassMethod(NSDictionary.class, @selector(dictionaryWithContentsOfFile:), @selector(hook_dictionaryWithContentsOfFile:));
    
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

static NSString *LCFileSHA256Hex(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

static NSDictionary *LCSanitizeSecurityPresets(NSDictionary *dict, NSString *path) {
    if (!dict || ![path.lastPathComponent isEqualToString:@"SecurityPresets.plist"]) return dict;
    NSMutableDictionary *result = [dict mutableCopy];
    NSString *dir = path.stringByDeletingLastPathComponent;
    NSFileManager *fm = NSFileManager.defaultManager;

    NSArray *profileHashes = result[@"secureMobileProvisioningProfileHashes"];
    if ([profileHashes isKindOfClass:NSArray.class] && profileHashes.count == 1 &&
        [[profileHashes.firstObject description] length] == 0) {
        NSString *original = [dir stringByAppendingPathComponent:@".td-original.mobileprovision"];
        NSString *current = [dir stringByAppendingPathComponent:@"embedded.mobileprovision"];
        NSString *source = [fm fileExistsAtPath:original] ? original : current;
        NSString *hash = LCFileSHA256Hex(source);
        if (hash) result[@"secureMobileProvisioningProfileHashes"] = @[hash];
    }

    NSString *guestID = NSUserDefaults.lcGuestAppId;
    if (guestID.length > 0 && [result[@"secureMainBundleIdentifiers"] isKindOfClass:NSArray.class]) {
        result[@"secureMainBundleIdentifiers"] = @[guestID];
    }
    return result;
}

@implementation NSDictionary (LiveContainerHooks)

+ (NSDictionary *)hook_dictionaryWithContentsOfFile:(NSString *)path {
    NSDictionary *dict = [self hook_dictionaryWithContentsOfFile:path];
    return LCSanitizeSecurityPresets(dict, path);
}

@end

// NSFileManager simulate app group
@implementation NSFileManager(LiveContainerHooks)

- (nullable NSURL *)hook_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    if([groupIdentifier isEqualToString:[NSClassFromString(@"LCSharedUtils") appGroupID]]) {
        return [NSURL fileURLWithPath: NSUserDefaults.lcAppGroupPath];
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

- (nullable NSData *)hook_contentsAtPath:(NSString *)path {
    if ([path.lastPathComponent isEqualToString:@"embedded.mobileprovision"]) {
        NSString *original = [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:@".td-original.mobileprovision"];
        if ([NSFileManager.defaultManager fileExistsAtPath:original]) {
            return [NSData dataWithContentsOfFile:original];
        }
    }
    return [self hook_contentsAtPath:path];
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
