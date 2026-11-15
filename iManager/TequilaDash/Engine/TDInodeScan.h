//
//  TDInodeScan.h
//  TequilaDash
//
//  本仓适配 (worse_query 枚举重写): 对齐 WQFiles `WQAccess.m` 的生产级做法 ——
//  多线程 fsgetpath 全量扫 + 磁盘缓存 + 增量扫描 + 缓存条目复核。
//  上游 forcequit 的 pathleak 是单线程 O(probe)，在真机 inode 数千万级时
//  一次要几十秒，命中 0 直接回退 —— 这正是 0.3.874/876 目录枚举仍失败的根因。
//

#ifndef TDInodeScan_h
#define TDInodeScan_h

#import <Foundation/Foundation.h>

/// 枚举 `dir` 的一级子项（路径形式，/private/var/... 前缀）。
/// 返回 nil = 无法确定卷或探测失败（调用方回落扩展方案）。
/// outScanned/outProbe 可为 NULL；用于日志（扫描范围 / 当前 inode 探测值）。
NSArray<NSString *> *td_wq_enumerate(NSString *dir, int64_t *outScanned, int64_t *outProbe);

/// 当前缓存的扫描水位（探测 inode 值）；0 = 尚未扫过。
int64_t td_wq_cached_probe(void);

#endif /* TDInodeScan_h */