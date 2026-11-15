//
//  TDRootfsUnpack.m
//  TequilaDash
//
//  Tier B-3 rootfs 解包引擎实现. parity 清单 / 差异点见 TDRootfsUnpack.h 头注释;
//  本文件只实现, 不再重复.
//

#import "TDRootfsUnpack.h"

#import "TDRootHideInit.h"

#import <dlfcn.h>
#import <stdio.h>
#import <string.h>
#import <sys/stat.h>

NSErrorDomain const TDRootfsUnpackErrorDomain = @"TDRootfsUnpackErrorDomain";

#pragma mark - libarchive 动态解析 (不产生链接期依赖)

// iOS 系统自带 /usr/lib/libarchive.2.dylib (Nyxian 同款依赖, 真机可用).
// SDK 不带 archive.h/tbd, 因此这里 dlopen + dlsym 出本实现用到的最小集合.
struct archive;
struct archive_entry;

static struct archive *(*td_ar_read_new)(void);
static int (*td_ar_read_support_format_all)(struct archive *);
static int (*td_ar_read_support_filter_all)(struct archive *);
static int (*td_ar_read_open_filename)(struct archive *, const char *, size_t);
static int (*td_ar_read_next_header)(struct archive *, struct archive_entry **);
static const char *(*td_ar_entry_pathname)(struct archive_entry *);
static int (*td_ar_read_data_block)(struct archive *, const void **, size_t *, int64_t *);
static int (*td_ar_read_free)(struct archive *);
static const char *(*td_ar_error_string)(struct archive *);
static struct archive *(*td_ar_write_disk_new)(void);
static int (*td_ar_write_disk_set_options)(struct archive *, int);
static int (*td_ar_write_header)(struct archive *, struct archive_entry *);
static ssize_t (*td_ar_write_data_block)(struct archive *, const void *, size_t, int64_t);
static int (*td_ar_write_finish_entry)(struct archive *);
static int (*td_ar_write_free)(struct archive *);

// 与 libarchive archive.h 对齐的常量 (本文件自持, 不引 vendored LC 头).
#define TD_AR_OK 0
#define TD_AR_EOF 1
// 上游 decomp options 0xD = TIME|ACL|FFLAGS; 本仓叠加两个 SECURE 位 (见头注释差异).
#define TD_AR_EXTRACT_TIME 0x0001
#define TD_AR_EXTRACT_ACL 0x0004
#define TD_AR_EXTRACT_FFLAGS 0x0008
#define TD_AR_EXTRACT_SECURE_NODOTDOT 0x0040
#define TD_AR_EXTRACT_SECURE_NOABSOLUTEPATHS 0x00010000
#define TD_AR_EXTRACT_OPTIONS (TD_AR_EXTRACT_TIME | TD_AR_EXTRACT_ACL | \
                               TD_AR_EXTRACT_FFLAGS | \
                               TD_AR_EXTRACT_SECURE_NODOTDOT | \
                               TD_AR_EXTRACT_SECURE_NOABSOLUTEPATHS)
#define TD_AR_READ_BLOCK_SIZE 0x2800 // 与 decomp unzipArchiveAtPath* 的块大小一致

static BOOL td_ar_resolve_symbols(NSError **error) {
    static dispatch_once_t once;
    static BOOL ok = NO;
    dispatch_once(&once, ^{
        void *h = dlopen("libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL);
        if (!h) return;
#define TD_DLSYM(var, name) do { \
        var = (typeof(var))dlsym(h, name); if (!var) return; } while (0)
        TD_DLSYM(td_ar_read_new, "archive_read_new");
        TD_DLSYM(td_ar_read_support_format_all, "archive_read_support_format_all");
        TD_DLSYM(td_ar_read_support_filter_all, "archive_read_support_filter_all");
        TD_DLSYM(td_ar_read_open_filename, "archive_read_open_filename");
        TD_DLSYM(td_ar_read_next_header, "archive_read_next_header");
        TD_DLSYM(td_ar_entry_pathname, "archive_entry_pathname");
        TD_DLSYM(td_ar_read_data_block, "archive_read_data_block");
        TD_DLSYM(td_ar_read_free, "archive_read_free");
        TD_DLSYM(td_ar_error_string, "archive_error_string");
        TD_DLSYM(td_ar_write_disk_new, "archive_write_disk_new");
        TD_DLSYM(td_ar_write_disk_set_options, "archive_write_disk_set_options");
        TD_DLSYM(td_ar_write_header, "archive_write_header");
        TD_DLSYM(td_ar_write_data_block, "archive_write_data_block");
        TD_DLSYM(td_ar_write_finish_entry, "archive_write_finish_entry");
        TD_DLSYM(td_ar_write_free, "archive_write_free");
#undef TD_DLSYM
        ok = YES;
    });
    if (!ok && error) {
        *error = [NSError errorWithDomain:TDRootfsUnpackErrorDomain
                                     code:TDRootfsUnpackErrorCodeArchiveRead
                                 userInfo:@{NSLocalizedDescriptionKey:
                                     @"libarchive.2.dylib 不可用 (dlopen/dlsym 失败)"}];
    }
    return ok;
}

