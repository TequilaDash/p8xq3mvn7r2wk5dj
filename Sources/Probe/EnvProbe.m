// EnvProbe.m — 环境泄漏检测探针 (宿主沙盒容器访客侧自检工具)
//
// 目的: 在沙盒容器里跑一个"访客视角"的全通道自检, 输出与 Reveil 同口径的
// 检测面结果, 用于验收 shim 隐藏层是否真的盖住. 单文件 ObjC, 无宿主依赖,
// 兼容 dlopen 注入模式 (LiveProcess 链路) 与独立执行.
//
// 检测通道 (每项: 无泄漏=OK / 发现泄漏=LEAK + 详情):
//  P01 getenv          — TD_*/LC_*/LP_* 门控键清洗
//  P02 sysctlbyname    — kern.bootargs 非空 / hw.machine 伪值一致性
//  P03 csops           — CS_GET_TASK_ALLOW / CS_DEBUGGED 位
//  P04 SecTask         — 宿主私有 entitlement 可读性
//  P05 dyld 镜像枚举   — LC/ZSign/TweakLoader/宿主路径可见性
//  P06 dladdr 反查     — 镜像路径含宿主容器前缀
//  P07 proc_pidpath    — 自身路径是否暴露宿主容器
//  P08 proc_listallpids— 宿主进程可见性
//  P09 文件系统        — Documents/Tweaks 可见性 (访客 caller)
//  P10 NSUserDefaults  — org.tequila.*/LC 域泄漏
//  P11 NSBundle.main   — bundlePath 指向访客还是宿主
//  P12 HOME/CFFIXED    — 家目录环境
//  P13 getuid 族       — full 模式应伪 0
//  P14 getmntinfo      — vroot 挂载项泄露宿主路径
//  P15 task_info       — mach 端口级镜像表 (interpose 拦不住的通道, 报告实况)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/dyld_images.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <sys/proc.h>
#import <sys/mount.h>
#import <libproc.h>
#import <spawn.h>
#import <dlfcn.h>

// csops 无公开头
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
// SecTask 无公开头
typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef ent, CFErrorRef *error);

#define CS_OPS_STATUS 0
#define CS_GET_TASK_ALLOW 0x00002000
#define CS_DEBUGGED 0x10000000

static NSMutableString *gReport;
static int gLeakCount = 0;

