#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 宿主 Documents/ConsoleLog 目录 (不存在时创建). 取不到宿主目录时返回 nil.
NSString * _Nullable TDConsoleLogDirectory(void);

/// 追加一行带时间戳的日志到 ConsoleLog/console-YYYYMMDD-pid<PID>.log。
/// 只用于低频启动面包屑, 不做 NSLog 全量劫持.
void TDConsoleLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// 捕获未处理异常与崩溃信号并写入 ConsoleLog, 不做任何弹窗.
void TDConsoleLogInstallCrashHandlers(void);

NS_ASSUME_NONNULL_END
