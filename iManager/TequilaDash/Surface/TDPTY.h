//
//  TDPTY.h
//  TequilaDash (Surface/Tier B-1: PTY 底座, Tier B-2 起点)
//
//  给访客 shell 一条真 tty 的 C 底座: 公开 API 的 posix_openpt 家族 + 私有
//  fileport 导出 (把 master fd 变成 mach send right, 供跨进程移交).
//  只暴露 C API, 不接 UI (owner Tier B-1 边界).
//
//  === Parity checklist (EPSL-1.1 上游只读思路, 未拷文本) ===
//  上游参照:
//    · Frameworks/LiveProcessLegacy/LowShim/LPLLSPTY.c (swirom 镜像, EPSL-1.1):
//      openpty → SYS_openpty 自定义 syscall → 宿主侧拿 fileport 回传访客.
//      输入: 无; 输出: master/slave fd 对; 错误: EMFILE/ENFILE/EINTR 透传.
//    · decomp_superslot.c: _tty_kill @0x60248 (对挂在 tty 上的 ksurface_proc 发信号,
//      :60270 → _proc_kill(proc, sig)) —— 证明上游 pty 语义 = "真 tty + 进程表联动".
//  本实现平价点:
//    · 取 tty: posix_openpt(O_RDWR|O_NOCTTY) + grantpt(EINTR 重试) + unlockpt +
//      ptsname —— 与上游 openpty 的等价公开 API 路径, 行为一致 (master fd + slave 名).
//    · 跨进程移交: fileport_makeport(fd)/fileport_makefd(port) —— 平价上游
//      SYS_openpty 的 fileport 产物 (宿主持 master, 访客经 mach port 接管).
//      B-2 接线: 扩展进程 open → export → mach msg 给宿主 → 宿主 import.
//  差异 (Inferred, 需真机复核):
//    · 上游走自家 syscall 服务器 + entitlement 门; 本实现零特权, 不建服务器.
//    · fileport_* 是 libsystem_kernel 私有导出 (iOS 10+/macOS 10.7+ 实机均存在),
//      以 weak_import 声明并在运行时判空 —— 符号缺失时返回 ENOSYS, 不闪退.
//
//  线程安全: 各函数无共享状态; 同一 master fd 的并发读写由调用方约束.
//

#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <stddef.h>

NS_ASSUME_NONNULL_BEGIN

/// 打开一对 pty.
/// 输入: 无.
/// 输出: 成功返回 master fd (>=0), 并把 slave 路径 (形如 /dev/ttysNNN) 写入
///       outSlavePath (NUL 结尾, 截断安全); 失败返回 -1, errno 保留
///       (EMFILE/ENFILE/EFTYPE/EACCES... 与 posix_openpt/grantpt 语义一致).
int TDPTYOpen(char *outSlavePath, size_t outSlavePathSize);

/// 把 master fd 导出为 mach fileport (send right).
/// 输入: master fd (TDPTYOpen 或合法 dup 的产物).
/// 输出: 成功 *outPort = fileport, 返回 0; 失败返回 -1, errno 保留
///       (EBADF/ENOSYS: fileport 符号缺失时即 ENOSYS).
/// 注意: 产出的 send right 由调用方 mach_port_deallocate.
int TDPTYExportFilePort(int masterFd, mach_port_t *outPort);

/// 在**本进程**内把 fileport 还原成 fd (宿主进程收口的入口).
/// 输入: TDPTYExportFilePort 产出的 fileport.
/// 输出: 成功返回新 fd (指向同一 pty master), 失败返回 -1, errno 保留.
int TDPTYImportFilePort(mach_port_t port);

/// 关闭 master fd (幂等安全: fd<0 直接返回).
void TDPTYClose(int masterFd);

NS_ASSUME_NONNULL_END