static void line(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void line(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    [gReport appendFormat:@"%@\n", [[NSString alloc] initWithFormat:fmt arguments:ap]];
    va_end(ap);
}
static void leak(NSString *probe, NSString *detail) {
    gLeakCount++;
    line(@"🔴 LEAK  [%@] %@", probe, detail);
}
static void ok(NSString *probe, NSString *detail) {
    line(@"✅ OK    [%@] %@", probe, detail);
}
static void info(NSString *probe, NSString *detail) {
    line(@"ℹ️  INFO  [%@] %@", probe, detail);
}

// ---------- P01 getenv ----------
static void probe_getenv(void) {
    static NSString * const keys[] = {
        @"TD_NET_BLOCK", @"TD_VROOT", @"TD_VROOT_MODE", @"TD_DYLD_TRIM",
        @"TD_SYSCTL_SPOOF", @"TD_SECTASK_SPOOF", @"TD_CSOPS_SPOOF",
        @"TD_CSOPS_KEEP_DEBUGGED", @"LC_HOME_PATH", @"LP_HOME_PATH",
        @"LC_GLOBAL_TWEAKS_FOLDER", @"LC_JITLESS_TEST_LOADED",
    };
    NSMutableArray *found = [NSMutableArray array];
    for (NSString *k in keys) {
        if (getenv(k.UTF8String)) [found addObject:k];
    }
    if (found.count) leak(@"P01 getenv", [NSString stringWithFormat:@"访客 env 可见宿主门控键: %@", [found componentsJoinedByString:@", "]]);
    else ok(@"P01 getenv", @"TD_*/LC_*/LP_* 全部清洗");
}

// ---------- P02 sysctlbyname ----------
static void probe_sysctl(void) {
    char buf[256]; size_t len = sizeof(buf);
    if (sysctlbyname("kern.bootargs", buf, &len, NULL, 0) == 0 && len > 1 && buf[0] != '\0') {
        leak(@"P02 sysctl bootargs", [NSString stringWithFormat:@"kern.bootargs 非空: %s (非空 = 越狱/USB 引导实锤)", buf]);
    } else {
        ok(@"P02 sysctl bootargs", @"空或查询失败 (=真机形态)");
    }
    len = sizeof(buf);
    if (sysctlbyname("hw.machine", buf, &len, NULL, 0) == 0) {
        info(@"P02 hw.machine", [NSString stringWithFormat:@"%s (若与宿主机型不符 = 伪值穿帮)", buf]);
    }
}

// ---------- P03 csops ----------
static void probe_csops(void) {
    unsigned int flags = 0; size_t sz = sizeof(flags);
    if (csops(getpid(), CS_OPS_STATUS, &flags, sz) == 0) {
        if (flags & CS_GET_TASK_ALLOW) {
            leak(@"P03 csops", @"CS_GET_TASK_ALLOW=1 (可被调试, 侧载宿主必露, 需 TD_CSOPS_SPOOF)");
        } else ok(@"P03 csops", @"CS_GET_TASK_ALLOW 已清");
        if (flags & CS_DEBUGGED) {
            info(@"P03 csops", @"CS_DEBUGGED=1 (调试器位; 若非本探针预期 = 泄漏)");
        }
    } else {
        info(@"P03 csops", @"csops 查询失败");
    }
}

// ---------- P04 SecTask ----------
static void probe_sectask(void) {
    SecTaskRef task = SecTaskCreateFromSelf(NULL);
    if (!task) { info(@"P04 SecTask", @"CreateFromSelf 失败"); return; }
    static NSString * const probes[] = {
        @"get-task-allow",
        @"com.apple.private.security.no-sandbox",
        @"com.apple.private.xpc.launchd.userspace-reboot",
        @"org.tequila.test",
    };
    NSMutableArray *leaks = [NSMutableArray array];
    for (NSString *k in probes) {
        CFTypeRef v = SecTaskCopyValueForEntitlement(task, (__bridge CFStringRef)k, NULL);
        if (v) {
            [leaks addObject:[NSString stringWithFormat:@"%@=%@", k, v]];
            CFRelease(v);
        }
    }
    CFRelease(task);
    if (leaks.count) leak(@"P04 SecTask", [NSString stringWithFormat:@"私有 entitlement 可读: %@", [leaks componentsJoinedByString:@"; "]]);
    else ok(@"P04 SecTask", @"私有键全部 NULL (=键不存在同形)");
}

// ---------- P05 dyld 镜像枚举 ----------
static void probe_dyld_images(void) {
    uint32_t n = _dyld_image_count();
    NSMutableArray *bad = [NSMutableArray array];
    for (uint32_t i = 0; i < n; i++) {
        const char *p = _dyld_get_image_name(i);
        if (!p) continue;
        NSString *s = [NSString stringWithUTF8String:p];
        if ([s containsString:@"LiveContainer"] || [s containsString:@"ZSign"] ||
            [s containsString:@"TweakLoader"] || [s containsString:@"CydiaSubstrate"] ||
            [s containsString:@"Documents/Tweaks"]) {
            [bad addObject:s.lastPathComponent];
        }
    }
    if (bad.count) leak(@"P05 dyld images", [NSString stringWithFormat:@"%u 张镜像中含注入层: %@", n, [bad componentsJoinedByString:@", "]]);
    else ok(@"P05 dyld images", [NSString stringWithFormat:@"%u 张镜像全部干净", n]);
}

// ---------- P06 dladdr 反查 ----------
static void probe_dladdr_self(void) {
    Dl_info info;
    if (dladdr((void *)&probe_dladdr_self, &info) && info.dli_fname) {
        NSString *p = [NSString stringWithUTF8String:info.dli_fname];
        if ([p containsString:@"Containers/Bundle/Application"]) {
            leak(@"P06 dladdr", [NSString stringWithFormat:@"本镜像路径在宿主 Bundle 容器: %@", p]);
        } else ok(@"P06 dladdr", p);
    }
}

// ---------- P07 proc_pidpath ----------
static void probe_pidpath(void) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(getpid(), path, sizeof(path)) > 0) {
        NSString *p = [NSString stringWithUTF8String:path];
        if ([p containsString:@".app/"]) {
            // 正常形态: 访客 app 自己的路径
            ok(@"P07 pidpath", p);
        } else {
            leak(@"P07 pidpath", [NSString stringWithFormat:@"自身路径异常: %@", p]);
        }
    }
}