#pragma mark - 小工具

static void td_set_error(NSError **error, TDRootfsUnpackErrorCode code, NSString *desc,
                         NSString *failureReason) {
    if (!error) return;
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = desc ?: @"TDRootfsUnpack failed";
    if (failureReason) userInfo[NSLocalizedFailureReasonErrorKey] = failureReason;
    *error = [NSError errorWithDomain:TDRootfsUnpackErrorDomain code:code userInfo:userInfo];
}

// Mach-O 判定: 读首 4 字节, thin arm64/arm (MH_MAGIC/_64) 或 fat (FAT_MAGIC/_64).
static BOOL td_path_is_macho(NSString *path) {
    uint8_t head[4];
    FILE *f = fopen(path.fileSystemRepresentation, "rb");
    if (!f) return NO;
    size_t n = fread(head, 1, sizeof(head), f);
    fclose(f);
    if (n != sizeof(head)) return NO;
    uint32_t magic = (uint32_t)head[0] | ((uint32_t)head[1] << 8) |
                     ((uint32_t)head[2] << 16) | ((uint32_t)head[3] << 24);
    return magic == 0xFEEDFACF || magic == 0xFEEDFACE ||
           magic == 0xCAFEBABE || magic == 0xCAFEBABF;
}

// 解包树模式收紧 (TDRootfsUnpack.h "沙盒收紧"): 目录 0755, 文件 mode&0755
// (setuid/setgid/sticky 清零, 组/其他可写位清零, 可执行位保留). 符号链接不动.
static void td_tighten_tree(NSString *root) {
    NSFileManager *fm = NSFileManager.defaultManager;
    // 不预取 URL resource keys (逐项用 attributesOfItemAtPath 重取); NSFileTypeKey
    // 不是 URL resource key (CI run 43554287571 实锤, 正名是 NSFileType 字典键).
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:root]
                                 includingPropertiesForKeys:nil
                                                    options:0
                                               errorHandler:nil];
    for (NSURL *url in enumerator) {
        NSString *path = url.path;
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        NSString *ftype = attrs[NSFileType];
        if (![ftype isEqualToString:NSFileTypeRegular] &&
            ![ftype isEqualToString:NSFileTypeDirectory]) {
            continue; // 符号链接等不动
        }
        BOOL isDir = [ftype isEqualToString:NSFileTypeDirectory];
        // NSDictionary.filePosixPermissions 在 SDK 里直接是 NSUInteger (非 NSNumber).
        mode_t mode = (mode_t)attrs.filePosixPermissions & 07777;
        mode_t clamped = isDir ? 0755 : (mode & 0755);
        if (clamped != mode) {
            chmod(path.fileSystemRepresentation, clamped);
        }
    }
    chmod(root.fileSystemRepresentation, 0755); // 根目录本身
}

