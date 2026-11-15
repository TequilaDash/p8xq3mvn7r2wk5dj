//
//  TDRootfsUnpack.h
//  TequilaDash
//
//  Tier B-3 rootfs 解包引擎 (宿主 app 侧, 后台队列调用): procursus binpack / 最小
//  rootfs 归档 -> Documents/rootfs/.jbroot-<16hex>/, 可选 ZSigner 重签 + roothide
//  symredirect 改写. 解包本体只读系统 libarchive (/usr/lib/libarchive.2.dylib, dlopen
//  解析, 不产生链接期依赖); zstd 明确不支持 (见 TDRootfsUnpackErrorCodeZstdUnsupported).
//
//  ── 函数级 parity 清单 (EPSL 洁净室: 只对行为, 未拷贝任何 EPSL 文本) ──────────
//  [P1] 解包语义 — 参照 decomp_nyxian_app.c unzipArchiveAtPath@0x10002e1dc /
//       unzipArchiveAtPathWithoutParentDirectory@0x10002e38c (Nyxian app 侧)
//         输入: 归档文件路径 (libarchive 支持的格式), 目标目录
//         语义: archive_read_new -> support_format_all/support_filter_all ->
//               archive_read_open_filename(块 0x2800) -> 循环
//               archive_read_next_header / archive_write_header / 数据块拷贝
//               (archive_write_disk_new + archive_write_disk_set_options)
//         输出: 目标目录内的解包树; 失败即中止
//         差异: 上游 decomp 的 options 0xD = TIME|ACL|FFLAGS (无任何 SECURE 位);
//               本实现按任务要求叠加 ARCHIVE_EXTRACT_SECURE_NODOTDOT(0x40) +
//               ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS(0x10000)。"OVERWRITE" 在
//               libarchive 是缺省行为 (NO_OVERWRITE 0x100 是反位), 无独立标志位。
//         错误: TDRootfsUnpackErrorDomain code=ArchiveRead/EntryWrite。
//  [P2] 重签链路 — 参照 decomp_nyxian_app.c signROMFiles (flashROM 第 5 步)
//         输入: 解包树内待签 Mach-O 清单 + 现场签名身份 (BootSigningIdentity)
//         语义: NXSignMachOAuto -> NXClassifyMachO: filetype 2 (MH_EXECUTE) 走
//               LCUtils::signMachOAtURL_, filetype 6 (MH_DYLIB) 走 signMachOWithoutPatch_
//         输出: 就地重签, 失败中止安装
//         本仓: 收集 jbroot 内全部 Mach-O (thin/fat) 后一次
//               [ZSigner signMachOPathArr:...] 按宿主证书批量重签
//               (现有调用方式证据: LCUtils.m:234 signFilesWithZSignWithURLs);
//               无证书时回落 zsign_adhoc_file 逐文件 adhoc
//               (现有调用方式证据: MachoReSign.swift:44 + 工程桥接头 :89)。
//         错误: TDRootfsUnpackErrorDomain code=Sign。
//  [P3] symredirect 首次运行 — 参照 roothide/libroothide symredirect.cpp (MIT, 已
//       vendor 到 vendor/roothide/, 接口改造见该文件尾注)
//         输入: rootfs 内 Mach-O
//         语义: 把来自 /usr/lib、/System 的 vroot API 符号导入重绑到
//               @loader_path/.jbroot/usr/lib/libvrootapi.dylib (必要时追加 shim 库)
//         本仓: 先把内嵌 TDLibVrootApi.dylib 拷到 <jbroot>/usr/lib/libvrootapi.dylib,
//               逐文件 symredirect_process_file() (上游临时目录 /tmp 参数化为沙盒
//               NSTemporaryDirectory), 再对每个被改写二进制所在目录建
//               ".jbroot -> <jbroot根>" 相对符号链接 (@loader_path 约定)。
//               改写必然破坏旧签名, 因此与 P2 开关联用 (symredirect 后统一重签)。
//         错误: TDRootfsUnpackErrorDomain code=Symredirect (部分文件失败记入结果)。
//
//  沙盒收紧 (宿主要求): 解包目录树统一收紧到 0755 内 (setuid/setgid/sticky 清零,
//  组/其他可写位清零); rootfs 基目录 0700; 删除接口只接受 Documents/rootfs 下带
//  ".jbroot-" 名字的目录。移除上游对 /var/containers/Bundle/Application 的假定
//  (vendored jbroot.c 改造点 2) 后, jbroot 根可落在沙盒内任意可写位置。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 解包选项 (默认全关: 纯解包 = Tier A 可直接用的目录树).
typedef NS_OPTIONS(NSUInteger, TDRootfsUnpackOptions) {
    /// 解包后对 rootfs 内全部 Mach-O 按宿主身份重签 (无宿主证书回落 adhoc).
    TDRootfsUnpackOptionResignWithHostIdentity = 1 << 0,
    /// 解包后对 rootfs 内 Mach-O 跑 roothide symredirect (需配合重签).
    TDRootfsUnpackOptionSymredirect = 1 << 1,
};

