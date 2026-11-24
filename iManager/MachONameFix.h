//
//  MachONameFix.h
//  iManager — zcontainer-test2 源码块
//
//  【问题】dylibc 脏依赖名（TweakLoader.dylibC / TweakLoader.dylib@ …），
//  dyld 报 "no such file" 后访客起不来。
//
//  【根因分析】上游 getzeusapp/LiveContainer@zcontainer 的
//  LiveContainer/LCMachOUtils.m 里有三处写 load command 名字，只有一处
//  保证 NUL 结尾、没有一处在"空间不够"时做保护：
//
//   1) insertDylibCommand() else 分支（新增 LC_LOAD_DYLIB / 0x114514）
//        strncpy(dst, name, strlen(name));   // 不写 NUL
//      新命令落在 __TEXT 头部空洞里，这块内存不是零页；dyld 按 C 字符串
//      读到第一个 \0 为止，于是把空洞里的残留字节读进依赖名。
//
//   2) insertRPathCommand()
//        strncpy(dst, path, strlen(path));   // 同样不写 NUL
//      rpath 落在同一个空洞，同样会吸残留字节。
//
//   3) LCPatchExecSlice() 里原地改写已存在的 0x114514 命令：
//        strcpy(cmd + name.offset, tweakLoaderPath);
//      **这是最危险的一处，也是最容易复现 dylibc 的一处**：那条命令原本
//      可能是按 "/usr/lib/libc++.1.dylib"（21 字符）分配的，名字字段只有
//      24 字节；改写成的 tweakLoaderPath 是 43 字符 + NUL = 44 字节，
//      strcpy 直接越界约 20 字节，压坏紧邻的下一条 load command 头。
//      被压坏的邻居若也是 dylib 命令，dyld 读它的 cmd / name.offset 就是
//      垃圾值，拼出来的依赖名正是 "TweakLoader.dylibC" 这类带脏尾巴的形态。
//      —— 旧线的 bzero 修法只覆盖了 1) 2) 两个插入点，摸不到这里。
//
//  【本块的修法】
//   - 写名字一律走"有界拷贝 + 强制 NUL"（iManagerStrncpyZ），不留空洞残留。
//   - 插入点只清"名字字段"这一段（不是整条命令），范围最小、可证明安全：
//     两个调用点都有 freeLoadCommandCountLeft >= cmdsize 的前置检查。
//   - 原地改写走 iManagerRewriteDylibCommandName()：先算可用空间，装不下
//     就**不写**，把那条命令降级成上游已在用的无效号 0x114515（dup 清理同款
//     处理），让正常插入路径另加一条全新的、空间足够的命令。
//     这样任何长度的路径都不会越界压坏邻居。
//
//  【依赖】仅 <string.h> / <stddef.h>，纯 C，无 UIKit/Foundation 依赖。
//
//  【引用点】LiveContainer/LCMachOUtils.m
//     - insertDylibCommand()          → iManagerZeroNameField + iManagerStrncpyZ
//     - insertRPathCommand()          → iManagerZeroNameField + iManagerStrncpyZ
//     - LCPatchExecSlice() 的 strcpy  → iManagerRewriteDylibCommandName
//

#ifndef MACHO_NAME_FIX_H
#define MACHO_NAME_FIX_H

#include <string.h>
#include <stddef.h>

// 上游用于标记"失效/重复"的伪命令号，原地改写放不下时沿用它。
#define IMANAGER_CMD_INVALID_DUP 0x114515

// 有界拷贝 + 强制 NUL 结尾。dstSize 为目标缓冲区可用字节数（含 NUL 位）。
// 最多写 dstSize-1 个字符，最后一个字节恒为 '\0'；dstSize 为 0 时不动。
static inline void iManagerStrncpyZ(void *dst, const char *src, size_t dstSize) {
    if (!dst || !src || dstSize == 0) return;
    size_t i = 0;
    for (; i + 1 < dstSize && src[i] != '\0'; i++) {
        ((char *)dst)[i] = src[i];
    }
    ((char *)dst)[i] = '\0';
}

// 只清 load command 的名字字段（dstSize 字节），不动结构体头与相邻命令。
// 目的：让名字里"字符串结束之后的字节"确定为零，dyld 不会读到空洞残留。
static inline void iManagerZeroNameField(void *nameField, size_t dstSize) {
    if (!nameField || dstSize == 0) return;
    memset(nameField, 0, dstSize);
}

// 原地改写一条 dylib/rpath 命令的名字，**装不下就不写**。
//   cmd        : 命令起始地址（struct dylib_command / struct rpath_command 均可）
//   cmdsize    : 该命令的 cmdsize
//   nameOffset : 名字字段相对命令起始的偏移（通常 sizeof(struct dylib_command)）
//   newName    : 新名字
// 返回 1 = 已写入且 NUL 结尾；返回 0 = 空间不足，调用方应放弃这条命令
// （上游做法：把它标记成 0x114515，让插入路径补一条新的）。
static inline int iManagerRewriteDylibCommandName(void *cmd, unsigned int cmdsize,
                                                  unsigned int nameOffset, const char *newName) {
    if (!cmd || !newName || cmdsize <= nameOffset) return 0;
    size_t capacity = (size_t)cmdsize - (size_t)nameOffset;
    size_t need = strlen(newName) + 1;
    if (need > capacity) return 0;              // 装不下：绝不越界
    char *field = (char *)cmd + nameOffset;
    iManagerZeroNameField(field, capacity);     // 先清，再写，双保险
    iManagerStrncpyZ(field, newName, capacity);
    return 1;
}

#endif /* MACHO_NAME_FIX_H */
