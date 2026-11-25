#import <Foundation/Foundation.h>
#include <libproc.h>
#include <sys/resource.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#import "../LiveContainer/utils.h"

/// 访客自报内存的定时器；block 内不能声明 static，只能放文件作用域。
static dispatch_source_t gIManagerMemoryTimer = NULL;

static NSString *loadTweakAtURL(NSURL *url) {
    NSString *tweakPath = url.path;
    NSString *tweak = tweakPath.lastPathComponent;
    if (![tweakPath hasSuffix:@".dylib"] && ![tweakPath hasSuffix:@".framework"]) {
        return nil;
    }
    if ([tweakPath hasSuffix:@".framework"]) {
        NSURL* infoPlistURL = [url URLByAppendingPathComponent:@"Info.plist"];
        NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfURL:infoPlistURL];
        NSString* binary = infoDict[@"CFBundleExecutable"];
        if(!binary || ![binary isKindOfClass:NSString.class]) {
            return [NSString stringWithFormat:@"Unable to load %@: Unable to read Info.Plist", tweak];
        }
        tweakPath = [[url URLByAppendingPathComponent:binary] path];
    }
    
    void *handle = dlopen(tweakPath.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
    const char *error = dlerror();
    if (handle) {
        NSLog(@"Loaded tweak %@", tweak);
        return nil;
    } else if (error) {
        NSLog(@"Error: %s", error);
        return @(error);
    } else {
        NSLog(@"Error: dlopen(%@): Unknown error because dlerror() returns NULL", tweak);
        return [NSString stringWithFormat:@"dlopen(%@): unknown error, handle is NULL", tweakPath];
    }
}

static void loadTweaksRecursively(NSURL *folderURL, NSMutableArray *errors) {
    NSArray<NSURL *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtURL:folderURL includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:nil];
    for (NSURL *fileURL in items) {
        NSString *name = fileURL.lastPathComponent;
        if ([name hasSuffix:@".disabled"]) {
            NSLog(@"Skipping disabled tweak %@", name);
            continue;
        }
        NSNumber *isDirectory = nil;
        [fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        // a .framework is a directory but loads as a single tweak
        if (isDirectory.boolValue && ![name hasSuffix:@".framework"]) {
            loadTweaksRecursively(fileURL, errors);
        } else {
            NSString *error = loadTweakAtURL(fileURL);
            if (error) {
                [errors addObject:error];
            }
        }
    }
}