// ---------- P08 proc_listallpids ----------
static void probe_proclist(void) {
    pid_t pids[2048];
    int n = proc_listallpids(pids, sizeof(pids));
    if (n > 0) {
        info(@"P08 proclist", [NSString stringWithFormat:@"可见 %d 个进程 (Nyxian ksurface 方案可全隐藏, interpose 方案仅文件面; 数值对照 zContainer 同环境基线)", n]);
    }
}

// ---------- P09 Tweaks 目录 (caller=guest) ----------
static void probe_tweaks_dir(void) {
    NSString *home = NSHomeDirectory();
    NSString *tweaks = [home stringByAppendingPathComponent:@"Documents/Tweaks"];
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:tweaks];
    if (exists) {
        info(@"P09 Tweaks", @"Documents/Tweaks 存在且对访客可见 (M37b 仅拦访客镜像 caller; 本探针本身是访客=应被拦. 若本条为可见且 shim 在, 判定 fail-open)");
    } else ok(@"P09 Tweaks", @"ENOENT (隐藏生效)");
}

// ---------- P10 NSUserDefaults 域 ----------
static void probe_defaults(void) {
    static NSString * const domains[] = {
        @"org.tequila.dash", @"com.tequila", @"group.com.tequila.dash",
        @"org.emexlabs.nyxian",
    };
    NSMutableArray *leaks = [NSMutableArray array];
    for (NSString *d in domains) {
        NSDictionary *dict = [NSUserDefaults.standardUserDefaults persistentDomainForName:d];
        if (dict.count > 0) [leaks addObject:[NSString stringWithFormat:@"%@ (%lu 键)", d, (unsigned long)dict.count]];
    }
    if (leaks.count) leak(@"P10 defaults", [NSString stringWithFormat:@"宿主 prefs 域可见: %@", [leaks componentsJoinedByString:@"; "]]);
    else ok(@"P10 defaults", @"宿主域不可见");
}

// ---------- P11 NSBundle.main ----------
static void probe_bundle(void) {
    NSString *bp = NSBundle.mainBundle.bundlePath;
    info(@"P11 bundle", [NSString stringWithFormat:@"%@", bp]);
}

// ---------- P12 HOME ----------
static void probe_home(void) {
    const char *h = getenv("HOME");
    const char *cf = getenv("CFFIXED_USER_HOME");
    info(@"P12 HOME", [NSString stringWithFormat:@"HOME=%s CFFIXED_USER_HOME=%s", h ?: "-", cf ?: "-"]);
}

// ---------- P13 getuid 族 ----------
static void probe_uid(void) {
    uid_t u = getuid(), e = geteuid();
    if (u == 0 || e == 0) info(@"P13 uid", @"uid=0 (vroot full 模式伪值)");
    else info(@"P13 uid", [NSString stringWithFormat:@"uid=%d euid=%d (mobile=501)", u, e]);
}

// ---------- P14 getmntinfo ----------
static void probe_mnt(void) {
    struct statfs *mnt;
    int n = getmntinfo(&mnt, MNT_WAIT);
    NSMutableArray *bad = [NSMutableArray array];
    for (int i = 0; i < n; i++) {
        NSString *dir = [NSString stringWithUTF8String:mnt[i].f_mntonname];
        if ([dir containsString:@".jbroot"] || [dir containsString:@"rootfs"]) {
            [bad addObject:dir];
        }
    }
    if (bad.count) leak(@"P14 mntinfo", [NSString stringWithFormat:@"挂载表暴露 vroot 项: %@", [bad componentsJoinedByString:@", "]]);
    else ok(@"P14 mntinfo", @"无 vroot 泄漏项");
}