// 顶层目录归一化 (TDRootfsUnpack.h P1 差异): procursus binpack 常见两种壳:
//   · <root>/opt/procursus/{usr,...}  (Nyxian jbroot=$vroot/opt/procursus 同构)
//   · <root>/<单顶层目录>/{usr,bin,...}
// 两种都把内容上提到 jbroot 根, 使 Tier A 的 /usr -> <root>/usr 前缀映射直接成立.
static NSString *td_flatten_layout(NSString *root) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *procursus = [root stringByAppendingPathComponent:@"opt/procursus"];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:procursus isDirectory:&isDir] && isDir) {
        for (NSString *child in [fm contentsOfDirectoryAtPath:procursus error:nil]) {
            NSString *from = [procursus stringByAppendingPathComponent:child];
            NSString *to = [root stringByAppendingPathComponent:child];
            if ([fm fileExistsAtPath:to]) continue; // 冲突保留现值, 不覆盖
            [fm moveItemAtPath:from toPath:to error:nil];
        }
        [fm removeItemAtPath:[root stringByAppendingPathComponent:@"opt"] error:nil];
        return @"opt/procursus 已上提到 jbroot 根";
    }

    NSArray *top = [fm contentsOfDirectoryAtPath:root error:nil];
    if (top.count != 1) return nil;
    NSString *only = [root stringByAppendingPathComponent:top.firstObject];
    if (![fm fileExistsAtPath:only isDirectory:&isDir] || !isDir) return nil;
    // 明确的根级目录 (usr/bin/...) 不剥壳.
    static NSArray<NSString *> *rootLevel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rootLevel = @[@"usr", @"bin", @"sbin", @"etc", @"opt", @"var", @"root",
                      @"tmp", @"dev", @"Applications", @"Library"];
    });
    if ([rootLevel containsObject:top.firstObject]) return nil;
    if (![fm fileExistsAtPath:[only stringByAppendingPathComponent:@"usr"]] &&
        ![fm fileExistsAtPath:[only stringByAppendingPathComponent:@"bin"]]) {
        return nil; // 不是 rootfs 形状, 不动
    }
    for (NSString *child in [fm contentsOfDirectoryAtPath:only error:nil]) {
        NSString *from = [only stringByAppendingPathComponent:child];
        NSString *to = [root stringByAppendingPathComponent:child];
        if ([fm fileExistsAtPath:to]) continue;
        [fm moveItemAtPath:from toPath:to error:nil];
    }
    [fm removeItemAtPath:only error:nil];
    return [NSString stringWithFormat:@"顶层 %@/ 已剥壳上提", top.firstObject];
}

