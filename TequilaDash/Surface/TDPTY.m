//
//  TDPTY.m
//  TequilaDash (Surface/Tier B-1: PTY 底座)
//
//  实现与 parity 依据见 TDPTY.h 头注 (对照 LiveProcessLegacy/LowShim/LPLLSPTY.c
//  的 openpty→fileport 语义, clean-room 重写).
//

#import "Surface/TDPTY.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

// libsystem_kernel 私有导出: fileport_makeport / fileport_makefd.
// weak_import + 运行时判空: 极旧/裁剪内核上退化为 ENOSYS, 不闪退.
extern int fileport_makeport(int fd, mach_port_t *out_port) __attribute__((weak_import));
extern int fileport_makefd(mach_port_t port) __attribute__((weak_import));

int TDPTYOpen(char *outSlavePath, size_t outSlavePathSize) {
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) {
        return -1;  // EMFILE/ENFILE/EAGAIN, errno 已就位
    }
    // grantpt 会被 SIGCHLD 打断 (EINTR), 重试到真失败为止.
    while (grantpt(master) != 0) {
        if (errno != EINTR) {
            int saved = errno;
            close(master);
            errno = saved;
            return -1;
        }
    }
    if (unlockpt(master) != 0) {
        int saved = errno;
        close(master);
        errno = saved;
        return -1;
    }
    char *slave = ptsname(master);
    if (!slave) {
        int saved = errno;
        close(master);
        errno = saved;
        return -1;
    }
    if (outSlavePath && outSlavePathSize > 0) {
        // 截断安全拷贝; 调用方给的缓冲区太小不算致命 (路径仍可从 ptsname 语义推断).
        strncpy(outSlavePath, slave, outSlavePathSize - 1);
        outSlavePath[outSlavePathSize - 1] = '\0';
    }
    return master;
}

int TDPTYExportFilePort(int masterFd, mach_port_t *outPort) {
    if (masterFd < 0 || !outPort) {
        errno = EINVAL;
        return -1;
    }
    if (fileport_makeport == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (fileport_makeport(masterFd, outPort) != 0) {
        return -1;  // errno 由内核侧就位 (EBADF / MIG 错误映射)
    }
    return 0;
}

int TDPTYImportFilePort(mach_port_t port) {
    if (port == MACH_PORT_NULL) {
        errno = EINVAL;
        return -1;
    }
    if (fileport_makefd == NULL) {
        errno = ENOSYS;
        return -1;
    }
    int fd = fileport_makefd(port);
    if (fd < 0) {
        return -1;
    }
    return fd;
}

void TDPTYClose(int masterFd) {
    if (masterFd >= 0) {
        close(masterFd);
    }
}
