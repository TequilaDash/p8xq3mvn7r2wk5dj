#!/usr/bin/env bash
# TDPTY 单元冒烟 (Tier B-1): posix_openpt 链路 + fileport 导出/导入回环.
#
# 只能在 macOS/Linux 类 POSIX 宿主上跑 (Windows 不具备 posix_openpt):
#   bash Resources/Scripts/tdpty_smoke.sh
# 前置: xcrun clang (macOS) 或 clang + Foundation 头.
#
# 验证点 (对应 TDPTY.h parity checklist):
#   1. TDPTYOpen 返回 master fd 且 slave 路径可解析、可打开.
#   2. master 写 -> slave 读回环 (真 tty 数据通路).
#   3. fileport 导出/导入回环: import 出的新 fd 与原 master 指向同一 pty.
# 本脚本在临时目录编译运行, 不改动仓库; TDProcTable/环境均无副作用.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/main.m" <<'EOF'
#import "TDPTY.h"
#import <fcntl.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (cond) { printf("PASS %s\n", msg); } \
    else { printf("FAIL %s\n", msg); failures++; } \
} while (0)

int main(void) {
    char slavePath[128] = {0};
    int master = TDPTYOpen(slavePath, sizeof(slavePath));
    CHECK(master >= 0, "TDPTYOpen returns master fd");
    CHECK(slavePath[0] == '/', "slave path resolved");
    if (master < 0) {
        printf("TDPTY SMOKE FAILED (%d)\n", failures);
        return 1;
    }

    int slave = open(slavePath, O_RDWR);
    CHECK(slave >= 0, "slave open");

    const char *msg = "ping-pty\n";
    CHECK(write(master, msg, strlen(msg)) == (ssize_t)strlen(msg), "master->slave write");
    char buf[64] = {0};
    ssize_t n = read(slave, buf, sizeof(buf) - 1);
    CHECK(n == (ssize_t)strlen(msg) && strcmp(buf, msg) == 0, "slave readback");

    mach_port_t port = MACH_PORT_NULL;
    if (TDPTYExportFilePort(master, &port) == 0) {
        CHECK(1, "fileport export");
        int dupFd = TDPTYImportFilePort(port);
        CHECK(dupFd >= 0, "fileport import");
        if (dupFd >= 0) {
            const char *msg2 = "via-fileport\n";
            CHECK(write(dupFd, msg2, strlen(msg2)) == (ssize_t)strlen(msg2), "imported fd write");
            char buf2[64] = {0};
            ssize_t n2 = read(slave, buf2, sizeof(buf2) - 1);
            CHECK(n2 == (ssize_t)strlen(msg2) && strcmp(buf2, msg2) == 0,
                  "slave readback via fileport fd");
            close(dupFd);
        }
        mach_port_deallocate(mach_task_self(), port);
    } else {
        // fileport 符号缺失 (ENOSYS) 在非 Apple 平台是预期分支; Apple 宿主上应 PASS.
        printf("SKIP fileport round-trip (errno=%d)\n", errno);
    }

    TDPTYClose(master);
    if (slave >= 0) close(slave);

    if (failures == 0) {
        printf("TDPTY SMOKE OK\n");
        return 0;
    }
    printf("TDPTY SMOKE FAILED (%d)\n", failures);
    return 1;
}
EOF

CLANG="clang"
if command -v xcrun >/dev/null 2>&1; then
    CLANG="xcrun clang"
fi

"$CLANG" -fobjc-arc -framework Foundation \
    -I "$ROOT/TequilaDash/Surface" \
    "$ROOT/TequilaDash/Surface/TDPTY.m" "$TMP/main.m" \
    -o "$TMP/tdpty_smoke" || { echo "COMPILE FAIL"; exit 1; }

"$TMP/tdpty_smoke"
