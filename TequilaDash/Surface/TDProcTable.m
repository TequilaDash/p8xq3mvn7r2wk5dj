//
//  TDProcTable.m
//  TequilaDash (Surface/Tier B-1: Surface-lite 虚拟进程面)
//
//  设计与 parity 依据见 TDProcTable.h 头注 (对照 decomp_superslot.c
//  _proc_kill__impl @0x42d20 / _proc_reap @0x42e38, clean-room 重写).
//
//  并发模型:
//    · 进程内: NSRecursiveLock 串行 (kill 的轮询收口会再调 markExited, 需可重入).
//    · 跨进程: 对 <Documents/TDSurface>/proc_table.lock flock(LOCK_EX) 包住
//      读-改-写, 写侧写临时文件后 rename(2) 原子替换. 宿主与扩展进程共用该文件.
//    · 文件损坏/缺失按空表重建 (崩溃后可重建状态的兜底之一).
//

#import "Surface/TDProcTable.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

NSString * const TDProcTableErrorDomain = @"TDProcTableErrorDomain";

// JSON 根键
static NSString * const kRootVersion   = @"version";
static NSString * const kRootBootTime  = @"bootTime";
static NSString * const kRootEntries   = @"entries";
// 条目键
static NSString * const kPid           = @"pid";
static NSString * const kKind          = @"kind";
static NSString * const kName          = @"name";
static NSString * const kBundleId      = @"bundleId";
static NSString * const kContainerUUID = @"containerUUID";
static NSString * const kState         = @"state";
static NSString * const kRegisteredAt  = @"registeredAt";
static NSString * const kExitedAt      = @"exitedAt";
static NSString * const kExitNote      = @"exitNote";
static NSString * const kPidStartTime  = @"pidStartTime";

static const NSInteger kSchemaVersion = 1;
static const NSTimeInterval kPruneExitedAfterSeconds = 7 * 24 * 3600;  // 7 天
static const NSTimeInterval kKillPollBudgetSeconds   = 2.0;
static const useconds_t kKillPollStepUs   = 50 * 1000;
static const useconds_t kWaitPollStepUs   = 100 * 1000;

#pragma mark - 系统/时间辅助

static double TDNowSeconds(void) {
    return [[NSDate date] timeIntervalSince1970];
}

// kern.boottime: 表内条目跨重启一律作废的依据 (pid 在两次 boot 间必然重用).
static double TDBootTimeSeconds(void) {
    struct timeval tv;
    memset(&tv, 0, sizeof(tv));
    size_t len = sizeof(tv);
    int mib[2] = { CTL_KERN, KERN_BOOTTIME };
    if (sysctl(mib, 2, &tv, &len, NULL, 0) != 0) {
        return 0;
    }
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

// 目标 pid 的进程起始时间 (pid 重用检测): sysctl(KERN_PROC_PID) 拿 kinfo_proc.
// 沙盒若拒绝 (返回 0) 则跳过重用检测 —— Inferred, 真机复核.
static double TDProcStartTime(pid_t pid) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    struct kinfo_proc kp;
    memset(&kp, 0, sizeof(kp));
    size_t len = sizeof(kp);
    if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len < sizeof(kp)) {
        return 0;
    }
    struct timeval tv = kp.kp_proc.p_starttime;
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

// 该 pid 当前是否存在: kill(pid, 0) 的三态 —— 0 存活 / ESRCH 不存在 / EPERM 存活.
// 存在返回 YES, 确认不存在返回 NO, 其它错误按存活处理 (保守).
static BOOL TDProcAlive(pid_t pid) {
    if (kill(pid, 0) == 0) {
        return YES;
    }
    return errno != ESRCH;
}

static NSError *TDError(TDProcTableErrorCode code, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);