FOUNDATION_EXPORT NSErrorDomain const TDRootfsUnpackErrorDomain;

typedef NS_ERROR_ENUM(TDRootfsUnpackErrorDomain, TDRootfsUnpackErrorCode) {
    /// 归档打不开 / 不支持 (内嵌 libarchive 错误串在 NSLocalizedFailureReasonErrorKey).
    TDRootfsUnpackErrorCodeArchiveRead = 1,
    /// 条目写出失败 (含 SECURE_* 拒绝: 绝对路径 / .. 穿越).
    TDRootfsUnpackErrorCodeEntryWrite = 2,
    /// .tar.zst / .zst 明确不支持 (iOS 无系统 libzstd, 本仓 SWCompression 无 zstd
    /// 解码器, Apple 系 libarchive 亦无 zstd filter) — 解包前置即拒.
    TDRootfsUnpackErrorCodeZstdUnsupported = 3,
    /// 重签失败 (ZSigner 批量调用 / adhoc 回落均失败).
    TDRootfsUnpackErrorCodeSign = 4,
    /// symredirect 失败 (shim 库缺失 / 改写错误).
    TDRootfsUnpackErrorCodeSymredirect = 5,
    /// 目标目录非法 (不在 Documents/rootfs 下 / 已存在 / 无法创建).
    TDRootfsUnpackErrorCodeDestination = 6,
};

/// 一次解包的结果 (全部计数只含本次操作).
@interface TDRootfsUnpackResult : NSObject
/// jbroot 根 (Documents/rootfs/.jbroot-<16hex>, 或调用方显式给的目标).
@property (nonatomic, readonly) NSURL *jbrootURL;
/// 该根的 brand (16 位大写 hex); jbrootURL 未带 .jbroot-<hex> 名字时为 nil.
@property (nonatomic, readonly, nullable) NSString *jbrootBrand;
/// 解包条目数 (archive_read_next_header 成功次数).
@property (nonatomic, readonly) NSUInteger entryCount;
/// 归档顶层归一化说明 ("opt/procursus 已上提" / "顶层 bootstrap/ 已剥壳" / nil).
@property (nonatomic, readonly, nullable) NSString *layoutNote;
/// 识别出的 Mach-O 数 (thin/fat, 不含符号链接).
@property (nonatomic, readonly) NSUInteger machoCount;
/// symredirect 改写成功数 (未启用该开关时为 0).
@property (nonatomic, readonly) NSUInteger symredirectedCount;
/// 交给 ZSigner 批量重签的路径数 (未启用该开关时为 0).
@property (nonatomic, readonly) NSUInteger resignedCount;
/// 非致命告警 (symredirect 跳过原因 / 个别文件改写失败等).
@property (nonatomic, readonly, copy, nullable) NSArray<NSString *> *warnings;
@end

@interface TDRootfsUnpack : NSObject

/// 解包归档到 per-guest 随机根 Documents/rootfs/.jbroot-<16hex> (destinationURL 为
/// nil 时), 并按 options 跑 symredirect / 重签. 阻塞调用 — 必须在后台队列使用.
+ (nullable TDRootfsUnpackResult *)unpackArchiveAtURL:(NSURL *)archiveURL
                                       destinationURL:(nullable NSURL *)destinationURL
                                              options:(TDRootfsUnpackOptions)options
                                                error:(NSError **)error;

/// 默认 rootfs 基目录: <NSHomeDirectory>/Documents/rootfs (与 LCPathBridge.rootfs 同点).
+ (NSURL *)rootfsBaseURL;

/// 删除一个随机 jbroot 根. 只接受 Documents/rootfs 下名字含 ".jbroot-" 的目录.
+ (BOOL)removeRootfsAtURL:(NSURL *)jbrootURL error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
