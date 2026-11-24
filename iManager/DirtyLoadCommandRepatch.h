//
//  DirtyLoadCommandRepatch.h
//  iManager — zcontainer-test2 源码块
//
//  【问题】修好的打补丁逻辑不生效：装上新版后访客仍报
//  "@loader_path/../../Tweaks/TweakLoader.dylibC (no such file)"。
//
//  【第一层】上游 LiveContainerSwiftUI/Models/LCAppInfo.m 用版本号门控：
//      int currentPatchRev = 7;
//      bool needPatch = [info[@"LCPatchRevision"] intValue] < currentPatchRev;
//  已装 app 的号已达 7 → 补丁不执行，脏名永远留着。本块按事实判断绕过门控。
//
//  【第二层 —— 判据必须命中真实形态，前两版都错在这里】
//
//  错误判据一：「名字字段里找不到 NUL 就算脏」。
//      cmdsize = 24 + rnd32(43+1, 8) = 24 + 48 = 72，名字字段容量 48 字节，
//      路径 43 字符。旧 strncpy 只写 43 字节，第 44 字节是残留（那个 "C"），
//      但第 45~48 字节本来就是 0 —— memchr 照样成功，脏名被判成干净。
//
//  错误判据二：「.dylib 后面还有字符就算脏」。
//      只查了 LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB / LC_REEXPORT_DYLIB /
//      LC_LOAD_UPWARD_DYLIB，**漏掉了注入命令自己的号 0x114514** ——
//      而脏名恰恰挂在这条命令上（注入被关掉时上游把 LC_LOAD_DYLIB 改写成
//      0x114514，名字字段照旧）。命令号不匹配，循环根本不看它。
//
//  【正确判据】按「已知注入路径前缀」比对，而不是猜后缀：
//      期望名 = "@loader_path/../../Tweaks/TweakLoader.dylib"（43 字符）
//      用 strnlen 取实际名字长度 n，再看
//        · n > 43           → 名字后面粘了东西（"…dylibC"）→ 脏
//        · n == 容量        → 整个字段没有 NUL，dyld 必读越界 → 脏
//      命令号必须包含 0x114514，这是旧线踩过的坑。
//
//  【引用点】LiveContainerSwiftUI/Models/LCAppInfo.m
//      needPatch = (LCPatchRevision 门控) || iManagerHasDirtyLoadCommandName(header)
//

#ifndef IMANAGER_DIRTY_LOAD_COMMAND_REPATCH_H
#define IMANAGER_DIRTY_LOAD_COMMAND_REPATCH_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <mach-o/loader.h>
#include "LoadCommandScanGuard.h"

// 上游注入的 tweak loader 依赖路径（与 LCMachOUtils.m 的 tweakLoaderPath 一致）。
#define IMANAGER_TWEAK_LOADER_PATH "@loader_path/../../Tweaks/TweakLoader.dylib"

// 判断一条 dylib 命令的名字是否被旧版补丁写坏。
//   dc : dylib 命令
// 返回 1 = 脏。
static inline int iManagerDylibCommandNameIsDirty(struct dylib_command *dc) {
    if (!dc) return 0;
    uint32_t offset = dc->dylib.name.offset;
    if (dc->cmdsize <= offset) return 0;

    const char *name = (const char *)dc + offset;
    size_t capacity = (size_t)dc->cmdsize - (size_t)offset;
    size_t length = strnlen(name, capacity);

    const size_t expected = sizeof(IMANAGER_TWEAK_LOADER_PATH) - 1;   // 43
    if (length < expected) return 0;                                  // 短于期望，不是这条
    if (strncmp(name, IMANAGER_TWEAK_LOADER_PATH, expected) != 0) return 0; // 前缀不符

    // 前缀匹配上了，说明这条命令本该正好是期望路径。两种情况判脏：
    //   · 比期望长 → 尾巴被粘了脏字节（真机形态 "…dylibC"）
    //   · 用满整个字段仍无 NUL → dyld 一定读越界
    if (length > expected) return 1;
    if (length == capacity) return 1;
    return 0;
}

// 扫描整个 load command 区，判断这份二进制是否带着旧版补丁写坏的脏名字。
// 返回 1 = 有脏名，需要重打补丁；0 = 干净。
static inline int iManagerHasDirtyLoadCommandName(struct mach_header_64 *header) {
    if (!header) return 0;
    uint8_t *base = (uint8_t *)header + sizeof(struct mach_header_64);
    size_t offset = 0;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *lc = (struct load_command *)(base + offset);
        if (!iManagerLoadCommandStepIsSane(lc->cmdsize, offset, header->sizeofcmds)) {
            return 0;   // 步长不可信：交给扫描护栏处理，这里不判脏
        }
        // 0x114514 是上游用来标记「注入被关掉」的伪 LC_LOAD_DYLIB 号，
        // 脏名恰恰挂在这条命令上，必须一起查。
        if (lc->cmd == LC_LOAD_DYLIB ||
            lc->cmd == LC_LOAD_WEAK_DYLIB ||
            lc->cmd == LC_REEXPORT_DYLIB ||
            lc->cmd == LC_LOAD_UPWARD_DYLIB ||
            lc->cmd == 0x114514) {
            if (iManagerDylibCommandNameIsDirty((struct dylib_command *)lc)) return 1;
        }
        offset += lc->cmdsize;
    }
    return 0;
}

#endif /* IMANAGER_DIRTY_LOAD_COMMAND_REPATCH_H */