static NSError *TDError(TDProcTableErrorCode code, NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    if (code == TDProcTableErrorKillFailed) {
        // kill(2) 失败: 把 errno 原文带上, 不吞.
        msg = [msg stringByAppendingFormat:@" (errno=%d %@)", errno, strerror(errno)];
    }
    return [NSError errorWithDomain:TDProcTableErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg ?: @""}];
}

static NSMutableDictionary *TDNewEmptyRoot(void) {
    return [@{
        kRootVersion: @(kSchemaVersion),
        kRootBootTime: @(0),
        kRootEntries: [NSMutableArray array],
    } mutableCopy];
}

#pragma mark - TDProcEntry

@interface TDProcEntry ()
// 公共只读; 表内部回填走这里.
@property (nonatomic, readwrite) pid_t pid;
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite, copy) NSString *bundleId;
@property (nonatomic, readwrite, copy) NSString *containerUUID;
@property (nonatomic, readwrite) TDProcKind kind;
@property (nonatomic, readwrite) TDProcState state;
@property (nonatomic, readwrite, copy) NSString *exitNote;
@property (nonatomic, readwrite) NSTimeInterval registeredAt;
@property (nonatomic, readwrite) NSTimeInterval exitedAt;
@end

@implementation TDProcEntry

- (instancetype)initWithDictionary:(NSDictionary *)d {
    self = [super init];
    if (self) {
        _pid = (pid_t)[d[kPid] integerValue];
        _kind = (TDProcKind)[d[kKind] integerValue];
        _state = (TDProcState)[d[kState] integerValue];
        id name = d[kName];
        _name = [name isKindOfClass:NSString.class] ? name : @"";
        id bundleId = d[kBundleId];
        _bundleId = [bundleId isKindOfClass:NSString.class] ? bundleId : @"";
        id container = d[kContainerUUID];
        _containerUUID = [container isKindOfClass:NSString.class] ? container : @"";
        id note = d[kExitNote];
        _exitNote = [note isKindOfClass:NSString.class] ? note : @"";
        _registeredAt = [d[kRegisteredAt] doubleValue];
        _exitedAt = [d[kExitedAt] doubleValue];
    }
    return self;
}

@end

#pragma mark - TDProcTable

@interface TDProcTable ()
@property (nonatomic, strong) NSRecursiveLock *lock;
@end

@implementation TDProcTable

+ (instancetype)shared {
    static TDProcTable *table = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [[TDProcTable alloc] init];
    });
    return table;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [NSRecursiveLock new];
        _lock.name = @"TequilaDash.Surface.TDProcTable";
    }
    return self;
}

#pragma mark 路径

// 基准目录: 扩展进程经 LC_HOME_PATH 拿宿主 home (main.m 在自登记前 setenv),
// 宿主进程 HOME 即自身; 两进程最终落在同一份 Documents/TDSurface 下.
+ (NSString *)surfaceBaseDir {
    const char *env = getenv("LC_HOME_PATH");
    if (!env || !*env) {
        env = getenv("HOME");
    }
    NSString *base = (env && *env) ? [NSString stringWithUTF8String:env] : @"";
    if (base.length == 0) {
        base = NSHomeDirectory();
    }
    return [[base stringByAppendingPathComponent:@"Documents"]
        stringByAppendingPathComponent:@"TDSurface"];
}

+ (NSString *)tableFilePath {
    return [[self surfaceBaseDir] stringByAppendingPathComponent:@"proc_table.json"];
}

#pragma mark 文件层 (调用方须已持进程锁 + flock)

static void TDEnsureDir(NSString *dir) {
    if (mkdir(dir.fileSystemRepresentation, 0755) != 0 && errno != EEXIST) {
        // 下一层 save/load 会以更明确的 errno 报错, 这里不二次报.
    }
}

// 读表: 缺失/损坏 → 空表 (崩溃后可重建).
static NSMutableDictionary *TDLoadRootLocked(NSString *path, NSError **error) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        if (errno == ENOENT) {
            return TDNewEmptyRoot();
        }
        if (error) {
            *error = TDError(TDProcTableErrorIO, @"读表失败 %@", path.lastPathComponent);
        }
        return nil;
    }
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]] || !obj[kRootEntries]) {
        // 损坏表: 重建而不报死 (文件由 rename 原子替换, 正常不会出现; 防御半旧工具).
        return TDNewEmptyRoot();
    }
    return [obj mutableCopy];
}

