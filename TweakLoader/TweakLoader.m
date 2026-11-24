#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <limits.h>
#include <stdlib.h>
#include <objc/runtime.h>
#include <fcntl.h>
#include <unistd.h>
#import "../LiveContainer/utils.h"
typedef void (*TDLConsoleLogFn)(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// 1.1.111 取证：访客主程序 initializer 抛未捕获 NSException 时，abort_report_np 之前
// 没有我们的栈帧可看。这里装全局异常 handler，把 name + reason + callStackSymbols
// 落到 NSLog、TDConsoleLog（dlsym，TweakLoader 不链接 Shared）和磁盘文件，
// 下一次崩溃日志里直接出现异常原文，不再需要二分发版猜根因。
static void LCGuestUncaughtExceptionHandler(NSException *exception) {
    NSString *name = exception.name ?: @"(nil)";
    NSString *reason = exception.reason ?: @"(nil)";
    NSArray *symbols = exception.callStackSymbols ?: @[];
    NSString *stack = [symbols componentsJoinedByString:@" | "];
    NSString *text = [NSString stringWithFormat:@"[LC-EXCEPTION] name=%@ reason=%@ stack=%@", name, reason, stack];
    NSLog(@"%@", text);
    TDLConsoleLogFn logFn = (TDLConsoleLogFn)dlsym(RTLD_DEFAULT, "TDConsoleLog");
    if (logFn) logFn(@"%@", text);
    const char *dir = getenv("TD_CONSOLE_LOG_DIR");
    NSString *directory = (dir && dir[0] == '/') ? [NSString stringWithUTF8String:dir] : nil;
    if (!directory) {
        const char *home = getenv("LC_HOME_PATH");
        if (home && home[0] == '/') {
            directory = [NSString stringWithFormat:@"%s/Documents/ConsoleLog", home];
        }
    }
    if (directory) {
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"exception-%d.log", getpid()]];
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
        if (fd >= 0) { write(fd, data.bytes, data.length); close(fd); }
    }
}

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
    const char *tweakFolderC = getenv("LC_GLOBAL_TWEAKS_FOLDER");
    NSString *globalTweakFolder = @(tweakFolderC);
    unsetenv("LC_GLOBAL_TWEAKS_FOLDER");

    // 1.1.111 取证：尽早注册全局异常 handler。访客主程序 initializer 抛的
    // NSException 走 uncaught-exception 路径到 abort_report_np，栈里没有我方
    // 帧，装在这里才能在崩溃前拿到 name + reason + 调用栈。
    NSSetUncaughtExceptionHandler(LCGuestUncaughtExceptionHandler);

    // 会话登记: 访客进程把 pid/bundleId/时间戳写进 app group, 供宿主内存管理页
    // 与堆叠后台内存胶囊定位进程 (jailed 下 sysctl KERN_PROC_ALL 不可枚举,
    // 但同 uid 进程 proc_pid_rusage/kill(pid,0) 可用; 宿主用 kill 探活过滤死项).
    // 1.1.111: 整块 @try/@catch——登记本身绝不能成为崩源，任何异常落日志后继续。
    @try {
        NSUserDefaults *shared = NSUserDefaults.lcSharedDefaults;
        NSMutableDictionary *reg = [[shared dictionaryForKey:@"TDLiveGuestPids"] mutableCopy] ?: [NSMutableDictionary new];
        reg[@(getpid())] = @{
            @"bundleId": NSUserDefaults.lcGuestAppId ?: @"",
            @"ts": @([[NSDate date] timeIntervalSince1970]),
        };
        [shared setObject:reg forKey:@"TDLiveGuestPids"];
        [shared synchronize];
    } @catch (NSException *exc) {
        NSLog(@"[LC] TDLiveGuestPids registration failed: %@ - %@", exc.name, exc.reason);
    }

    if([NSUserDefaults.guestAppInfo[@"dontInjectTweakLoader"] boolValue]) {
        // don't load any tweak since tweakloader is loaded after all initializers
        NSLog(@"Skip loading tweaks");
        return;
    }
    
    NSMutableArray *errors = [NSMutableArray new];
    
    NSArray<NSURL *> *globalTweaks = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:globalTweakFolder]
    includingPropertiesForKeys:@[] options:0 error:nil];
    NSString *tweakFolderName = NSUserDefaults.guestAppInfo[@"LCTweakFolder"];
    
    if([globalTweaks count] <= 1 && tweakFolderName.length == 0) {
        // nothing to load
        return;
    }

    // Load CydiaSubstrate
    // NSUserDefaults.lcMainBundle 在访客启动后可能已被改写成访客 bundle
    // (真机表现为去找 <guest>/Documents/Frameworks/CydiaSubstrate.framework).
    // 从 TweakLoader 自身镜像路径反推 LC app, 与 bundle 覆盖无关.
    char substratePath[PATH_MAX];
    substratePath[0] = '\0';
    char selfPath[PATH_MAX];
    Dl_info selfInfo;
    if (dladdr((void *)&TweakLoaderConstructor, &selfInfo) && selfInfo.dli_fname &&
        realpath(selfInfo.dli_fname, selfPath)) {
        char *frameworks = strstr(selfPath, "/Frameworks/");
        if (frameworks) {
            *frameworks = '\0';
            snprintf(substratePath, sizeof(substratePath),
                     "%s/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", selfPath);
        }
    }
    if (substratePath[0] == '\0') {
        // 回退: 旧路径推导 (仅当自定位失败)
        const char *lcMainBundlePath;
        if(NSUserDefaults.isLiveProcess) {
            lcMainBundlePath = NSUserDefaults.lcMainBundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.fileSystemRepresentation;
        } else {
            lcMainBundlePath = NSUserDefaults.lcMainBundle.bundlePath.fileSystemRepresentation;
        }
        snprintf(substratePath, sizeof(substratePath),
                 "%s/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", lcMainBundlePath);
    }
    dlopen(substratePath, RTLD_LAZY | RTLD_GLOBAL);
    const char *substrateError = dlerror();
    if (substrateError) {
        NSLog(@"[TweakLoader] substrate load failed: %s (%s)", substratePath, substrateError);
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
