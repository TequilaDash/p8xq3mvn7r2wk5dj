//
//  TDInodeScan.m
//  TequilaDash
//
//  参考（MIT/Apache 源码对比）：kolbicz/WQFiles WQAccess.m `wq_volume_max_inode`
//  + `wq_scan_children`（多线程分块 fsgetpath + 磁盘缓存 + 增量）。
//  只做**读路径枚举**，不触碰 worse_query 签扩展链路。
//

#import "TDInodeScan.h"

#import <fcntl.h>
#import <sys/fsgetpath.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <unistd.h>

extern ssize_t fsgetpath(char *buf, size_t buflen, fsid_t *fsid, uint64_t objid);

static const int64_t kTDInodeMargin = 100000;
static const int kTDScanCacheVersion = 1;

static NSString *TDNormalize(NSString *path) {
    if ([path hasPrefix:@"/private/var/"]) return path;
    if ([path hasPrefix:@"/var/"]) return [@"/private" stringByAppendingString:path];
    return path;
}

static NSString *TDCachePath(void) {
    NSString *dir = NSTemporaryDirectory();
    return dir.length ? [dir stringByAppendingPathComponent:@"td-inode-scan.plist"] : nil;
}

/// 探测当前卷最新 inode（必须在目标 fsid 所在卷上创建临时文件）。
static int64_t TDProbeInode(fsid_t fsid, int64_t *outProbe) {
    if (outProbe) *outProbe = 0;
    NSArray<NSString *> *directories = @[
        NSTemporaryDirectory() ?: @"",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"],
        [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject] ?: @"",
    ];
    for (NSString *directory in directories) {
        if (!directory.length) continue;
        NSString *probe = [directory stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"td-inode-%u", arc4random()]];
        int fd = open(probe.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY, 0600);
        if (fd < 0) continue;
        struct stat st = {0};
        struct statfs sfs = {0};
        BOOL ok = fstat(fd, &st) == 0 && fstatfs(fd, &sfs) == 0;
        int err = errno;
        close(fd);
        unlink(probe.fileSystemRepresentation);
        if (!ok) continue;
        if (memcmp(&sfs.f_fsid, &fsid, sizeof(fsid)) != 0) continue;
        if ((uint64_t)st.st_ino > (uint64_t)INT64_MAX - (uint64_t)kTDInodeMargin) return 0;
        if (outProbe) *outProbe = (int64_t)st.st_ino;
        return (int64_t)st.st_ino + kTDInodeMargin;
    }
    return 0;
}

