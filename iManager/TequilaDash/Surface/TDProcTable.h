//
//  TDProcTable.h
//  TequilaDash (Surface/Tier B-1: Surface-lite 虚拟进程面)
//
//  轻量虚拟进程表 —— Nyxian ksurface_proc 的函数级平价重写 (clean-room).
//  只保留 pid/name/bundleId/container/state 的注册表语义, 不抄 radix tree /
//  rwlock / mach syscall 服务器 (22k 行 Surface 不引入, 计划 §4(b) Tier B 结论).
//
//  === Parity checklist (对照 EPSL-1.1 上游, 只读思路未拷文本) ===
//  上游参照 (decomp_superslot.c, Ghidra 12.2 导出):
//    · _proc_kill__impl @0x42d20  — 输入: proc 句柄 + 信号号(1..31, 越界=4 EINVAL,
//      未知句柄=0x38 ESRCH); 行为: PEProcessManager 按 pid 查回句柄后 sendSignal_.
//    · sendSignal_ 终点 = 真实信号 (SIGKILL=9 见 :64581/:64615, SIGTERM=0x14 见 :51852).
//    · _proc_reap @0x42e38 — 退出状态的回收发生在模拟进程树内部 (kvobject 引用计数),
//      非 waitpid 语义.
//    · 上游 kill 门 = 虚拟 entitlement org.emexlabs.nyxian.process.kill
//      (decomp_superslot.c:6207, 只被它自己的代码检查).
//  本实现平价点:
//    · kill: killPid: 只对**本表登记且 state=running** 的 pid 发 kill(pid, SIGKILL)
//      (真 syscall, 无假实现); 不在表内 => ESRCH (平价上游 0x38); 表外 pid 一律拒绝,
//      这是比上游虚拟 entitlement 更实的门 (见低成本改进: 表成员资格即越界护栏).
//    · wait: 扩展进程由系统 (FrontBoard) 拉起, 不是宿主 fork 的子进程, waitpid 必返回
//      ECHILD —— 故 wait = kill(pid, 0) 存活轮询 + 退出后落 state=exited (平价
//      _proc_reap 的"退出可见"语义, 放弃其进程树回收语义, 本表无进程树).
//    · register/lookup/list: 平价 ksurface_proc_t 内嵌字段的最小子集
//      (pid/name/entitlements→bundleId/containerUUID/state), 见
//      NYXIAN-INTEGRATION-PLAN.md §1 (上游 proc/def.h:34-90 结构摘要).
//  差异 (Inferred, 需真机复核):
//    · 上游拿 task port 走 exception handoff; 本表只做信号与存活观察, 不碰 task port.
//    · pid 重用检测依赖 sysctl(KERN_PROC_PID) 的 p_starttime 对账; 沙盒若拒该 sysctl
//      则退化为 kill(pid,0) 存活判断 (标记 Inferred).
//
//  持久化: <HOME|LC_HOME_PATH>/Documents/TDSurface/proc_table.json (原子替换 + flock),
//  宿主与扩展进程共用同一文件 (扩展经 LC_HOME_PATH 拿到宿主 Documents, 与访客容器同机制).
//  加载时对账 bootTime 与存活位, 崩溃/重启后可重建状态.
//
//  线程安全: 进程内 NSLock 串行 + 跨进程 flock 读-改-写.
//

#import <Foundation/Foundation.h>
#include <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

/// 条目状态. Swift: .running / .exited.
typedef NS_ENUM(NSInteger, TDProcState) {
    TDProcStateRunning = 0,
    TDProcStateExited  = 1,
};

/// 条目种类. Swift: .hostExtension / .guestVisitor.
///   HostExtension = NSExtension 拉起的 TequilaDashLiveProcess.appex 子进程本体;
///   GuestVisitor  = 扩展进程内 dlopen 进来的访客 app (与扩展同 pid, 生命周期一致).
typedef NS_ENUM(NSInteger, TDProcKind) {
    TDProcKindHostExtension = 0,
    TDProcKindGuestVisitor  = 1,
};

/// 单条虚拟进程记录 (只读快照; 变更走 TDProcTable 的写接口).
@interface TDProcEntry : NSObject

