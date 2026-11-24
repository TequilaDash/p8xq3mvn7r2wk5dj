//
//  DirtyLoadCommandRepatch.h
//  iManager — zcontainer-test2 源码块
//
//  【问题】修好的打补丁逻辑不生效：装上新版后访客仍报
//  "@loader_path/../../Tweaks/TweakLoader.dylibC (no such file)"。
//
//  【第一层根因】上游 LiveContainerSwiftUI/Models/LCAppInfo.m 用版本号门控：
//
//      int currentPatchRev = 7;
//      bool needPatch = [info[@"LCPatchRevision"] intValue] < currentPatchRev;
//
//  已装 app 的号已达 7 → 补丁不执行。本块按事实判断绕过门控。
//
//  【第二层根因 —— 判据必须精确，否则等于没判】
//  脏名的形态是"路径后面还粘着一个字符"，例如
//      "@loader_path/../../Tweaks/TweakLoader.dylib" + "C"
//  而命令的 cmdsize 是按 rnd32(strlen+1, 8) 对齐的：
//      sizeof(dylib_command)=24，strlen("…TweakLoader.dylib")=43
//      cmdsize = 24 + rnd32(44, 8) = 24 + 48 = 72
//      名字字段容量 = 72 - 24 = 48 字节
//  即容量比字符串多 5 字节。旧 strncpy 只写 43 字节、不写 NUL，第 44 字节是
//  空洞里的残留（就是那个 "C"），而第 45~48 字节很可能本来就是 0。
//
//  所以"字段里找不到 NUL 就算脏"是**错的判据** —— 第 45 字节的 0 会让
//  memchr 成功返回，脏名被判成干净，补丁永远不重打。
//
//  【正确判据】把名字当 C 字符串读出来，看 ".dylib" 之后还有没有字符：
//      "@loader_path/../../Tweaks/TweakLoader.dylib"    → 干净
//      "@loader_path/../../Tweaks/TweakLoader.dylibC"   → 脏（.dylib 后面有 C）
//  另外两种同样判脏：
//      · 整个字段里找不到 NUL（dyld 一定会读越界）；
//      · 名字以 ".dylib" 结尾但不是已知的注入路径（被越界写坏成别的形态）。
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

// 判断一个名字字段是否是"旧版补丁写坏的"形态。
//   cmd/cmdsize/nameOffset : 命令自身信息
// 返回 1 = 脏。
static inline int iManagerLoadCommandNameIsDirty(void *cmd, uint32_t cmdsize, uint32_t nameOffset) {
    if (!cmd || cmdsize <= nameOffset) return 0;
    size_t capacity = (size_t)cmdsize - (size_t)nameOffset;
    const char *field = (const char *)cmd + nameOffset;

    // 容量内没有 NUL：dyld 一定会读到字段外，无条件判脏。
    const char *nul = (const char *)memchr(field, '\0', capacity);
    if (nul == NULL) return 1;

    size_t length = (size_t)(nul - field);
    if (length == 0) return 0;                       // 空名字，不是我们的形态

    // 名字里出现 ".dylib"，但 ".dylib" 后面还有字符 → 尾巴被粘上了脏字节。
    // 这是真机现象 "@loader_path/../../Tweaks/TweakLoader.dylibC" 的形态。
    static const char suffix[] = ".dylib";
    const size_t suffixLength = sizeof(suffix) - 1;
    if (length > suffixLength) {
        // 找到最后一个 ".dylib" 出现位置（名字里通常只有一处）
        const char *lastSuffix = NULL;
        for (size_t i = 0; i + suffixLength <= length; i++) {
            if (memcmp(field + i, suffix, suffixLength) == 0) lastSuffix = field + i;
        }
        if (lastSuffix != NULL) {
            size_t afterSuffix = (size_t)((field + length) - (lastSuffix + suffixLength));
            if (afterSuffix != 0) return 1;          // ".dylib" 后面还有东西 → 脏
        }
    }

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