// 写表: 临时文件 + rename 原子替换.
static BOOL TDSaveRootLocked(NSString *path, NSDictionary *root, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:NULL];
    if (!data) {
        if (error) {
            *error = TDError(TDProcTableErrorIO, @"序列化表失败");
        }
        return NO;
    }
    NSString *tmp = [path stringByAppendingFormat:@".tmp.%d", (int)getpid()];
    if (![data writeToFile:tmp options:NSDataWritingAtomic error:error]) {
        return NO;
    }
    if (rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        if (error) {
            *error = TDError(TDProcTableErrorIO, @"替换表失败 %@", path.lastPathComponent);
        }
        return NO;
    }
    return YES;
}

// 读-改-写总装: 进程锁 + flock + 加载期对账 + 变更才落盘.
// block 返回 YES = 有变更需落盘; NO = 只读语义 (reconcile 无变化时不写).
- (BOOL)mutateRoot:(BOOL (^)(NSMutableDictionary *root, NSError **error))block
             error:(NSError **)error {
    [_lock lock];
    BOOL ok = NO;
    int lockFd = -1;
    @try {
        NSString *dir = [TDProcTable surfaceBaseDir];
        TDEnsureDir(dir);
        NSString *path = [TDProcTable tableFilePath];

        NSString *lockPath = [dir stringByAppendingPathComponent:@"proc_table.lock"];
        lockFd = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_CLOEXEC, 0644);
        if (lockFd < 0) {
            if (error) {
                *error = TDError(TDProcTableErrorIO, @"打开文件锁失败");
            }
            return NO;
        }
        while (flock(lockFd, LOCK_EX) != 0) {
            if (errno != EINTR) {
                if (error) {
                    *error = TDError(TDProcTableErrorIO, @"flock 失败");
                }
                return NO;
            }
        }

        NSError *loadError = nil;
        NSMutableDictionary *root = TDLoadRootLocked(path, &loadError);
        if (!root) {
            if (error) {
                *error = loadError;
            }
            return NO;
        }

        // 加载期对账: bootTime 变了 → running 全部落 exited("reboot"), 内存即生效.
        double boot = TDBootTimeSeconds();
        double storedBoot = [root[kRootBootTime] doubleValue];
        if (boot != 0 && storedBoot != 0 && storedBoot != boot) {
            for (NSMutableDictionary *e in root[kRootEntries]) {
                if ([e[kState] integerValue] == TDProcStateRunning) {
                    e[kState] = @(TDProcStateExited);
                    e[kExitedAt] = @(TDNowSeconds());
                    e[kExitNote] = @"reboot";
                }
            }
        }
        if (boot != 0) {
            root[kRootBootTime] = @(boot);
        }

        BOOL changed = block(root, error);
        if (changed) {
            ok = TDSaveRootLocked(path, root, error);
        } else {
            ok = (error == nil || *error == nil);  // 只读路径: block 未报错即视为成功
        }
        if (flock(lockFd, LOCK_UN) != 0) {
            // 解锁失败只影响本次, 文件已 rename, 不回滚.
        }
        return ok;
    }
    @finally {
        if (lockFd >= 0) {
            close(lockFd);
        }
        [_lock unlock];
    }
}

#pragma mark 条目操作

static NSMutableArray *TDEntriesOf(NSMutableDictionary *root) {
    id entries = root[kRootEntries];
    if (![entries isKindOfClass:[NSMutableArray class]]) {
        entries = [NSMutableArray array];
        root[kRootEntries] = entries;
    }
    return entries;
}

