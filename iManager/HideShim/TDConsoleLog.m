#import "TDConsoleLog.h"

#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
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
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *dirs = [NSMutableArray array];
        const char *override = getenv("TD_CONSOLE_LOG_DIR");
        if (override && override[0] == '/') {
            [dirs addObject:@(override)];
        }
        NSString *base = TDConsoleLogBaseDocuments();
        if (base) [dirs addObject:[base stringByAppendingPathComponent:@"ConsoleLog"]];
        for (NSString *dir in dirs) {
            if (TDConsoleLogDirWritable(dir)) {
                resolved = dir;
                break;
            }
        }
    });
    return resolved;
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