static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *TDLoadCache(
    fsid_t fsid, int64_t *outProbe, NSString **whyFull) {
    *outProbe = 0;
    NSString *path = TDCachePath();
    if (!path.length) { *whyFull = @"no temp dir"; return [NSMutableDictionary dictionary]; }
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![cache isKindOfClass:[NSDictionary class]]) { *whyFull = @"no saved scan"; return [NSMutableDictionary dictionary]; }
    NSNumber *version = cache[@"version"], *f0 = cache[@"fsid0"], *f1 = cache[@"fsid1"], *probe = cache[@"probe"];
    if (![version isKindOfClass:[NSNumber class]] || version.integerValue != kTDScanCacheVersion ||
        ![f0 isKindOfClass:[NSNumber class]] || ![f1 isKindOfClass:[NSNumber class]] ||
        ![probe isKindOfClass:[NSNumber class]] || probe.longLongValue <= 0) {
        *whyFull = @"cache unreadable"; return [NSMutableDictionary dictionary];
    }
    if (f0.intValue != fsid.val[0] || f1.intValue != fsid.val[1]) { *whyFull = @"different volume"; return [NSMutableDictionary dictionary]; }
    if (probe.longLongValue > INT64_MAX - kTDInodeMargin) { *whyFull = @"volume ids were reset"; return [NSMutableDictionary dictionary]; }
    NSMutableDictionary *roots = [NSMutableDictionary dictionary];
    for (NSString *base in cache[@"roots"]) {
        NSDictionary *entries = cache[@"roots"][base];
        if (![entries isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary<NSString *, NSNumber *> *map = [NSMutableDictionary dictionary];
        for (NSString *p in entries) {
            id v = entries[p];
            if ([v isKindOfClass:[NSNumber class]]) map[p] = v;
        }
        roots[base] = map;
    }
    *outProbe = probe.longLongValue;
    return roots;
}

static void TDSaveCache(fsid_t fsid, int64_t probe,
                        NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *roots) {
    NSString *path = TDCachePath();
    if (!path.length) return;
    NSDictionary *cache = @{ @"version": @(kTDScanCacheVersion),
                             @"fsid0": @(fsid.val[0]), @"fsid1": @(fsid.val[1]),
                             @"probe": @(probe), @"roots": roots };
    if (![cache writeToFile:path atomically:YES]) {
        NSLog(@"[TDInodeScan] cannot save scan cache %@", path);
    }
}

/// 复核缓存条目：fsgetpath(ino) 必须还落在同一 base 下；否则丢弃该条目。
static void TDVerifyCache(fsid_t fsid,
                          NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *roots,
                          NSMutableDictionary<NSString *, NSNumber *> *target) {
    char buf[1200];
    for (NSString *base in roots) {
        NSMutableDictionary<NSString *, NSNumber *> *map = roots[base];
        NSMutableArray<NSString *> *stale = nil;
        for (NSString *p in map) {
            int64_t ino = map[p].longLongValue;
            if (ino <= 0) continue;
            ssize_t n = fsgetpath(buf, sizeof(buf), &fsid, (uint64_t)ino);
            BOOL same = n > 0 && strcmp(buf, p.UTF8String) == 0;
            if (!same) {
                if (!stale) stale = [NSMutableArray array];
                [stale addObject:p];
            }
        }
        if (stale) {
            for (NSString *p in stale) [map removeObjectForKey:p];
            NSLog(@"[TDInodeScan] cache verify: dropped %lu stale entries", (unsigned long)stale.count);
        }
        if ([base isEqualToString:target]) *target = map;
    }
}

static void TDScanRange(fsid_t fsid, int64_t first, int64_t last,
                        NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *roots,
                        int64_t *outScanned) {
    if (last < first) return;
    int64_t total = last - first + 1;
    int64_t chunkSize = MAX(4096, total / 64);
    int64_t chunks = (total + chunkSize - 1) / chunkSize;
    __block int64_t scanned = 0;
    dispatch_semaphore_t lock = dispatch_semaphore_create(1);
    NSMutableArray<NSString *> *baseList = [roots.allKeys mutableCopy];
    NSUInteger baseCount = baseList.count;
    dispatch_apply(chunks, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t c) {
        char buf[1200];
        NSMutableArray<NSMutableDictionary<NSString *, NSNumber *> *> *local = [NSMutableArray arrayWithCapacity:baseCount];
        for (NSUInteger i = 0; i < baseCount; i++) {
            [local addObject:[NSMutableDictionary dictionary]];
        }
        int64_t firstId = first + (int64_t)c * chunkSize;
        int64_t lastId = MIN(firstId + chunkSize - 1, last);
        for (int64_t ino = firstId; ino <= lastId; ino++) {
            ssize_t n = fsgetpath(buf, sizeof(buf), &fsid, (uint64_t)ino);
            if (n <= 0) continue;
            for (NSUInteger i = 0; i < baseCount; i++) {
                const char *prefix = baseList[i].UTF8String;
                size_t prefixLen = strlen(prefix);
                if (strncmp(buf, prefix, prefixLen) == 0 && buf[prefixLen] == '/' &&
                    strchr(buf + prefixLen + 1, '/') == NULL) {
                    local[i][[NSString stringWithUTF8String:buf]] = @(ino);
                    break;
                }
            }
        }
        dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
        for (NSUInteger i = 0; i < baseCount; i++) {
            NSMutableDictionary<NSString *, NSNumber *> *map = local[i];
            if (map.count) {
                NSMutableDictionary<NSString *, NSNumber *> *dst = roots[baseList[i]];
                if (!dst) { dst = [NSMutableDictionary dictionary]; roots[baseList[i]] = dst; }
                [dst addEntriesFromDictionary:map];
            }
        }
        scanned += lastId - firstId + 1;
        dispatch_semaphore_signal(lock);
    });
    if (outScanned) *outScanned = scanned;
}

NSArray<NSString *> *td_wq_enumerate(NSString *dir, int64_t *outScanned, int64_t *outProbe) {
    if (outScanned) *outScanned = 0;
    if (outProbe) *outProbe = 0;
    if (!dir.length) return nil;
    NSString *base = TDNormalize(dir);

    struct statfs sfs;
    if (statfs(base.fileSystemRepresentation, &sfs) != 0) return nil;
    fsid_t fsid = sfs.f_fsid;

    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    [lock lock];
    @try {

    int64_t probeInode = 0;
    int64_t limit = TDProbeInode(fsid, &probeInode);
    if (outProbe) *outProbe = probeInode;
    if (limit <= 0) return nil;

    NSString *whyFull = nil;
    int64_t cachedProbe = 0;
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *roots =
        TDLoadCache(fsid, &cachedProbe, &whyFull);
    NSMutableDictionary<NSString *, NSNumber *> *target = roots[base] ?: [NSMutableDictionary dictionary];
    roots[base] = target;

    int64_t scanned = 0;
    if (cachedProbe <= 0 || cachedProbe > probeInode) {
        TDVerifyCache(fsid, roots, target);
        TDScanRange(fsid, 1, limit, roots, &scanned);
        NSLog(@"[TDInodeScan] full scan 1..%lld scanned=%lld roots=%lu why=%@",
              (long long)limit, (long long)scanned, (unsigned long)roots.count, whyFull ?: @"first");
    } else {
        TDVerifyCache(fsid, roots, target);
        if (cachedProbe + 1 <= probeInode) {
            TDScanRange(fsid, cachedProbe + 1, limit, roots, &scanned);
        }
        if (scanned > 0) {
            NSLog(@"[TDInodeScan] incremental %lld..%lld scanned=%lld", (long long)cachedProbe + 1,
                  (long long)limit, (long long)scanned);
        }
    }

    TDSaveCache(fsid, probeInode, roots);
    if (outScanned) *outScanned = scanned;
    return [target.allKeys sortedArrayUsingSelector:@selector(compare:)];
    } @finally {
        [lock unlock];
    }
}

int64_t td_wq_cached_probe(void) {
    NSString *path = TDCachePath();
    if (!path.length) return 0;
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:path];
    NSNumber *probe = cache[@"probe"];
    return [probe isKindOfClass:[NSNumber class]] ? probe.longLongValue : 0;
}