// 收集 root 内全部 Mach-O 文件 (不含符号链接).
static NSArray<NSString *> *td_collect_machos(NSString *root) {
    NSFileManager *fm = NSFileManager.defaultManager;
    // 同 td_tighten_tree: 不预取 URL resource keys.
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:root]
                                 includingPropertiesForKeys:nil
                                                    options:0
                                               errorHandler:nil];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *url in enumerator) {
        NSString *path = url.path;
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        if (![attrs[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
        if (td_path_is_macho(path)) [paths addObject:path];
    }
    return paths;
}

// dir 相对 jbroot 根的相对路径 ("../../"; dir==root 时 ".").
static NSString *td_relative_path_to_root(NSString *dir, NSString *root) {
    NSString *rel = dir.length > root.length ? [dir substringFromIndex:root.length] : @"";
    if ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];
    NSUInteger depth = 0;
    for (NSString *part in [rel pathComponents]) {
        if (part.length) depth++;
    }
    if (depth == 0) return @".";
    NSMutableString *target = [NSMutableString string];
    for (NSUInteger i = 0; i < depth; i++) {
        if (i) [target appendString:@"/"];
        [target appendString:@".."];
    }
    return target;
}

#pragma mark - 重签 (TDRootfsUnpack.h P2)

// ZSign 目标里的入口 (桥接头 TequilaDash-Bridging-Header.h:89 同款声明).
extern int zsign_adhoc_file(const char *path, const char *bundleId,
                            const char *entXml, int entLen);

static NSData *td_host_certificate(void) {
    Class lc = NSClassFromString(@"LCUtils"); // LiveContainerSwiftUI framework
    if (lc && [lc respondsToSelector:@selector(certificateData)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        return [lc performSelector:@selector(certificateData)];
#pragma clang diagnostic pop
    }
    return nil;
}

static NSString *td_host_certificate_password(void) {
    Class lc = NSClassFromString(@"LCSharedUtils"); // LC 核心, 编进主二进制
    if (lc && [lc respondsToSelector:@selector(certificatePassword)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        return [lc performSelector:@selector(certificatePassword)];
#pragma clang diagnostic pop
    }
    return nil;
}

// 按宿主身份批量重签 (LCUtils.m:234 signFilesWithZSignWithURLs 的同款 ZSigner 入口);
// 无宿主证书时逐文件 zsign_adhoc_file 回落 (MachoReSign.swift:44 同款). 返回处理数.
static NSUInteger td_resign_machos(NSArray<NSString *> *paths, NSString *jbrootPath,
                                   NSError **error) {
    if (paths.count == 0) return 0;
    Class signer = NSClassFromString(@"ZSigner"); // ZSign 引擎, 编进主二进制
    NSData *cert = td_host_certificate();
    NSString *pass = cert ? td_host_certificate_password() : nil;

    if (signer && cert) {
        SEL sel = @selector(signMachOPathArr:bundleId:cert:pass:completionHandler:);
        NSMethodSignature *sig = [signer methodSignatureForSelector:sel];
        if (sig.numberOfArguments == 7) { // self,_cmd,paths,bundleId,cert,pass,handler
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block BOOL success = NO;
            __block NSString *signErrorText = nil;
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:signer];
            [inv setSelector:sel];
            [inv retainArguments];
            NSArray<NSString *> *arr = paths;
            NSString *bundleId = NSBundle.mainBundle.bundleIdentifier;
            NSUInteger idx = 2;
            [inv setArgument:&arr atIndex:idx++];
            [inv setArgument:&bundleId atIndex:idx++];
            [inv setArgument:&cert atIndex:idx++];
            [inv setArgument:&pass atIndex:idx++];
            void (^handler)(BOOL, NSError *) = ^(BOOL ok, NSError *e) {
                success = ok;
                if (!ok && e) signErrorText = e.localizedDescription;
                dispatch_semaphore_signal(sem);
            };
            [inv setArgument:&handler atIndex:idx++];
            [inv invoke];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER); // 异步完成才回 handler
            if (success) return paths.count;
            td_set_error(error, TDRootfsUnpackErrorCodeSign,
                         [NSString stringWithFormat:@"宿主身份重签失败 (%lu 个文件)",
                          (unsigned long)paths.count],
                         signErrorText ?: @"ZSigner 未返回成功");
            return 0;
        }
    }

    // 回落: adhoc 重签 (无宿主证书 / ZSigner 接口异常).
    NSString *ent = @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
        "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">"
        "<plist version=\"1.0\"><dict/></plist>";
    NSInteger failures = 0;
    for (NSString *path in paths) {
        int code = zsign_adhoc_file(path.fileSystemRepresentation,
                                    NSBundle.mainBundle.bundleIdentifier.fileSystemRepresentation,
                                    ent.UTF8String, (int)ent.length);
        if (code != 0) failures++;
    }
    if (failures == 0) return paths.count;
    td_set_error(error, TDRootfsUnpackErrorCodeSign,
                 [NSString stringWithFormat:@"adhoc 重签 %ld/%lu 个文件失败",
                  (long)failures, (unsigned long)paths.count],
                 [NSString stringWithFormat:@"jbroot=%@", jbrootPath]);
    return 0;
}

#pragma mark - symredirect (TDRootfsUnpack.h P3)

// vendored roothide symredirect CLI -> 库函数 (vendor/roothide/symredirect.cpp 尾注).
extern int symredirect_process_file(const char *target, const char *tmpdir,
                                    char *errbuf, size_t errbufsize);

// 找到 app 内嵌的 shim 库 (TDLibVrootApi 跳板 + TDLibVroot 实现两件, project.yml 双 target).
static NSString *td_find_embedded_dylib(NSString *name) {
    NSBundle *main = NSBundle.mainBundle;
    NSArray<NSString *> *candidates = @[
        [main.bundleURL.path stringByAppendingPathComponent:
            [NSString stringWithFormat:@"Frameworks/%@", name]],
        [main.bundleURL.path stringByAppendingPathComponent:
            [NSString stringWithFormat:@"Frameworks/lib%@", name]],
        [main.bundleURL.path stringByAppendingPathComponent:name],
    ];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *path in candidates) {
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

// shim 两件拷到 <jbroot>/usr/lib/: 跳板 TDLibVrootApi.dylib -> libvrootapi.dylib
// (symredirect 硬编码名), 实现 TDLibVroot.dylib -> TDLibVroot.dylib (跳板的
// LC_LOAD_DYLIB @loader_path/TDLibVroot.dylib 指名). 之后逐文件改写 + .jbroot 相对链接.
// 改写必然破坏旧签名, 因此调用方必须在之后跑重签.
static NSUInteger td_symredirect_machos(NSArray<NSString *> *paths, NSString *jbrootPath,
                                        NSMutableArray<NSString *> *warnings) {
    if (paths.count == 0) return 0;
    NSString *shimSource = td_find_embedded_dylib(@"TDLibVrootApi.dylib");
    NSString *implSource = td_find_embedded_dylib(@"TDLibVroot.dylib");
    if (!shimSource || !implSource) {
        if (warnings) [warnings addObject:@"TDLibVrootApi/TDLibVroot 未随包嵌入, symredirect 跳过"];
        return 0;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *shimDir = [jbrootPath stringByAppendingPathComponent:@"usr/lib"];
    NSString *shimDest = [shimDir stringByAppendingPathComponent:@"libvrootapi.dylib"];
    NSString *implDest = [shimDir stringByAppendingPathComponent:@"TDLibVroot.dylib"];
    if (![fm createDirectoryAtPath:shimDir withIntermediateDirectories:YES
                        attributes:@{NSFilePosixPermissions: @0755}
                             error:nil]) {
        if (warnings) [warnings addObject:@"无法创建 usr/lib, symredirect 跳过"];
        return 0;
    }
    BOOL shimOk = YES;
    [fm removeItemAtPath:shimDest error:nil];
    shimOk &= [fm copyItemAtPath:shimSource toPath:shimDest error:nil];
    [fm removeItemAtPath:implDest error:nil];
    shimOk &= [fm copyItemAtPath:implSource toPath:implDest error:nil];
    if (!shimOk) {
        if (warnings) [warnings addObject:@"shim 库拷贝失败, symredirect 跳过"];
        return 0;
    }
    chmod(shimDest.fileSystemRepresentation, 0755);
    chmod(implDest.fileSystemRepresentation, 0755);

    NSString *tmpDir = NSTemporaryDirectory();
    NSUInteger redirected = 0;
    NSMutableSet<NSString *> *patchedDirs = [NSMutableSet set];
    for (NSString *path in paths) {
        char errbuf[256] = {0};
        if (symredirect_process_file(path.fileSystemRepresentation,
                                     tmpDir.fileSystemRepresentation,
                                     errbuf, sizeof(errbuf)) == 0) {
            redirected++;
            [patchedDirs addObject:path.stringByDeletingLastPathComponent];
        } else if (warnings) {
            [warnings addObject:[NSString stringWithFormat:@"%@: %s",
                                 path.lastPathComponent, errbuf]];
        }
    }
    // @loader_path/.jbroot/usr/lib/libvrootapi.dylib 约定 (上游 updatelinks 语义):
    // 每个含被改写二进制的目录放一个指回 jbroot 根的相对符号链接.
    for (NSString *dir in patchedDirs) {
        NSString *link = [dir stringByAppendingPathComponent:@".jbroot"];
        [fm removeItemAtPath:link error:nil];
        [fm createSymbolicLinkAtPath:link
                  withDestinationPath:td_relative_path_to_root(dir, jbrootPath)
                                error:nil];
    }
    return redirected;
}

#pragma mark - P1 解包循环

// libarchive 解包主循环 (parity 见 TDRootfsUnpack.h). 失败返回 NO 并填 error.
static BOOL td_extract_archive(NSString *archivePath, NSUInteger *entryCount,
                               NSError **error) {
    struct archive *reader = td_ar_read_new();
    struct archive *writer = td_ar_write_disk_new();
    td_ar_read_support_format_all(reader);
    td_ar_read_support_filter_all(reader);
    td_ar_write_disk_set_options(writer, TD_AR_EXTRACT_OPTIONS);
    if (td_ar_read_open_filename(reader, archivePath.fileSystemRepresentation,
                                 TD_AR_READ_BLOCK_SIZE) != TD_AR_OK) {
        td_set_error(error, TDRootfsUnpackErrorCodeArchiveRead, @"归档读取失败",
                     @(td_ar_error_string(reader) ?: "archive_read_open_filename failed"));
        td_ar_read_free(reader);
        td_ar_write_free(writer);
        return NO;
    }

    NSUInteger entries = 0;
    BOOL ok = NO;
    NSString *failure = nil;
    for (;;) {
        struct archive_entry *entry = NULL;
        int rc = td_ar_read_next_header(reader, &entry);
        if (rc == TD_AR_EOF) {
            ok = YES;
            break;
        }
        if (rc != TD_AR_OK) {
            failure = @(td_ar_error_string(reader) ?: "archive_read_next_header failed");
            break;
        }
        entries++;
        if (td_ar_write_header(writer, entry) != TD_AR_OK) {
            failure = [NSString stringWithFormat:@"entry '%s': %s",
                       td_ar_entry_pathname(entry),
                       td_ar_error_string(writer) ?: "archive_write_header failed"];
            break;
        }
        const void *buff = NULL;
        size_t size = 0;
        int64_t offset = 0;
        BOOL dataFailed = NO;
        for (;;) {
            int r = td_ar_read_data_block(reader, &buff, &size, &offset);
            if (r == TD_AR_EOF) break;
            if (r < TD_AR_OK) {
                failure = @(td_ar_error_string(reader) ?: "archive_read_data_block failed");
                dataFailed = YES;
                break;
            }
            if (td_ar_write_data_block(writer, buff, size, offset) < TD_AR_OK) {
                failure = @(td_ar_error_string(writer) ?: "archive_write_data_block failed");
                dataFailed = YES;
                break;
            }
        }
        if (dataFailed) break;
        if (td_ar_write_finish_entry(writer) != TD_AR_OK) {
            failure = @(td_ar_error_string(writer) ?: "archive_write_finish_entry failed");
            break;
        }
    }

    // TD_AR_EXTRACT_FFLAGS 语义下 libarchive 在 finish_entry 时统一落盘; 循环内已逐条调用.
    td_ar_read_free(reader);
    td_ar_write_free(writer);
    if (!ok) {
        td_set_error(error, TDRootfsUnpackErrorCodeArchiveRead,
                     @"归档解包失败", failure);
        return NO;
    }
    *entryCount = entries;
    return YES;
}

#pragma mark - 主流程

// 只读公共面 + 私有写入口 (解包方法内赋值).
@interface TDRootfsUnpackResult ()
@property (nonatomic, readwrite) NSURL *jbrootURL;
@property (nonatomic, readwrite, copy, nullable) NSString *jbrootBrand;
@property (nonatomic, readwrite) NSUInteger entryCount;
@property (nonatomic, readwrite, copy, nullable) NSString *layoutNote;
@property (nonatomic, readwrite) NSUInteger machoCount;
@property (nonatomic, readwrite) NSUInteger symredirectedCount;
@property (nonatomic, readwrite) NSUInteger resignedCount;
@property (nonatomic, readwrite, copy, nullable) NSArray<NSString *> *warnings;
@end

@implementation TDRootfsUnpackResult
@end

@implementation TDRootfsUnpack

+ (NSURL *)rootfsBaseURL {
    // 与 LCPathBridge.rootfs 同点 (LCUIAdapters/LCPathBridge.swift:52).
    return [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:
                                   @"Documents/rootfs"] isDirectory:YES];
}

+ (BOOL)removeRootfsAtURL:(NSURL *)jbrootURL error:(NSError **)error {
    NSString *path = jbrootURL.path;
    NSString *base = self.rootfsBaseURL.path;
    NSString *last = path.lastPathComponent;
    if (path.length <= base.length || ![path hasPrefix:base] ||
        ![last containsString:@".jbroot-"]) {
        td_set_error(error, TDRootfsUnpackErrorCodeDestination,
                     @"拒绝删除: 目标不在 Documents/rootfs 下或不是 .jbroot-* 目录", path);
        return NO;
    }
    NSError *fmError = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:path error:&fmError]) {
        td_set_error(error, TDRootfsUnpackErrorCodeDestination,
                     @"删除 jbroot 根失败", fmError.localizedDescription);
        return NO;
    }
    return YES;
}

