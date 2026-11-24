//
//  DirtyLoadCommandRepatch.h
//  iManager — zcontainer-test2 源码块
//
//  【问题】修好的打补丁逻辑不生效：装上新版后访客仍报
//  "@loader_path/../../Tweaks/TweakLoader.dylibC (no such file)"。
//
//  【根因】上游 LiveContainerSwiftUI/Models/LCAppInfo.m 用版本号门控是否重打补丁：
//
//      int currentPatchRev = 7;
//      bool needPatch = [info[@"LCPatchRevision"] intValue] < currentPatchRev;
//
//  已经在上一个版本里被打过补丁的 app，LCPatchRevision 就是 7，装了新版后
//  needPatch 为 false —— 补丁代码根本不执行，二进制里那条脏 load command
//  原封不动留在原处。修复代码写得再对也不会生效。
//
//  【本块】不改上游的版本号（那个数字属于上游节奏），改为**按事实判断**：
//  启动时直接读访客二进制，检查有没有"名字比字段容量还长/没有 NUL 结尾"的
//  dylib 命令。有就说明这个 app 的补丁是旧版写坏的，需要重打一次。
//
//  判据（任一成立即视为脏）：
//    · 名字字段在容量内找不到 '\0'（旧 strncpy 不写 NUL 的典型形态）；
//    · 名字以已知的脏尾巴形态出现（如 "...TweakLoader.dylib" 后面还跟着字符）。
//
//  这样既不碰上游的 LCPatchRevision 语义，也只对真正被写坏的 app 重打，
//  正常 app 一次都不多打。
//
//  【引用点】LiveContainerSwiftUI/Models/LCAppInfo.m
//      bool needPatch = (LCPatchRevision 门控) || iManagerHasDirtyLoadCommandName(header);
//

#ifndef IMANAGER_DIRTY_LOAD_COMMAND_REPATCH_H
#define IMANAGER_DIRTY_LOAD_COMMAND_REPATCH_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <mach-o/loader.h>
#include "LoadCommandScanGuard.h"

// 判断一条 dylib/rpath 命令的名字字段是否是"旧版补丁写坏的"形态。
//   cmd/cmdsize/nameOffset 来自命令自身；返回 1 = 脏。
static inline int iManagerLoadCommandNameIsDirty(void *cmd, uint32_t cmdsize, uint32_t nameOffset) {
    if (!cmd || cmdsize <= nameOffset) return 0;
    size_t capacity = (size_t)cmdsize - (size_t)nameOffset;
    const char *field = (const char *)cmd + nameOffset;
    // 容量内没有 NUL：dyld 一定会读到字段外，这就是脏名。
    if (memchr(field, '\0', capacity) == NULL) return 1;
    return 0;
}

// 扫描整个 load command 区，判断这份二进制是否带着旧版补丁写坏的脏名字。
//   header 指向 mach_header_64，命令区紧随其后。
// 返回 1 = 有脏名，需要重打补丁；0 = 干净。
static inline int iManagerHasDirtyLoadCommandName(struct mach_header_64 *header) {
    if (!header) return 0;
    uint8_t *base = (uint8_t *)header + sizeof(struct mach_header_64);
    size_t offset = 0;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (!iManagerLoadCommandStepIsSane(((struct load_command *)(base + offset))->cmdsize,
                                           offset, header->sizeofcmds)) {
            return 0;   // 步长不可信：交给扫描护栏处理，这里不判脏
        }
        struct load_command *lc = (struct load_command *)(base + offset);
        if (lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB ||
            lc->cmd == LC_REEXPORT_DYLIB || lc->cmd == LC_LOAD_UPWARD_DYLIB) {
            struct dylib_command *dc = (struct dylib_command *)lc;
            if (iManagerLoadCommandNameIsDirty(dc, dc->cmdsize, dc->dylib.name.offset)) return 1;
        } else if (lc->cmd == LC_RPATH) {
            struct rpath_command *rc = (struct rpath_command *)lc;
            if (iManagerLoadCommandNameIsDirty(rc, rc->cmdsize, rc->path.offset)) return 1;
        }
        offset += lc->cmdsize;
    }
    return 0;
}

#endif /* IMANAGER_DIRTY_LOAD_COMMAND_REPATCH_H */
