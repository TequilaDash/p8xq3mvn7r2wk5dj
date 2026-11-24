//
//  MachONameFix.h
//  iManager — zcontainer-test2 源码块
//
//  【问题】dylibc 脏依赖名（TweakLoader.dylibC / no such file），访客起不来。
//
//  【根因】上游 getzeusapp/LiveContainer@zcontainer 的
//  LiveContainer/LCMachOUtils.m 三处写 load command 名字，三处都不安全：
//
//   1) insertDylibCommand() 的 else 分支（新增 LC_LOAD_DYLIB / 0x114514）
//        strncpy(dst, name, strlen(name));      // 不写 NUL
//      新命令落在 __TEXT 头部空洞里，那块内存不是零页；dyld 按 C 字符串读到
//      第一个 \0，于是把空洞里的残留字节读进依赖名。
//
//   2) insertRPathCommand()
//        strncpy(dst, path, strlen(path));      // 同样不写 NUL
//
//   3) LCPatchExecSlice() 里对既有 0x114514 命令的原地改写
//        strcpy(cmd + name.offset, tweakLoaderPath);   // 无条件写
//      **这是最容易复现 dylibc 的一处**：那条命令可能是按更短的
//      "/usr/lib/libc++.1.dylib"（21 字符，名字字段 24 字节）分配的，改写成
//      43 字符的 tweakLoaderPath 会越界约 20 字节，压坏紧邻的下一条 load
//      command 头；dyld 读被压坏的邻居，拼出来的依赖名就是
//      "TweakLoader.dylibC" 这种带脏尾巴的形态。
//      （旧线 Zcontainer 分支只在 1) 2) 补了 bzero，摸不到这里。）
//
//  【本块的三个入口】上游文件只调用，不写逻辑：
//     iManagerWriteLoadCommandName()      —— 新增命令：只清名字字段 + 有界拷贝 + 强制 NUL
//     iManagerSettleLoaderDylibCommand()  —— 既有命令：装得下才原地改写，装不下降级成无效号
//     iManagerStrncpyZ()                  —— 通用有界拷贝（上面两个的基础件）
//
//  【安全性】所有写入都被限制在本命令 cmdsize 之内；插入点沿用上游已有的
//  freeLoadCommandCountLeft >= cmdsize 空间检查，不改变上游策略。
//

#ifndef MACHO_NAME_FIX_H
#define MACHO_NAME_FIX_H

#include <string.h>
#include <stddef.h>
#include <stdint.h>
#include <mach-o/loader.h>

// 上游用来标记失效/重复命令的伪命令号（见 LCMachOUtils.m 的 dup 清理）。
#define IMANAGER_CMD_INVALID_DUP 0x114515

// 有界拷贝 + 强制 NUL 结尾。dstSize = 目标缓冲区可用字节数（含 NUL 位）。
// 最多写 dstSize-1 个字符，最后一字节恒为 '\0'。
static inline void iManagerStrncpyZ(void *dst, const char *src, size_t dstSize) {
    if (!dst || !src || dstSize == 0) return;
    size_t i = 0;
    for (; i + 1 < dstSize && src[i] != '\0'; i++) {
        ((char *)dst)[i] = src[i];
    }
    ((char *)dst)[i] = '\0';
}

// 往刚构造好的 load command 里写名字（新增命令路径）。
//   先只清"名字字段"这一段（不是整条命令，范围更小、可证明不越过 cmdsize），
//   再有界拷贝并强制 NUL —— dyld 读到的字符串不会再吸空洞里的残留字节。
static inline void iManagerWriteLoadCommandName(void *cmd, uint32_t cmdsize,
                                                uint32_t nameOffset, const char *name) {
    if (!cmd || !name || cmdsize <= nameOffset) return;
    size_t capacity = (size_t)cmdsize - (size_t)nameOffset;
    char *field = (char *)cmd + nameOffset;
    memset(field, 0, capacity);
    iManagerStrncpyZ(field, name, capacity);
}

// 定点改写一条已存在的 dylib 命令的名字，**装不下就绝不写**。
//   existing : 已存在的命令（通常是上次打补丁留下的 0x114514）
//   wantedCmd: 本次希望它变成的命令号（LC_LOAD_DYLIB 或 0x114514）
//   wantedPath: 希望写入的依赖路径
// 返回 1 = 原地改写完成（命令号也已设好）；
// 返回 0 = 名字字段装不下，**没有写入任何字节**，只把旧命令降级成
//          IMANAGER_CMD_INVALID_DUP，调用方应补插一条空间足够的新命令。
static inline int iManagerSettleLoaderDylibCommand(struct dylib_command *existing,
                                                   uint32_t wantedCmd,
                                                   const char *wantedPath) {
    if (!existing || !wantedPath) return 0;
    uint32_t cmdsize = existing->cmdsize;
    uint32_t nameOffset = existing->dylib.name.offset;
    if (cmdsize > nameOffset && strlen(wantedPath) + 1 <= (size_t)cmdsize - (size_t)nameOffset) {
        iManagerWriteLoadCommandName(existing, cmdsize, nameOffset, wantedPath);
        existing->cmd = wantedCmd;
        return 1;
    }
    // 装不下：不写、不越界。降级旧命令，让调用方走插入路径。
    existing->cmd = IMANAGER_CMD_INVALID_DUP;
    return 0;
}

#endif /* MACHO_NAME_FIX_H */