+ (nullable TDRootfsUnpackResult *)unpackArchiveAtURL:(NSURL *)archiveURL
                                       destinationURL:(NSURL *)destinationURL
                                              options:(TDRootfsUnpackOptions)options
                                                error:(NSError **)error {
    // zstd 明确前置拒绝 (TDRootfsUnpack.h 差异点).
    NSString *lower = archiveURL.path.lowercaseString;
    if ([lower hasSuffix:@".zst"] || [lower hasSuffix:@".tar.zst"]) {
        td_set_error(error, TDRootfsUnpackErrorCodeZstdUnsupported,
                     @"不支持 .tar.zst/.zst: iOS 无系统 libzstd, 本仓 SWCompression 无 zstd "
                     "解码器, Apple 系 libarchive 也无 zstd filter; 请提供 .tar/.zip 归档",
                     archiveURL.path);
        return nil;
    }
    if (!td_ar_resolve_symbols(error)) return nil;

    // 目标目录: 显式 destination 或 per-guest 随机根 <rootfsBase>/.jbroot-<16hex>.
    NSURL *baseURL = [self rootfsBaseURL];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *fmError = nil;
    if (![fm createDirectoryAtURL:baseURL withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @0700}
                            error:&fmError]) {
        td_set_error(error, TDRootfsUnpackErrorCodeDestination,
                     @"无法创建 Documents/rootfs 基目录", fmError.localizedDescription);
        return nil;
    }

    NSURL *jbrootURL = nil;
    NSString *brand = nil;
    if (destinationURL) {
        if (![destinationURL.path hasPrefix:baseURL.path]) {
            td_set_error(error, TDRootfsUnpackErrorCodeDestination,
                         @"目标目录必须位于 Documents/rootfs 下 (沙盒收紧)",
                         destinationURL.path);
            return nil;
        }
        if ([fm fileExistsAtPath:destinationURL.path]) {
            td_set_error(error, TDRootfsUnpackErrorCodeDestination,
                         @"目标目录已存在", destinationURL.path);
            return nil;
        }
        jbrootURL = destinationURL;
    } else {
        // per-guest 随机根: roothide 的 .jbroot-<16hex> 命名 (brand 校验合法),
        // 真实路径对访客无语义 (hiding: 路径不可猜).
        for (int attempt = 0; attempt < 8 && !jbrootURL; attempt++) {
            char name[64];
            if (!TDRootHideMakeRandomRootName(name, sizeof(name))) continue;
            NSURL *candidate = [baseURL URLByAppendingPathComponent:@(name)];
            if (![fm fileExistsAtPath:candidate.path]) {
                jbrootURL = candidate;
                brand = [@((char *)name + strlen(".jbroot-")) copy];
            }
        }
        if (!jbrootURL) {
            td_set_error(error, TDRootfsUnpackErrorCodeDestination,
                         @"无法生成随机 jbroot 目录名", baseURL.path);
            return nil;
        }
    }

    NSString *jbrootPath = jbrootURL.path;
    if (![fm createDirectoryAtURL:jbrootURL withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @0755}
                            error:&fmError]) {
        td_set_error(error, TDRootfsUnpackErrorCodeDestination,
                     @"无法创建 jbroot 目录", fmError.localizedDescription ?: jbrootPath);
        return nil;
    }

    // ── P1: libarchive 解包 ──────────────────────────────────────────────
    NSUInteger entryCount = 0;
    if (!td_extract_archive(archiveURL.path, &entryCount, error)) {
        [fm removeItemAtPath:jbrootPath error:nil]; // 失败即清场, 不留半棵树
        return nil;
    }

    // ── 沙盒收紧 + 顶层归一化 ────────────────────────────────────────────
    td_tighten_tree(jbrootPath);
    NSString *layoutNote = td_flatten_layout(jbrootPath);
    if (layoutNote) td_tighten_tree(jbrootPath);

    // ── Mach-O 收集 + P3 symredirect + P2 重签 ───────────────────────────
    NSArray<NSString *> *machos = td_collect_machos(jbrootPath);
    NSUInteger redirected = 0;
    NSUInteger resigned = 0;
    NSMutableArray<NSString *> *warnings = [NSMutableArray array];
    BOOL needResign = (options & (TDRootfsUnpackOptionResignWithHostIdentity |
                                  TDRootfsUnpackOptionSymredirect)) != 0;
    if (options & TDRootfsUnpackOptionSymredirect) {
        redirected = td_symredirect_machos(machos, jbrootPath, warnings);
        if (redirected > 0) td_tighten_tree(jbrootPath); // 改写会 chmod(mode&0777)
    }
    if (needResign) {
        resigned = td_resign_machos(machos, jbrootPath, error);
        if (resigned == 0 && machos.count > 0) {
            [fm removeItemAtPath:jbrootPath error:nil]; // 签名失败同样清场
            return nil;
        }
    }

    TDRootfsUnpackResult *result = [[TDRootfsUnpackResult alloc] init];
    result.jbrootURL = jbrootURL;
    result.jbrootBrand = brand;
    result.entryCount = entryCount;
    result.layoutNote = layoutNote;
    result.machoCount = machos.count;
    result.symredirectedCount = redirected;
    result.resignedCount = resigned;
    if (warnings.count) {
        result.warnings = [warnings copy];
    }
    return result;
}

@end