static void showDlerrAlert(NSString *error) {
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Failed to load tweaks" message:error preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        UIPasteboard.generalPasteboard.string = error;
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = 1000;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

 __attribute__((constructor))
static void TweakLoaderConstructor() {
    // iManager(内存管理): 把本访客进程登记进 app group，供宿主内存页与
    // 堆叠后台内存胶囊定位 PID；宿主也会直接收集活跃 controller。
    // 每个 PID 独立偏好键，避免多个进程 read-modify-write 同一字典丢项。
    // 整块 @try 保护：登记失败绝不能让访客崩（108~111 四版就是栽在这里）。
    @try {
        NSUserDefaults *iManagerShared = NSUserDefaults.lcSharedDefaults;
        NSString *iManagerKey = [NSString stringWithFormat:@"TDLiveGuestPid.%d", getpid()];
        [iManagerShared setObject:@{
            @"bundleId": NSUserDefaults.lcGuestAppId ?: @"",
            @"ts": @([[NSDate date] timeIntervalSince1970]),
        } forKey:iManagerKey];
        [iManagerShared synchronize];
    } @catch (NSException *iManagerExc) {
        NSLog(@"[iManager] guest pid registration failed: %@ - %@", iManagerExc.name, iManagerExc.reason);
    }
    // iManager(内存管理): 宿主读别的进程 footprint 会被内核拒绝（实测全部
    // "不可读取"）。访客有权限读自己，所以由访客定期把自己的 footprint
    // 写进 app group，宿主直接读这个值。放在早退之前，没装 tweak 也要上报。
    @try {
        int iManagerPID = getpid();
        NSString *iManagerMemKey = [NSString stringWithFormat:@"TDLiveGuestMem.%d", iManagerPID];
        void (^iManagerReport)(void) = ^{
            struct rusage_info_v2 iManagerInfo;
            memset(&iManagerInfo, 0, sizeof(iManagerInfo));
            if (proc_pid_rusage(iManagerPID, RUSAGE_INFO_V2, (rusage_info_t *)&iManagerInfo) == 0) {
                [NSUserDefaults.lcSharedDefaults setObject:@(iManagerInfo.ri_phys_footprint)
                                                   forKey:iManagerMemKey];
            }
        };
        iManagerReport();
        dispatch_source_t iManagerTimer =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        if (iManagerTimer) {
            dispatch_source_set_timer(iManagerTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                      2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
            dispatch_source_set_event_handler(iManagerTimer, iManagerReport);
            dispatch_resume(iManagerTimer);
            gIManagerMemoryTimer = iManagerTimer; // 必须持有，否则立刻释放
        }
    } @catch (NSException *iManagerMemExc) {
        NSLog(@"[iManager] guest memory reporting failed: %@", iManagerMemExc.reason);
    }
    const char *tweakFolderC = getenv("LC_GLOBAL_TWEAKS_FOLDER");
    NSString *globalTweakFolder = tweakFolderC ? @(tweakFolderC) : nil;
    unsetenv("LC_GLOBAL_TWEAKS_FOLDER");
    if([NSUserDefaults.guestAppInfo[@"dontInjectTweakLoader"] boolValue]) {
        NSLog(@"Skip loading tweaks");
        return;
    }
    NSMutableArray *errors = [NSMutableArray new];
    
    // 全局目录为空时不要直接 return：App 自带的 Tweak 目录（LCTweakFolder）还要加载。
    NSArray<NSURL *> *globalTweaks = globalTweakFolder.length
        ? [NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:globalTweakFolder]
                                      includingPropertiesForKeys:@[] options:0 error:nil]
        : @[];
    NSString *tweakFolderName = NSUserDefaults.guestAppInfo[@"LCTweakFolder"];
    
    if([globalTweaks count] <= 1 && tweakFolderName.length == 0) {
        // nothing to load
        return;
    }

    // Load CydiaSubstrate
    const char *lcMainBundlePath;
    if(NSUserDefaults.isLiveProcess) {
        lcMainBundlePath = NSUserDefaults.lcMainBundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.fileSystemRepresentation;
    } else {
        lcMainBundlePath = NSUserDefaults.lcMainBundle.bundlePath.fileSystemRepresentation;
    }
    char substratePath[PATH_MAX];
    snprintf(substratePath, sizeof(substratePath), "%s/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", lcMainBundlePath);
    dlopen(substratePath, RTLD_LAZY | RTLD_GLOBAL);
    const char *substrateError = dlerror();
    if (substrateError) {
        [errors addObject:@(substrateError)];
    }

    // Load global tweaks
    NSLog(@"Loading tweaks from the global folder");

    for (NSURL *fileURL in globalTweaks) {
        NSString *name = fileURL.lastPathComponent;
        if ([name isEqualToString:@"TweakLoader.dylib"]) {
            // skip loading myself
            continue;
        }
        if ([name hasSuffix:@".disabled"]) {
            NSLog(@"Skipping disabled global tweak %@", name);
            continue;
        }
        NSString *error = loadTweakAtURL(fileURL);
        if (error) {
            [errors addObject:error];
        }
    }

    // Load selected tweak folder, recursively
    if (tweakFolderName.length > 0) {
        NSLog(@"Loading tweaks from the selected folder");
        NSString *tweakFolder = [globalTweakFolder stringByAppendingPathComponent:tweakFolderName];
        loadTweaksRecursively([NSURL fileURLWithPath:tweakFolder], errors);
    }

    if (errors.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *error = [errors componentsJoinedByString:@"\n"];
            showDlerrAlert(error);
        });
    }
}
