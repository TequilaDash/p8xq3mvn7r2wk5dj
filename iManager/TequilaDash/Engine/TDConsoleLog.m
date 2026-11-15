#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <pthread.h>
#import <stdio.h>

/// 把 NSLog 的输出同时落到 `Documents/td-console.log`，供 SSH `cat td-console.log` 读取.
///
/// 为什么需要：SSH 的 `logs` 只读 LoginLogger；我们与上游的 NSLog 诊断（多任务/网络等）
/// 走的是统一日志，远程看不到。`_NSSetLogCStringFunction` 是 Foundation 的既有钩子，
/// 装上后 NSLog 会改走我们函数，这里再写回 stderr 以保持 Console.app 可见.
void TDConsoleLogInstall(void);

static FILE *gFile = NULL;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static char gPath[PATH_MAX];

static void td_log_write(const char *cstr, unsigned len, BOOL withTime) {
    pthread_mutex_lock(&gLock);
    if (!gFile && gPath[0]) {
        gFile = fopen(gPath, "a+");
        if (gFile) {
            fseek(gFile, 0, SEEK_END);
            long sz = ftell(gFile);
            if (sz > 2 * 1024 * 1024) {
                fclose(gFile);
                gFile = fopen(gPath, "w+");
            }
        }
    }
    if (gFile && cstr) {
        if (withTime) {
            time_t t = time(NULL);
            struct tm tmv;
            localtime_r(&t, &tmv);
            fprintf(gFile, "%02d:%02d:%02d ", tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
        }
        fwrite(cstr, 1, len, gFile);
        // NSLog 的 C 回调不保证带换行：不补的话整个文件是一行，SSH `cat` 里无法按行过滤.
        if (len == 0 || cstr[len - 1] != '\n') {
            fputc('\n', gFile);
        }
        fflush(gFile);
    }
    pthread_mutex_unlock(&gLock);
    // 仍写 stderr，Console.app 里照常可见.
    if (cstr) {
        fwrite(cstr, 1, len, stderr);
    }
}

void TDConsoleLogInstall(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (docs) {
        snprintf(gPath, sizeof(gPath), "%s/td-console.log", docs.fileSystemRepresentation);
    }

    // 安装时写一条分隔标记：旧版本可能把整份文件写成一行，标记能把历史与本次运行分开.
    if (gPath[0]) {
        FILE *f = fopen(gPath, "a+");
        if (f) {
            fprintf(f, "\n==== TDConsoleLog install ====\n");
            fflush(f);
            fclose(f);
        }
    }

    typedef void (*SetLogFn)(void (*)(const char *, unsigned, BOOL));
    SetLogFn setLog = (SetLogFn)dlsym(RTLD_DEFAULT, "_NSSetLogCStringFunction");
    if (setLog) {
        setLog(td_log_write);
    } else {
        fprintf(stderr, "[TDConsoleLog] _NSSetLogCStringFunction 不可用，仅记录手动调用\n");
    }
}