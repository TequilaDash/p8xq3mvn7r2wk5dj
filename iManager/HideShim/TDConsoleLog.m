#import "TDConsoleLog.h"

#include <execinfo.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

extern const char *TDHostHomeDocumentsPath(void);

// 日志必须落在宿主 App 与 LiveProcess 都能写的位置:
//   1) TD_CONSOLE_LOG_DIR (LCBootstrap 预先算好的 app group/ConsoleLog, 两个进程都可用)
//   2) LC_HOME_PATH/Documents/ConsoleLog (宿主 App 进程)
//   3) 捕获的宿主 Documents/ConsoleLog
static bool TDConsoleLogDirWritable(NSString *dir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]) {
        return NO;
    }
    NSString *probe = [dir stringByAppendingPathComponent:@".probe"];
    if (![[@"1" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:probe atomically:YES]) {
        return NO;
    }
    [fm removeItemAtPath:probe error:nil];
    return YES;
}

static NSString *TDConsoleLogBaseDocuments(void) {
    const char *home = getenv("LC_HOME_PATH");
    if (home && home[0] == '/') {
        return [NSString stringWithFormat:@"%s/Documents", home];
    }
    const char *docs = TDHostHomeDocumentsPath();
    return (docs && docs[0]) ? @(docs) : nil;
}

static NSUncaughtExceptionHandler *gTDPreviousExceptionHandler = NULL;
static pthread_mutex_t gTDLogLock = PTHREAD_MUTEX_INITIALIZER;

static NSString *TDLogTimestamp(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);
    return [NSString stringWithFormat:@"%04d-%02d-%02d %02d:%02d:%02d.%03d",
            tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
            tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000)];
}

NSString *TDConsoleLogDirectory(void) {
    static NSString *resolved = nil;
    static NSString *resolvedOverride = nil;
    static NSString *resolvedFallback = nil;
    static BOOL fallbackResolved = NO;
    const char *override = getenv("TD_CONSOLE_LOG_DIR");
    NSString *overridePath = (override && override[0] == '/') ? @(override) : nil;
    pthread_mutex_lock(&gTDLogLock);
    if (overridePath) {
        if (!resolvedOverride || ![resolvedOverride isEqualToString:overridePath]) {
            resolvedOverride = overridePath;
            resolved = nil;
        }
        if (!resolved && TDConsoleLogDirWritable(overridePath)) {
            resolved = overridePath;
        }
    }
    if (!resolved) {
        if (!fallbackResolved) {
            NSString *base = TDConsoleLogBaseDocuments();
            NSString *fallback = base ? [base stringByAppendingPathComponent:@"ConsoleLog"] : nil;
            if (fallback && TDConsoleLogDirWritable(fallback)) {
                resolvedFallback = fallback;
            }
            fallbackResolved = YES;
        }
        resolved = resolvedFallback;
    }
    NSString *result = resolved;
    pthread_mutex_unlock(&gTDLogLock);
    return result;
}

void TDConsoleLog(NSString *format, ...) {
    if (format.length == 0) return;
    static int tdLogWriteCount = 0;
    if (tdLogWriteCount >= 500) return;
    va_list ap;
    va_start(ap, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);

    NSString *dir = TDConsoleLogDirectory();
    if (!dir) return;
    NSDateFormatter *day = [[NSDateFormatter alloc] init];
    day.dateFormat = @"yyyyMMdd";
    // 宿主和各 LiveProcess 分文件追加, 进程内锁不承担跨进程的 seek/write 同步.
    // 旧 console-YYYYMMDD.log 保留, UI 仍按 .log 兼容读取.
    NSString *path = [dir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"console-%@-pid%d.log",
                       [day stringFromDate:[NSDate date]], (int)getpid()]];

    pthread_mutex_lock(&gTDLogLock);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", TDLogTimestamp(), message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (![fm fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
    } else {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            @try {
                [handle seekToEndOfFile];
                [handle writeData:data];
            } @catch (__unused NSException *e) {
            }
            [handle closeFile];
        }
    }
    pthread_mutex_unlock(&gTDLogLock);
}