- (BOOL)registerPid:(pid_t)pid
               name:(NSString *)name
           bundleId:(NSString *)bundleId
      containerUUID:(NSString *)containerUUID
               kind:(TDProcKind)kind
              error:(NSError **)error {
    if (pid <= 0) {
        if (error) {
            *error = TDError(TDProcTableErrorInvalidArg, @"register: 非法 pid=%d", (int)pid);
        }
        return NO;
    }
    return [self mutateRoot:^(NSMutableDictionary *root, NSError **err) {
        NSMutableArray *entries = TDEntriesOf(root);
        NSNumber *pidNum = @(pid);
        NSNumber *kindNum = @((NSInteger)kind);
        NSUInteger existingIdx = NSNotFound;
        for (NSUInteger i = 0; i < entries.count; i++) {
            NSDictionary *e = entries[i];
            if ([e[kPid] isEqualToNumber:pidNum] && [e[kKind] integerValue] == (NSInteger)kind) {
                existingIdx = i;
                break;
            }
        }
        double now = TDNowSeconds();
        if (existingIdx != NSNotFound) {
            // upsert 合并: 宿主先登记、扩展后自登记 (或反过来) 落到同一条.
            NSMutableDictionary *m = [entries[existingIdx] mutableCopy];
            if (name.length > 0) {
                m[kName] = name;
            }
            if (bundleId.length > 0) {
                m[kBundleId] = bundleId;
            }
            if (containerUUID.length > 0) {
                m[kContainerUUID] = containerUUID;
            }
            m[kPidStartTime] = @(TDProcStartTime(pid));
            if ([m[kState] integerValue] == TDProcStateExited) {
                // 同 pid 复活 (旧条目已死, 新一次 spawn): 重置为全新 running.
                m[kState] = @(TDProcStateRunning);
                m[kExitedAt] = @(0);
                m[kExitNote] = @"";
                m[kRegisteredAt] = @(now);
            }
            entries[existingIdx] = m;
        } else {
            NSMutableDictionary *m = [NSMutableDictionary dictionary];
            m[kPid] = pidNum;
            m[kKind] = kindNum;
            m[kName] = name.length > 0 ? name : @"";
            m[kBundleId] = bundleId.length > 0 ? bundleId : @"";
            m[kContainerUUID] = containerUUID.length > 0 ? containerUUID : @"";
            m[kState] = @(TDProcStateRunning);
            m[kRegisteredAt] = @(now);
            m[kExitedAt] = @(0);
            m[kExitNote] = @"";
            m[kPidStartTime] = @(TDProcStartTime(pid));
            [entries insertObject:m atIndex:0];
        }
        return YES;
    } error:error];
}

- (BOOL)markExitedForPid:(pid_t)pid note:(NSString *)note error:(NSError **)error {
    return [self mutateRoot:^(NSMutableDictionary *root, NSError **err) {
        NSMutableArray *entries = TDEntriesOf(root);
        BOOL touched = NO;
        double now = TDNowSeconds();
        for (NSMutableDictionary *e in entries) {
            if ([e[kPid] integerValue] == pid) {
                if ([e[kState] integerValue] != TDProcStateExited) {
                    e[kState] = @(TDProcStateExited);
                    e[kExitedAt] = @(now);
                }
                if (note.length > 0) {
                    e[kExitNote] = note;
                }
                touched = YES;
            }
        }
        if (!touched && err) {
            *err = TDError(TDProcTableErrorNotRegistered, @"markExited: pid=%d 不在表内", (int)pid);
        }
        return touched;
    } error:error];
}

- (BOOL)removePid:(pid_t)pid error:(NSError **)error {
    return [self mutateRoot:^(NSMutableDictionary *root, NSError **err) {
        NSMutableArray *entries = TDEntriesOf(root);
        NSMutableArray *kept = [NSMutableArray array];
        for (NSDictionary *e in entries) {
            if ([e[kPid] integerValue] != pid) {
                [kept addObject:e];
            }
        }
        BOOL removed = kept.count != entries.count;
        if (!removed && err) {
            *err = TDError(TDProcTableErrorNotRegistered, @"remove: pid=%d 不在表内", (int)pid);
        }
        root[kRootEntries] = kept;
        return removed;
    } error:error];
}