@property (nonatomic, readonly) pid_t pid;
/// 显示名: 扩展条目 = 访客目录名; 访客条目同.
@property (nonatomic, readonly, copy) NSString *name;
/// 访客 bundle id (宿主 userInfo 键 TequilaDashGuestBundleID), 可空串.
@property (nonatomic, readonly, copy) NSString *bundleId;
/// 访客容器 UUID (宿主 userInfo 键 TequilaDashContainerUUID), 可空串.
@property (nonatomic, readonly, copy) NSString *containerUUID;

@property (nonatomic, readonly) TDProcKind kind;
@property (nonatomic, readonly) TDProcState state;
/// 退出说明: "atexit: process exit" / "wait: exit observed" / "reconciled: ESRCH" /
/// "reboot" / "pid reused" / "SIGKILL delivered; exit observed in Nms" 等.
@property (nonatomic, readonly, copy) NSString *exitNote;

@property (nonatomic, readonly) NSTimeInterval registeredAt;  // epoch 秒
@property (nonatomic, readonly) NSTimeInterval exitedAt;      // 未退出为 0

@end

/// 错误域: TDProcTableErrorDomain; code 见 TDProcTableErrorCode.
typedef NS_ENUM(NSInteger, TDProcTableErrorCode) {
    TDProcTableErrorNotRegistered = 1,  // pid 不在表内或非 running (kill 门)
    TDProcTableErrorKillFailed    = 2,  // kill(2) 返回非 0, underlying = errno
    TDProcTableErrorIO            = 3,  // 表文件读写失败
    TDProcTableErrorInvalidArg    = 4,  // pid<=0 等参数错误
};

/// 虚拟进程表 (进程单例). 所有方法线程安全; 跨进程一致性由文件锁保证.
@interface TDProcTable : NSObject

/// 进程单例. Swift 侧按属性访问 (TDProcTable.shared, 不加括号).
@property (class, readonly) TDProcTable *shared;

/// 登记 (upsert, 以 pid+kind 为键): state=running, 记录 pid 起始时间用于 pid 重用检测.
/// 宿主在 spawn 成功回执后登记 HostExtension; 扩展进程 main.m 自登记并补 GuestVisitor.
/// 已存在同键 running 条目时合并字段 (先到的 registeredAt 保留); 同键 exited 条目复活.
/// bundleId/containerUUID 传 nil 时保留旧值 (仅更新 name).
- (BOOL)registerPid:(pid_t)pid
               name:(nullable NSString *)name
           bundleId:(nullable NSString *)bundleId
      containerUUID:(nullable NSString *)containerUUID
               kind:(TDProcKind)kind
              error:(NSError **)error;

/// 把该 pid 的全部条目 (extension 与 visitor 两条) 落 state=exited. note 可空.
- (BOOL)markExitedForPid:(pid_t)pid
                    note:(nullable NSString *)note
                   error:(NSError **)error;

/// 删除该 pid 的全部条目 (UI 清理已退出记录用).
- (BOOL)removePid:(pid_t)pid error:(NSError **)error;

/// 查单条 (pid 任一 kind 命中即返回; 无则 nil). 不触发对账.
- (nullable TDProcEntry *)lookupPid:(pid_t)pid;

/// 全表快照 (先做一次 reconcile, 再返回; running 在前, 同状态按 registeredAt 降序).
- (NSArray<TDProcEntry *> *)listEntries;

/// 真实 kill: 该 pid 在表内且 running 才发 kill(pid, SIGKILL) (真 syscall).
/// 成功后短轮询 (至多 2s) 观察退出并落 state=exited; 2s 后仍存活则保留 running
/// 并记 exitNote = "SIGKILL sent; still alive after poll".
- (BOOL)killPid:(pid_t)pid error:(NSError **)error;

/// 等待退出: 每 100ms kill(pid, 0) 轮询, 观察到 ESRCH 即落 state=exited 并返回快照;
/// 超时返回 nil (条目保持 running); 已是 exited 直接返回快照. timeout<=0 时只查一次.
- (nullable TDProcEntry *)waitForPid:(pid_t)pid timeout:(NSTimeInterval)timeout;

/// 对账: running 条目逐个 kill(pid,0) —— ESRCH 落 exited; EPERM 视为存活;
/// pid 重用 (p_starttime 对不上) 落 exited("pid reused"); bootTime 变化全体落 exited.
/// 再剪枝: exited 超过 7 天的条目删除. 加载即调, UI 刷新也调.
- (void)reconcile;

/// 表文件绝对路径 (诊断/冒烟脚本用; 不进访客环境变量).
+ (NSString *)tableFilePath;

@end

NS_ASSUME_NONNULL_END
