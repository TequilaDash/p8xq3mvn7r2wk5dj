#import "TDConsoleLog.h"

#include <execinfo.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

extern const char *TDHostHomeDocumentsPath(void);

// 访客崩溃发生在 LiveProcess 里, 它的 HOME 是扩展容器; 真正的 app Documents
// 由 LC_HOME_PATH 传入. 两个进程必须写同一个目录, iManager 才看得到.
static NSString *TDConsoleLogBaseDocuments(void) {
    const char *home = getenv("LC_HOME_PATH");
    if (home && home[0] == '/') {
        return [NSString stringWithFormat:@"%s/Documents", home];
    }
    const char *docs = TDHostHomeDocumentsPath();
    return (docs && docs[0]) ? @(docs) : nil;
}

static pthread_mutex_t gTDLogLock = PTHREAD_MUTEX_INITIALIZER;
static NSUncaughtExceptionHandler *gTDPreviousExceptionHandler = NULL;

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
    NSString *base = TDConsoleLogBaseDocuments();
    if (!base) return nil;
    NSString *dir = [base stringByAppendingPathComponent:@"ConsoleLog"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return dir;
}

void TDConsoleLog(NSString *format, ...) {
    if (format.length == 0) return;
    va_list ap;
    va_start(ap, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);

    NSString *dir = TDConsoleLogDirectory();
    if (!dir) return;
    NSDateFormatter *day = [[NSDateFormatter alloc] init];
    day.dateFormat = @"yyyyMMdd";
    NSString *path = [dir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"console-%@.log", [day stringFromDate:[NSDate date]]]];

    pthread_mutex_lock(&gTDLogLock);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    if ([attrs[NSFileSize] unsignedLongLongValue] > 512 * 1024) {
        [fm removeItemAtPath:path error:nil];
    }
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

// 信号处理里只做异步信号安全的事: 直接 open/write, 不碰 NSString.
static void TDWriteSignalCrash(int sig) {
    char docs[PATH_MAX];
    const char *lcHome = getenv("LC_HOME_PATH");
    if (lcHome && lcHome[0] == '/') {
        snprintf(docs, sizeof(docs), "%s/Documents", lcHome);
    } else {
        const char *captured = TDHostHomeDocumentsPath();
        if (!captured || !captured[0]) return;
        snprintf(docs, sizeof(docs), "%s", captured);
    }
    char dir[PATH_MAX];
    snprintf(dir, sizeof(dir), "%s/ConsoleLog", docs);
    mkdir(dir, 0755);

    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/crash-%04d%02d%02d-%02d%02d%02d-sig%d.log",
             dir, tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
             tm.tm_hour, tm.tm_min, tm.tm_sec, sig);
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
        NSString *name = [NSString stringWithFormat:@"crash-%@.log",
                          [[TDLogTimestamp() stringByReplacingOccurrencesOfString:@" " withString:@"-"]
                           stringByReplacingOccurrencesOfString:@":" withString:@""]];
        NSArray<NSString *> *symbols = exception.callStackSymbols ?: @[];
        NSString *body = [NSString stringWithFormat:@"exception: %@\nreason: %@\n\n%@\n",
                          exception.name ?: @"(nil)",
                          exception.reason ?: @"(nil)",
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
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    gTDPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&TDExceptionHandler);

    const int signals[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP};
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = TDSignalHandler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESETHAND | SA_NODEFER;
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        sigaction(signals[i], &action, NULL);
    }
}
