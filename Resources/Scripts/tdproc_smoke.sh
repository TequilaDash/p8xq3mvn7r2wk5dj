#!/usr/bin/env bash
# TDProcTable 单元冒烟 (Tier B-1): 登记/查询/列表 + JSON 持久化回环 +
# 真 kill(SIGKILL)/wait 语义 (fork 出真子进程作为被控对象, waitpid 取真实退出证据).
#
# 只能在 macOS 类 POSIX 宿主上跑 (Windows 无 fork/kill):
#   bash Resources/Scripts/tdproc_smoke.sh
# 环境隔离: 脚本把 LC_HOME_PATH 指到临时目录, 表文件落在 $TMP/Documents/TDSurface/,
# 不碰开发机真实 Documents.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/main.m" <<'EOF'
#import "TDProcTable.h"
#import <signal.h>
#import <stdio.h>
#import <sys/wait.h>
#import <unistd.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (cond) { printf("PASS %s\n", msg); } \
    else { printf("FAIL %s\n", msg); failures++; } \
} while (0)

int main(void) {
    // 1) 真子进程: 后续 kill/wait 的对象 (kill/waitpid 都是真实 syscall 证据).
    pid_t child = fork();
    if (child == 0) {
        for (;;) { pause(); }
    }
    CHECK(child > 0, "fork child");

    TDProcTable *table = [TDProcTable shared];
    NSError *err = nil;

    // 2) 登记: 宿主(extension) + 访客(visitor) 两条目, 同 pid 不同 kind.
    BOOL ok = [table registerPid:child
                            name:@"smoke-guest"
                        bundleId:@"com.smoke.guest"
                   containerUUID:@"UUID-1"
                            kind:TDProcKindHostExtension
                           error:&err];
    CHECK(ok, "register extension entry");
    ok = [table registerPid:child
                       name:@"smoke-guest"
                    bundleId:@"com.smoke.guest"
               containerUUID:@"UUID-1"
                        kind:TDProcKindGuestVisitor
                       error:&err];
    CHECK(ok, "register visitor entry");

    // 3) 查询/列表.
    TDProcEntry *e = [table lookupPid:child];
    CHECK(e != nil && e.state == TDProcStateRunning, "lookup returns running entry");
    CHECK([table listEntries].count >= 2, "list holds both kinds");

    // 4) JSON 持久化回环: 表文件存在且字段齐全 (崩溃后重建的数据源).
    NSString *path = [TDProcTable tableFilePath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    BOOL roundTrip = [json isKindOfClass:[NSDictionary class]] &&
        [json[@"entries"] isKindOfClass:[NSArray class]] &&
        [json[@"entries"] count] >= 2;
    CHECK(roundTrip, "json persistence round-trip");

    // 5) 真 kill: 表成员资格门内发 SIGKILL; waitpid 拿真退出状态.
    ok = [table killPid:child error:&err];
    CHECK(ok, "kill(SIGKILL) delivered via table");
    int status = 0;
    pid_t reaped = waitpid(child, &status, 0);
    CHECK(reaped == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL,
          "child death evidence: waitpid WIFSIGNALED+SIGKILL");

    // 6) wait: 轮询观察退出并落 state=exited.
    TDProcEntry *after = [table waitForPid:child timeout:3.0];
    CHECK(after != nil && after.state == TDProcStateExited, "wait marks exited");

    // 7) 表外 pid 拒杀 (越界护栏: 不在表内的 pid 一律 ESRCH).
    NSError *refuse = nil;
    ok = [table killPid:getpid() error:&refuse];
    CHECK(!ok && refuse.code == TDProcTableErrorNotRegistered,
          "kill outside table refused (NotRegistered)");

    // 8) 清理.
    [table removePid:child error:NULL];
    CHECK([table lookupPid:child] == nil, "remove clears entries");

    if (failures == 0) {
        printf("TDPROC SMOKE OK\n");
        return 0;
    }
    printf("TDPROC SMOKE FAILED (%d)\n", failures);
    return 1;
}
EOF

CLANG="clang"
if command -v xcrun >/dev/null 2>&1; then
    CLANG="xcrun clang"
fi

"$CLANG" -fobjc-arc -framework Foundation \
    -I "$ROOT/TequilaDash/Surface" \
    "$ROOT/TequilaDash/Surface/TDProcTable.m" "$TMP/main.m" \
    -o "$TMP/tdproc_smoke" || { echo "COMPILE FAIL"; exit 1; }

LC_HOME_PATH="$TMP" "$TMP/tdproc_smoke"