#pragma mark - 崩溃记录 (只写文件, 不弹窗)

static void TDWriteSignalCrash(int sig) {
    char dir[PATH_MAX];
    const char *override = getenv("TD_CONSOLE_LOG_DIR");
    if (override && override[0] == '/') {
        snprintf(dir, sizeof(dir), "%s", override);
    } else {
        char docs[PATH_MAX];
        const char *lcHome = getenv("LC_HOME_PATH");
        if (lcHome && lcHome[0] == '/') {
            snprintf(docs, sizeof(docs), "%s/Documents", lcHome);
        } else {
            const char *captured = TDHostHomeDocumentsPath();
            if (!captured || !captured[0]) return;
            snprintf(docs, sizeof(docs), "%s", captured);
        }
        snprintf(dir, sizeof(dir), "%s/ConsoleLog", docs);
    }
    mkdir(dir, 0755);
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/crash-%04d%02d%02d-%02d%02d%02d-pid%d-sig%d.log",
             dir, tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
             tm.tm_hour, tm.tm_min, tm.tm_sec, (int)getpid(), sig);
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) return;
    char header[160];
    int n = snprintf(header, sizeof(header), "signal=%d pid=%d\n", sig, (int)getpid());
    if (n > 0) write(fd, header, (size_t)n);
    void *frames[128];
    int count = backtrace(frames, 128);
    backtrace_symbols_fd(frames, count, fd);
    close(fd);
}

static void TDSignalHandler(int sig) {
    TDWriteSignalCrash(sig);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void TDExceptionHandler(NSException *exception) {
    NSString *dir = TDConsoleLogDirectory();
    if (dir) {
        NSString *name = [NSString stringWithFormat:@"crash-%@-pid%d.log",
                          [[TDLogTimestamp() stringByReplacingOccurrencesOfString:@" " withString:@"-"]
                           stringByReplacingOccurrencesOfString:@":" withString:@""], (int)getpid()];
        NSArray<NSString *> *symbols = exception.callStackSymbols ?: @[];
        NSString *body = [NSString stringWithFormat:@"exception: %@\nreason: %@\n\n%@\n",
                          exception.name ?: @"(nil)", exception.reason ?: @"(nil)",
                          [symbols componentsJoinedByString:@"\n"]];
        [[body dataUsingEncoding:NSUTF8StringEncoding]
            writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES];
    }
    NSUncaughtExceptionHandler *previous = gTDPreviousExceptionHandler;
    if (previous && previous != TDExceptionHandler) {
        previous(exception);
    }
}

void TDConsoleLogInstallCrashHandlers(void) {
    static BOOL exceptionInstalled = NO;
    static BOOL signalsSaved = NO;
    static const int signals[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGTERM, SIGINT, SIGHUP};
    static struct sigaction previousActions[sizeof(signals) / sizeof(signals[0])];
    if (!exceptionInstalled) {
        exceptionInstalled = YES;
        gTDPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&TDExceptionHandler);
    }
    const char *signalsEnabled = getenv("TD_CONSOLE_SIGNALS");
    BOOL shouldInstallSignals = signalsEnabled && signalsEnabled[0] == '1';
    if (shouldInstallSignals) {
        if (!signalsSaved) {
            for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
                sigaction(signals[i], NULL, &previousActions[i]);
            }
            signalsSaved = YES;
        }
        struct sigaction action;
        memset(&action, 0, sizeof(action));
        action.sa_handler = TDSignalHandler;
        sigemptyset(&action.sa_mask);
        action.sa_flags = SA_NODEFER;
        for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
            sigaction(signals[i], &action, NULL);
        }
    } else if (signalsSaved) {
        for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
            sigaction(signals[i], &previousActions[i], NULL);
        }
    }
}
