//
//  iManagerMachONameFix.h
//  iManager — zcontainer-test2 源码块
//
//  修复：dylibc 脏路径（TweakLoader.dylibC / TweakLoader.dylib@ 之类）
//
//  根因（上游 getzeusapp/LiveContainer@zcontainer d166a95d 的
//  LiveContainer/LCMachOUtils.m）：
//    insertDylibCommand() / insertRPathCommand() 用
//        strncpy(dst, name, strlen(name));
//    只拷贝 strlen(name) 字节，没有写结尾 NUL。cmdsize 虽然按
//    strlen+1 对齐 8 字节预留了空间，但那段空间是未清零的堆栈/堆残留，
//    dyld 读取 load command 里的字符串时按 C 字符串读到第一个 \0，
//    于是把紧邻的残留字节一并读进路径 —— 真机表现是访客加载
//    TweakLoader.dylibC / TweakLoader.dylib@（"no such file"）。
//    replaceDylinkerWithIDDylibCommand() 没有这个问题：它手动写了
//    `*((char*)... + nameSize - 1) = 0;`。
//
//  修法：strncpy 之后立刻补一个 NUL。两个调用点都要补。
//  该头文件只依赖 <string.h>/<stddef.h>，无任何 UIKit/Foundation 依赖，
//  编译进任何 target 都安全。
//
//  引用方式（LCMachOUtils.m 顶部）：
//    #import "iManager/MachONameFix/iManagerMachONameFix.h"
//  然后把两处 strncpy 的调用替换为：
//    iManagerStrncpyZ((void *)dylib + dylib->dylib.name.offset, name, cmdsize - dylib->dylib.name.offset);
//    iManagerStrncpyZ((void *)rpath + rpath->path.offset, path, rpath->cmdsize - rpath->path.offset);
//  （iManagerStrncpyZ 内部 = strncpy + 强制 NUL 结尾，永不越界。）
//

#ifndef IMANAGER_MACHO_NAME_FIX_H
#define IMANAGER_MACHO_NAME_FIX_H

#include <string.h>
#include <stddef.h>

// strncpy + 强制 NUL 结尾。dstSize 为目标缓冲区可用字节数（含 NUL 位）。
// 行为：最多拷贝 dstSize-1 字节，最后一位恒为 '\0'。
static inline void iManagerStrncpyZ(void *dst, const char *src, size_t dstSize) {
    if (!dst || !src || dstSize == 0) return;
    size_t i = 0;
    for (; i + 1 < dstSize && src[i] != '\0'; i++) {
        ((char *)dst)[i] = src[i];
    }
    ((char *)dst)[i] = '\0';
}

#endif /* IMANAGER_MACHO_NAME_FIX_H */