- (nullable TDProcEntry *)lookupPid:(pid_t)pid {
    [_lock lock];
    @try {
        NSDictionary *root = TDLoadRootLocked([TDProcTable tableFilePath], NULL);
        if (!root) {
            return nil;
        }
        for (NSDictionary *e in root[kRootEntries]) {
            if ([e[kPid] integerValue] == pid) {
                return [[TDProcEntry alloc] initWithDictionary:e];
            }
        }
        return nil;
    }
    @finally {
        [_lock unlock];
    }
}

- (NSArray<TDProcEntry *> *)listEntries {
    [self reconcile];
    [_lock lock];
    @try {
        NSDictionary *root = TDLoadRootLocked([TDProcTable tableFilePath], NULL);
        NSMutableArray<TDProcEntry *> *out = [NSMutableArray array];
        if (root) {
            for (NSDictionary *e in root[kRootEntries]) {
                [out addObject:[[TDProcEntry alloc] initWithDictionary:e]];
            }
        }
        // running 在前; 同组按 registeredAt 降序 (最新在前).
        [out sortUsingComparator:^NSComparisonResult(TDProcEntry *a, TDProcEntry *b) {
            if (a.state != b.state) {
                return a.state == TDProcStateRunning ? NSOrderedAscending : NSOrderedDescending;
            }
            if (a.registeredAt > b.registeredAt) {
                return NSOrderedAscending;
            }
            if (a.registeredAt < b.registeredAt) {
                return NSOrderedDescending;
            }
            return NSOrderedSame;
        }];
        return out;
    }
    @finally {
        [_lock unlock];
    }
}

#pragma mark kill / wait (真实 syscall)

- (BOOL)killPid:(pid_t)pid error:(NSError **)error {
    if (pid <= 0) {
        if (error) {
            *error = TDError(TDProcTableErrorInvalidArg, @"kill: 非法 pid=%d", (int)pid);
        }
        return NO;
    }
    // 门 1: 只对本表登记且 running 的 pid 发信号 —— 表外 pid (系统进程/别的 app)
    // 一律 ESRCH 拒绝, 这是 UI kill 按钮的越界护栏.
    TDProcEntry *entry = [self lookupPid:pid];
    if (!entry || entry.state != TDProcStateRunning) {
        if (error) {
            *error = TDError(TDProcTableErrorNotRegistered,
                             @"kill: pid=%d 不在表内或已退出", (int)pid);
        }
        return NO;
    }
    // 门 2: 真 kill(2). 扩展进程是宿主经 NSExtension 拉起的自家子进程, 同 uid 可签收;
    // 若沙盒拒发 (EPERM) 则如实上抛, 不做假成功.
    if (kill(pid, SIGKILL) != 0) {
        int err = errno;
        if (err == ESRCH) {
            // 门与 kill 之间刚死: 落账后按未命中上报.
            [self markExitedForPid:pid note:@"reconciled: ESRCH at kill" error:NULL];
            if (error) {
                *error = TDError(TDProcTableErrorNotRegistered, @"kill: pid=%d 已不存在", (int)pid);
            }
            return NO;
        }
        if (error) {
            *error = TDError(TDProcTableErrorKillFailed, @"kill(pid=%d, SIGKILL)", (int)pid);
        }
        return NO;
    }
    // 收口: 短轮询观察真死, 观察到才落 state=exited (SIGKILL 是异步的).
    long elapsedMs = 0;
    long budgetMs = (long)(kKillPollBudgetSeconds * 1000);
    while (elapsedMs < budgetMs) {
        usleep(kKillPollStepUs);
        elapsedMs += kKillPollStepUs / 1000;
        if (!TDProcAlive(pid)) {
            NSString *note = [NSString stringWithFormat:
                @"SIGKILL delivered; exit observed in %ldms", elapsedMs];
            [self markExitedForPid:pid note:note error:NULL];
            return YES;
        }
    }
    // 信号已送达但 2s 内未观察到退出: 如实保留 running 并记录, 交给 reconcile 收口.
    [self mutateRoot:^(NSMutableDictionary *root, NSError **err) {
        for (NSMutableDictionary *e in TDEntriesOf(root)) {
            if ([e[kPid] integerValue] == pid &&
                [e[kState] integerValue] == TDProcStateRunning) {
                e[kExitNote] = @"SIGKILL sent; still alive after poll";
            }
        }
        return YES;
    } error:NULL];
    return YES;
}

