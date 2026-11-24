//
//  LoadCommandScanGuard.h
//  iManager — zcontainer-test2 源码块
//
//  【问题】重打补丁时崩溃 / 找不到该找的命令。
//
//  【根因】上游 LCPatchExecSlice() 的 load command 扫描循环是
//
//      for (int i = 0; i < header->ncmds; i++) {
//          ... switch (command->cmd) ...
//          command = (struct load_command *)((void *)command + command->cmdsize);
//      }
//
//  它完全信任每条命令自己声明的 cmdsize，没有任何边界校验。
//  而旧版补丁逻辑恰恰会写坏邻居：LCPatchExecSlice 里对既有 0x114514 命令
//  无条件 strcpy 一个 43 字符的 tweakLoaderPath，而那条命令的名字字段可能
//  只有 24 字节（当初按 "/usr/lib/libc++.1.dylib" 分配的）—— 越界约 20 字节，
//  正好压到**下一条 load command 的 cmd / cmdsize 字段**上。
//
//  于是已经被旧版打过补丁的 app，磁盘上的二进制里就躺着一条 cmdsize 是脏值的
//  命令。新版要重打补丁（PatchRevision 门控放行）时，扫描循环走到那条命令就
//  按脏 cmdsize 跳转，跳到任意位置继续读结构体 —— 轻则找不到目标命令，
//  重则读到未映射页直接崩。
//
//  【本块】给每一步跳转加可证明的边界校验：
//    · cmdsize 至少能容纳一个 load_command 头；
//    · 当前偏移不越过 sizeofcmds；
//    · 本步不越过 sizeofcmds 末尾。
//  任一条不满足就停止扫描（返回 0），调用方按"没找到"处理 —— 走插入路径补一条
//  全新的、空间足够的命令，而不是在脏数据里乱跳。
//
//  【引用点】LiveContainer/LCMachOUtils.m 的 LCPatchExecSlice() 扫描循环
//      if (!iManagerLoadCommandStepIsSane(command->cmdsize, offset, header->sizeofcmds)) break;
//

#ifndef IMANAGER_LOAD_COMMAND_SCAN_GUARD_H
#define IMANAGER_LOAD_COMMAND_SCAN_GUARD_H

#include <stddef.h>
#include <stdint.h>
#include <mach-o/loader.h>

// 判断从 load command 区起始算起、偏移 offsetInCommands 处的一条命令，
// 其 cmdsize 是否可信到可以安全跳转。
//   cmdsize          : 该命令自己声明的 cmdsize
//   offsetInCommands : 该命令相对"第一条 load command"的字节偏移
//   sizeofcmds       : mach_header 里的 sizeofcmds（load command 区总长）
// 返回 1 = 可信；0 = 脏值，必须停止扫描。
static inline int iManagerLoadCommandStepIsSane(uint32_t cmdsize,
                                                size_t offsetInCommands,
                                                uint32_t sizeofcmds) {
    if (cmdsize < sizeof(struct load_command)) return 0;   // 连头都装不下
    if (offsetInCommands > (size_t)sizeofcmds) return 0;   // 已越出命令区
    if ((size_t)cmdsize > (size_t)sizeofcmds - offsetInCommands) return 0; // 本步越界
    return 1;
}

#endif /* IMANAGER_LOAD_COMMAND_SCAN_GUARD_H */
