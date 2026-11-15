#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 宿主 Documents/ConsoleLog 目录 (不存在时创建). 取不到宿主目录时返回 nil.
NSString * _Nullable TDConsoleLogDirectory(void);

/// 追加一行带时间戳的日志到 ConsoleLog/console-YYYYMMDD.log.
/// 只用于低频启动面包屑, 不做 NSLog 全量劫持.
void TDConsoleLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// 安装未捕获异常与崩溃信号处理器 (SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGTRAP),
/// 把原因与回溯写进 ConsoleLog/crash-<时间戳>.log, 然后按原行为结束进程.
/// 可重复调用; 安装后会链式调用此前的 NSUncaughtExceptionHandler.
void TDConsoleLogInstallCrashHandlers(void);

NS_ASSUME_NONNULL_END