// ---------- P15 task_info (mach 端口级, interpose 拦不住) ----------
static void probe_taskinfo(void) {
    task_dyld_info_data_t tinfo;
    mach_msg_type_number_t cnt = TASK_DYLD_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_DYLD_INFO, (task_info_t)&tinfo, &cnt) == KERN_SUCCESS) {
        // all_image_info_addr 指向 dyld_all_image_infos; 直接遍历可得完整镜像表.
        struct dyld_all_image_infos *aii = (struct dyld_all_image_infos *)tinfo.all_image_info_addr;
        if (aii && aii->infoArrayCount > 0) {
            uint32_t n = aii->infoArrayCount;
            NSMutableArray *bad = [NSMutableArray array];
            for (uint32_t i = 0; i < n && i < 512; i++) {
                const char *p = aii->infoArray[i].imageFilePath;
                if (!p) continue;
                NSString *s = [NSString stringWithUTF8String:p];
                if ([s containsString:@"LiveContainer"] || [s containsString:@"TweakLoader"] || [s containsString:@"ZSign"]) {
                    [bad addObject:s.lastPathComponent];
                }
            }
            if (bad.count) leak(@"P15 task_info", [NSString stringWithFormat:@"mach 端口级镜像表 %u 项, 注入层可见: %@ (interpose 拦不住 — 需 fishhook task_info 或改写 dyld 结构, 第三批)", n, [bad componentsJoinedByString:@", "]]);
            else ok(@"P15 task_info", [NSString stringWithFormat:@"%u 项, mach 级干净", n]);
        }
    } else info(@"P15 task_info", @"task_info 查询失败");
}

// ---------- 入口 ----------
__attribute__((constructor)) static void envprobe_entry(void) {
    // 延迟到 RunLoop 起来后再跑 (保证 UIKit/Foundation 就绪); 由 NSTimer 触发.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gReport = [NSMutableString string];
        [gReport appendFormat:@"EnvProbe 自检报告 — %@\n", [NSDate date]];
        [gReport appendFormat:@"pid=%d bundle=%@\n\n", getpid(), NSBundle.mainBundle.bundleIdentifier];

        probe_getenv();
        probe_sysctl();
        probe_csops();
        probe_sectask();
        probe_dyld_images();
        probe_dladdr_self();
        probe_pidpath();
        probe_proclist();
        probe_tweaks_dir();
        probe_defaults();
        probe_bundle();
        probe_home();
        probe_uid();
        probe_mnt();
        probe_taskinfo();

        [gReport appendFormat:@"\n====== 汇总: %d 项泄漏 ======\n", gLeakCount];
        [gReport appendString:@"判定基线: 与 zContainer 同环境跑本探针, 数值对齐后逐项消红.\n"];

        // 展示 + 落盘
        NSString *report = gReport.copy;
        NSLog(@"[EnvProbe]\n%@", report);
        NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        [report writeToFile:[doc stringByAppendingPathComponent:@"EnvProbe-report.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:NULL];

        // 弹窗 (若 UIKit 可用)
        if (NSClassFromString(@"UIAlertController")) {
            UIWindowScene *scene = UIApplication.sharedApplication.connectedScenes.allObjects.firstObject;
            UIWindow *w = scene.keyWindow ?: scene.windows.firstObject;
            UIViewController *vc = w.rootViewController;
            while (vc.presentedViewController) vc = vc.presentedViewController;
            if (vc) {
                UIAlertController *a = [UIAlertController alertControllerWithTitle:
                    [NSString stringWithFormat:@"EnvProbe: %d 项泄漏", gLeakCount]
                    message:report preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [vc presentViewController:a animated:YES completion:nil];
            }
        }
    });
}