- (nullable TDProcEntry *)waitForPid:(pid_t)pid timeout:(NSTimeInterval)timeout {
    TDProcEntry *entry = [self lookupPid:pid];
    if (!entry) {
        return nil;
    }
    if (entry.state == TDProcStateExited) {
        return entry;
    }
    double registeredStart = 0;  // pid 重用检测锚点
    [_lock lock];
    @try {
        NSDictionary *root = TDLoadRootLocked([TDProcTable tableFilePath], NULL);
        for (NSDictionary *e in root[kRootEntries]) {
            if ([e[kPid] integerValue] == pid) {
                registeredStart = [e[kPidStartTime] doubleValue];
                break;
            }
        }
    }
    @finally {
        [_lock unlock];
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    for (;;) {
        if (!TDProcAlive(pid)) {
            [self markExitedForPid:pid note:@"wait: exit observed" error:NULL];
            return [self lookupPid:pid];
        }
        // pid 重用: 进程还活着但起始时间对不上 → 原进程已死, 按退出收口.
        double currentStart = TDProcStartTime(pid);
        if (registeredStart > 0 && currentStart > 0 &&
            fabs(currentStart - registeredStart) > 0.5) {
            [self markExitedForPid:pid note:@"wait: pid reused" error:NULL];
            return [self lookupPid:pid];
        }
        if (timeout <= 0 || [deadline timeIntervalSinceNow] <= 0) {
            return nil;
        }
        usleep(kWaitPollStepUs);
    }
}

#pragma mark 对账

- (void)reconcile {
    [self mutateRoot:^(NSMutableDictionary *root, NSError **err) {
        BOOL changed = NO;
        NSMutableArray *entries = TDEntriesOf(root);
        double now = TDNowSeconds();
        for (NSMutableDictionary *e in entries) {
            if ([e[kState] integerValue] != TDProcStateRunning) {
                continue;
            }
            pid_t pid = (pid_t)[e[kPid] integerValue];
            if (!TDProcAlive(pid)) {
                e[kState] = @(TDProcStateExited);
                e[kExitedAt] = @(now);
                e[kExitNote] = @"reconciled: ESRCH";
                changed = YES;
                continue;
            }
            double storedStart = [e[kPidStartTime] doubleValue];
            double currentStart = TDProcStartTime(pid);
            if (storedStart > 0 && currentStart > 0 &&
                fabs(currentStart - storedStart) > 0.5) {
                e[kState] = @(TDProcStateExited);
                e[kExitedAt] = @(now);
                e[kExitNote] = @"pid reused";
                changed = YES;
            }
        }
        // 剪枝: exited 超 7 天的条目删除, 表不无限增长.
        NSMutableArray *kept = [NSMutableArray array];
        for (NSDictionary *e in entries) {
            double exitedAt = [e[kExitedAt] doubleValue];
            BOOL stale = [e[kState] integerValue] == TDProcStateExited &&
                exitedAt > 0 && (now - exitedAt) > kPruneExitedAfterSeconds;
            if (!stale) {
                [kept addObject:e];
            } else {
                changed = YES;
            }
        }
        root[kRootEntries] = kept;
        return changed;
    } error:NULL];
}

@end
