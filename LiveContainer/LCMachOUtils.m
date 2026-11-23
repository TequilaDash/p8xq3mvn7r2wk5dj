@import Darwin;
@import Foundation;
@import MachO;
#import "../litehook/src/litehook.h"
#import "LCUtils.h"
#include "dyld_cache_format.h"

static uint32_t rnd32(uint32_t v, uint32_t r) {
    r--;
    return (v + r) & ~r;
}

struct dyld_all_image_infos *_alt_dyld_get_all_image_infos(void) {
    static struct dyld_all_image_infos *result;
    if (result) {
        return result;
    }
    struct task_dyld_info dyld_info;
    mach_vm_address_t image_infos;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t ret;
    ret = task_info(mach_task_self_,
                    TASK_DYLD_INFO,
                    (task_info_t)&dyld_info,
                    &count);
    if (ret != KERN_SUCCESS) {
        return NULL;
    }
    image_infos = dyld_info.all_image_info_addr;
    result = (struct dyld_all_image_infos *)image_infos;
    return result;
}

static uint32_t get_chained_fixups_seg_count(void *macho, struct linkedit_data_command *fixups) {
    printf("[*] Found DYLD_CHAINED_FIXUPS!\n");
    
    if (fixups->dataoff == 0 || fixups->datasize < sizeof(struct dyld_chained_fixups_header)) {
        printf("\t\t[!] Invalid chained fixups payload\n");
        return 0;
    }
    
    off_t fixups_offset = fixups->dataoff;
    struct dyld_chained_fixups_header *header = (struct dyld_chained_fixups_header *)(macho+fixups_offset);
    
    if (header->starts_offset == 0 || header->starts_offset + sizeof(struct dyld_chained_starts_in_image) > fixups->datasize) {
        printf("\t\t[!] No chained starts to patch\n");

        return 0;
    }
    
    off_t starts_offset = fixups_offset + header->starts_offset;
    uint32_t *seg_count = (uint32_t *)(macho+starts_offset);

    return *seg_count;
}


static void insertDylibCommand(uint32_t cmd, const char *path, struct mach_header_64 *header) {
    const char *name = cmd==LC_ID_DYLIB ? basename((char *)path) : path;
    struct dylib_command *dylib;
    size_t cmdsize = sizeof(struct dylib_command) + rnd32((uint32_t)strlen(name) + 1, 8);
    if (cmd == LC_ID_DYLIB) {
        // Make this the first load command on the list (like dylibify does), or some UE3 games may break
        dylib = (struct dylib_command *)(sizeof(struct mach_header_64) + (uintptr_t)header);
        memmove((void *)((uintptr_t)dylib + cmdsize), (void *)dylib, header->sizeofcmds);
        bzero(dylib, cmdsize);
    } else {
        dylib = (struct dylib_command *)(sizeof(struct mach_header_64) + (void *)header+header->sizeofcmds);
        // 新命令落在 __TEXT 头部的空洞里, 这块内存不是零页. 不清零的话
        // strncpy 不写 NUL, dyld 会把空洞里的残留字节读进依赖名 ——
        // 现场见到的 "@loader_path/../../Tweaks/TweakLoader.dylibC" 即此.
        bzero(dylib, cmdsize);
    }
    dylib->cmd = cmd;
    dylib->cmdsize = cmdsize;
    dylib->dylib.name.offset = sizeof(struct dylib_command);
    dylib->dylib.compatibility_version = 0x10000;
    dylib->dylib.current_version = 0x10000;
    dylib->dylib.timestamp = 2;
    strncpy((void *)dylib + dylib->dylib.name.offset, name, strlen(name));
    header->ncmds++;
    header->sizeofcmds += dylib->cmdsize;
}

static void replaceDylinkerWithIDDylibCommand(struct dylinker_command* dylinkerCommand, const char *path) {
    uint32_t size = dylinkerCommand->cmdsize;
    struct dylib_command* newDylibCommand = (struct dylib_command*)dylinkerCommand;
    newDylibCommand->cmd = LC_ID_DYLIB;

    newDylibCommand->dylib.name.offset = sizeof(struct dylib_command);
    newDylibCommand->dylib.compatibility_version = 0x10000;
    newDylibCommand->dylib.current_version = 0x10000;
    newDylibCommand->dylib.timestamp = 2;
    uint32_t nameSize = size - sizeof(struct dylib_command);
    // we only have 8 bytes to use
    const char* name = basename((char *)path);
    strncpy((void *)newDylibCommand + newDylibCommand->dylib.name.offset, name, nameSize);
    *((char *)newDylibCommand + newDylibCommand->dylib.name.offset + nameSize - 1) = 0;
}

static void insertRPathCommand(const char *path, struct mach_header_64 *header) {
    struct rpath_command *rpath = (struct rpath_command *)(sizeof(struct mach_header_64) + (void *)header+header->sizeofcmds);
    // 同 insertDylibCommand: 命令区在 __TEXT 头部空洞里, 先清零再写, 保证串以 NUL 结尾.
    bzero(rpath, sizeof(struct rpath_command) + rnd32((uint32_t)strlen(path) + 1, 8));
    rpath->cmd = LC_RPATH;
    rpath->cmdsize = sizeof(struct rpath_command) + rnd32((uint32_t)strlen(path) + 1, 8);
    rpath->path.offset = sizeof(struct rpath_command);
    strncpy((void *)rpath + rpath->path.offset, path, strlen(path));
    header->ncmds++;
    header->sizeofcmds += rpath->cmdsize;
}

void LCPatchAddRPath(const char *path, struct mach_header_64 *header) {
    insertRPathCommand("@executable_path/../../Tweaks", header);
    insertRPathCommand("@loader_path", header);
}

// 旧 tweak 常把 CydiaSubstrate 的依赖名写死成
// /Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate 或
// @executable_path/libsubstrate.dylib；这两条在 zContainer 沙盒里都不存在。
// 统一改写成 @rpath/CydiaSubstrate，并补一条指向 LC CydiaSubstrate.framework
// 的 LC_RPATH，签名前完成，运行时就能解析到 TweakLoader 已加载的实现。
bool LCRepairTweakDependencies(const char *path, const char *substrateFrameworkPath) {
    if (!path || !path[0] || !substrateFrameworkPath || !substrateFrameworkPath[0]) {
        return false;
    }
    char *rpath = strdup(substrateFrameworkPath);
    if (!rpath) return false;
    __block bool changed = false;
    LCParseMachO(path, false, ^(const char *slicePath, struct mach_header_64 *header, int fd, void *filePtr) {
        if (header->cputype != CPU_TYPE_ARM64) {
            return;
        }
        bool hasRPath = false;
        struct load_command *command = (struct load_command *)(header + 1);
        for (uint32_t i = 0; i < header->ncmds; i++) {
            if (command->cmdsize < sizeof(struct load_command)) {
                break;
            }
            if (command->cmd == LC_RPATH && command->cmdsize >= sizeof(struct rpath_command)) {
                struct rpath_command *rpathCommand = (struct rpath_command *)command;
                if (rpathCommand->path.offset < command->cmdsize) {
                    const char *existing = (const char *)command + rpathCommand->path.offset;
                    if (strncmp(existing, rpath, command->cmdsize - rpathCommand->path.offset) == 0) {
                        hasRPath = true;
                    }
                }
            }
            if (command->cmd == LC_LOAD_DYLIB || command->cmd == LC_LOAD_WEAK_DYLIB) {
                struct dylib_command *dylib = (struct dylib_command *)command;
                if (dylib->dylib.name.offset < command->cmdsize) {
                    char *name = (char *)command + dylib->dylib.name.offset;
                    size_t capacity = command->cmdsize - dylib->dylib.name.offset;
                    bool needsRepair = strstr(name, "CydiaSubstrate.framework/CydiaSubstrate") != NULL ||
                                       strstr(name, "libsubstrate.dylib") != NULL;
                    const char *replacement = "@rpath/CydiaSubstrate";
                    if (needsRepair && capacity > strlen(replacement)) {
                        bzero(name, capacity);
                        strncpy(name, replacement, capacity - 1);
                        changed = true;
                    }
                }
            }
            command = (struct load_command *)((char *)command + command->cmdsize);
        }
        if (!hasRPath) {
            uint32_t textOffset = 0;
            struct load_command *scan = (struct load_command *)(header + 1);
            for (uint32_t i = 0; i < header->ncmds; i++) {
                if (scan->cmd == LC_SEGMENT_64 && scan->cmdsize >= sizeof(struct segment_command_64)) {
                    struct segment_command_64 *segment = (struct segment_command_64 *)scan;
                    if (strcmp(segment->segname, "__TEXT") == 0) {
                        for (uint32_t j = 0; j < segment->nsects; j++) {
                            struct section_64 *section = (struct section_64 *)((char *)scan + sizeof(struct segment_command_64) + sizeof(struct section_64) * j);
                            if (strcmp(section->sectname, "__text") == 0) {
                                textOffset = section->offset;
                                break;
                            }
                        }
                    }
                }
                scan = (struct load_command *)((char *)scan + scan->cmdsize);
            }
            size_t commandSize = sizeof(struct rpath_command) + rnd32((uint32_t)strlen(rpath) + 1, 8);
            size_t freeSpace = textOffset > (off_t)header->sizeofcmds
                ? textOffset - sizeof(struct mach_header_64) - header->sizeofcmds : 0;
            if (freeSpace >= commandSize) {
                insertRPathCommand(rpath, header);
                changed = true;
            }
        }
    });
    free(rpath);
    return changed;
}

int LCPatchExecSlice(const char *path, struct mach_header_64 *header, bool doInject) {
    uint8_t *imageHeaderPtr = (uint8_t*)header + sizeof(struct mach_header_64);
    int ans = 0;
    // Literally convert an executable to a dylib
    if (header->magic == MH_MAGIC_64) {
        //assert(header->flags & MH_PIE);
        header->filetype = MH_DYLIB;
        header->flags |= MH_NO_REEXPORTED_DYLIBS;
        header->flags &= ~MH_PIE;
    }

    // Patch __PAGEZERO to map just a single zero page, fixing "out of address space"
    struct segment_command_64 *seg = (struct segment_command_64 *)imageHeaderPtr;
    assert(seg->cmd == LC_SEGMENT_64 || seg->cmd == LC_ID_DYLIB);
    if (seg->cmd == LC_SEGMENT_64 && seg->vmaddr == 0) {
        seg->vmaddr = 0x100000000 - 0x4000;
        seg->vmsize = 0x4000;
    }

    BOOL hasDylibCommand = NO;
    struct dylib_command * dylibLoaderCommand = 0;
    const char *tweakLoaderPath = "@loader_path/../../Tweaks/TweakLoader.dylib";
    const char *libCppPath = "/usr/lib/libc++.1.dylib";
    int textSectionOffest = 0;
    struct load_command *command = (struct load_command *)imageHeaderPtr;
    struct dylinker_command* dylinkerCommand = 0;
    bool codeSignatureCommandFound = false;
    uint32_t loadCommandSegCount = 0;
    for(int i = 0; i < header->ncmds; i++) {
        if(command->cmd == LC_ID_DYLIB) {
            hasDylibCommand = YES;
        } else if(command->cmd == LC_LOAD_DYLIB) {
            struct dylib_command *dylib = (struct dylib_command *)command;
            char *dylibName = (void *)dylib + dylib->dylib.name.offset;
            if (!strncmp(dylibName, tweakLoaderPath, strlen(tweakLoaderPath))) {
                dylibLoaderCommand = dylib;
            }
        } else if(command->cmd == 0x114514) {
            dylibLoaderCommand = (struct dylib_command *)command;
        } else if(command->cmd == LC_SEGMENT_64) {
            struct segment_command_64* seglc = (struct segment_command_64*)command;
            loadCommandSegCount++;
            if (strcmp("__TEXT", seglc->segname) == 0) {
                for (uint32_t j = 0; j < seglc->nsects; j++) {
                    struct section_64* sect = (struct section_64*)(((void*)command + sizeof(struct segment_command_64) + sizeof(struct section_64) * j));
                    if (0 == strcmp("__text", sect->sectname)) {
                        textSectionOffest = sect->offset;
                    }
                }
            }
        } else if (command->cmd == LC_CODE_SIGNATURE) {
            codeSignatureCommandFound = true;
        } else if (command->cmd == LC_LOAD_DYLINKER) {
            dylinkerCommand = (struct dylinker_command*)command;
        } else if (command->cmd == LC_DYLD_CHAINED_FIXUPS) {
            if(loadCommandSegCount != get_chained_fixups_seg_count((void*)header, (struct linkedit_data_command *)command)) {
                ans |= PATCH_EXEC_RESULT_SEG_COUNT_MISMATCH;
            }
        }
        
        command = (struct load_command *)((void *)command + command->cmdsize);
    }
    long freeLoadCommandCountLeft = (void*)header + textSectionOffest - (void*)command;
    int tweakLoaderLoadDylibCmdSize = 0x48;
    
    // Insert command priority: LC_CODE_SIGNATURE > LC_ID_DYLIB > LC_LOAD_DYLIB
    if(!codeSignatureCommandFound) {
        freeLoadCommandCountLeft -= 0x10;
    }
    
    int idDylibCommandSize = sizeof(struct dylib_command) + rnd32((uint32_t)strlen(basename((char*)path)) + 1, 8);
    if(!hasDylibCommand) {
        if (freeLoadCommandCountLeft >= idDylibCommandSize) {
            freeLoadCommandCountLeft -= idDylibCommandSize;
            insertDylibCommand(LC_ID_DYLIB, path, header);
            if (dylibLoaderCommand) {
                dylibLoaderCommand = (struct dylib_command *)((char *)dylibLoaderCommand + idDylibCommandSize);
            }
        } else if (dylinkerCommand) {
            // #1042 fix: if there's not enough space for LC_ID_DYLIB we resue LC_LOAD_DYLINKER's space for LC_ID_DYLIB
            replaceDylinkerWithIDDylibCommand(dylinkerCommand, path);
        }
    }

    if (dylibLoaderCommand) {
        const char *targetPath = doInject ? tweakLoaderPath : libCppPath;
        size_t nameOffset = dylibLoaderCommand->dylib.name.offset;
        size_t nameLength = strlen(targetPath) + 1;
        size_t oldSize = dylibLoaderCommand->cmdsize;
        size_t nameCapacity = oldSize > nameOffset ? oldSize - nameOffset : 0;
        if (nameOffset >= sizeof(struct dylib_command) && nameOffset <= oldSize && nameCapacity < nameLength) {
            // A disabled loader was stored with the shorter libc++ name. Grow
            // its command before re-enabling injection, never truncate a path.
            size_t newSize = rnd32((uint32_t)(nameOffset + nameLength), 8);
            size_t growth = newSize - oldSize;
            if (growth <= (size_t)MAX(freeLoadCommandCountLeft, 0)) {
                char *tail = (char *)dylibLoaderCommand + oldSize;
                char *end = (char *)(header + 1) + header->sizeofcmds;
                memmove(tail + growth, tail, (size_t)(end - tail));
                dylibLoaderCommand->cmdsize = (uint32_t)newSize;
                header->sizeofcmds += (uint32_t)growth;
                freeLoadCommandCountLeft -= growth;
                nameCapacity = newSize - nameOffset;
            }
        }
        if (nameOffset >= sizeof(struct dylib_command) && nameCapacity >= nameLength) {
            dylibLoaderCommand->cmd = doInject ? LC_LOAD_DYLIB : 0x114514;
            char *nameStorage = (char *)dylibLoaderCommand + nameOffset;
            bzero(nameStorage, nameCapacity);
            memcpy(nameStorage, targetPath, nameLength);
        } else {
            ans |= PATCH_EXEC_RESULT_NO_SPACE_FOR_TWEAKLOADER;
        }
    } else {
        if (freeLoadCommandCountLeft >= tweakLoaderLoadDylibCmdSize) {
            freeLoadCommandCountLeft -= tweakLoaderLoadDylibCmdSize;
            insertDylibCommand(doInject ? LC_LOAD_DYLIB : 0x114514, doInject ? tweakLoaderPath : libCppPath, header);
        } else {
            // Not enough free space of injection tweak loader!
            ans |= PATCH_EXEC_RESULT_NO_SPACE_FOR_TWEAKLOADER;
        }
    }
    
    // Ensure No duplicated dylibs, often caused by incorrect tweak injection
    // https://github.com/LiveContainer/LiveContainer/issues/582
    // https://github.com/apple-oss-distributions/dyld/blob/93bd81f9d7fcf004fcebcb66ec78983882b41e71/mach_o/Header.cpp#L678
    struct load_command *command2 = (struct load_command *)imageHeaderPtr;
    __block int   depCount = 0;
    const char**  depPaths = malloc(header->ncmds * sizeof(char*));
    for(int i = 0; i < header->ncmds; i++) {
        switch ( command2->cmd ) {
            case LC_LOAD_DYLIB:
            case LC_LOAD_WEAK_DYLIB:
            case LC_REEXPORT_DYLIB:
            case LC_LOAD_UPWARD_DYLIB: {
                char* loadPath =  (void *)command2 + ((struct dylib_command*)command2)->dylib.name.offset;
                for ( int i = 0; i < depCount; ++i ) {
                    if ( strcmp(loadPath, depPaths[i]) == 0 ) {
                        // replace this duplicated dylib command with an invalid command number
                        command2->cmd = 0x114515;
                        continue;
                    }
                }
                depPaths[depCount] = loadPath;
                ++depCount;
            }
        }
        command2 = (struct load_command *)((void *)command2 + command2->cmdsize);
    }
    free(depPaths);
    
    return ans;
}


// 旧版本往依赖名槽里写路径时没有终止符, 磁盘上留下
// "@loader_path/../../Tweaks/TweakLoader.dylibC" 这类脏名. 这类二进制不会因为
// 补丁版本号相同而被重新修补, 必须在加载前识别出来, 让调用方强制重打并重签.
bool LCMachOExecutableHasDirtyTweakLoader(const char *path) {
    static const char *tweakLoaderPath = "@loader_path/../../Tweaks/TweakLoader.dylib";
    const size_t prefixLen = strlen(tweakLoaderPath);
    __block bool dirty = false;
    LCParseMachO(path, true, ^(const char *slicePath, struct mach_header_64 *header, int fd, void *filePtr) {
        if (dirty || header->cputype != CPU_TYPE_ARM64) return;
        struct load_command *command = (struct load_command *)(header + 1);
        for (uint32_t i = 0; i < header->ncmds; i++) {
            if (command->cmdsize < sizeof(struct load_command)) break;
            if (command->cmd == LC_LOAD_DYLIB || command->cmd == LC_LOAD_WEAK_DYLIB ||
                command->cmd == 0x114514) {
                struct dylib_command *dylib = (struct dylib_command *)command;
                uint32_t offset = dylib->dylib.name.offset;
                if (command->cmdsize > offset) {
                    const char *name = (const char *)command + offset;
                    size_t capacity = command->cmdsize - offset;
                    size_t n = strnlen(name, capacity);
                    if (n >= prefixLen && strncmp(name, tweakLoaderPath, prefixLen) == 0) {
                        // 名字比预期长, 或整个槽里没有 NUL: dyld 会把后续字节读进依赖名.
                        if (n > prefixLen || n == capacity) {
                            dirty = true;
                        }
                    }
                }
            }
            command = (struct load_command *)((char *)command + command->cmdsize);
        }
    });
    return dirty;
}

// 去掉一条加载命令: 后面的命令前移, 并修正 ncmds/sizeofcmds. 头部空洞还在,
// 段的布局不受影响.
static void lc_remove_load_command(struct mach_header_64 *header, struct load_command *target) {
    uint32_t size = target->cmdsize;
    uint8_t *cmds = (uint8_t *)(header + 1);
    size_t offset = (size_t)((uint8_t *)target - cmds);
    if (offset + size > header->sizeofcmds) return;
    size_t tail = header->sizeofcmds - offset - size;
    memmove(target, (uint8_t *)target + size, tail);
    bzero((uint8_t *)target + tail, size);
    header->ncmds--;
    header->sizeofcmds -= size;
}

// 容器往访客主可执行里加的两条命令: LC_ID_DYLIB(用可执行文件名) 与
// TweakLoader 的 LC_LOAD_DYLIB. 发行版的可执行没有这两条.
static bool lc_is_container_added_command(const struct load_command *command, const char *execName) {
    if (command->cmd != LC_LOAD_DYLIB && command->cmd != LC_LOAD_WEAK_DYLIB &&
        command->cmd != LC_ID_DYLIB) {
        return false;
    }
    if (command->cmdsize < sizeof(struct dylib_command)) return false;
    const struct dylib_command *dylib = (const struct dylib_command *)command;
    if (dylib->dylib.name.offset >= command->cmdsize) return false;
    const char *name = (const char *)command + dylib->dylib.name.offset;
    static const char *tweakLoaderPath = "@loader_path/../../Tweaks/TweakLoader.dylib";
    if (command->cmd == LC_ID_DYLIB) {
        return execName && strcmp(name, execName) == 0;
    }
    return strncmp(name, tweakLoaderPath, strlen(tweakLoaderPath)) == 0;
}

bool LCCreateGuestExecutableReleaseView(const char *execPath) {
    if (!execPath || !execPath[0]) return false;
    NSString *exec = [NSString stringWithUTF8String:execPath];
    if (!exec.length) return false;
    NSString *view = [exec stringByAppendingString:@".td-original.executable"];
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:view]) {
        return true; // 安装时留存的原件, 或者上一次已经生成过
    }
    NSError *error = nil;
    if (![fm copyItemAtPath:exec toPath:view error:&error]) {
        NSLog(@"[LC] failed to keep a release view of %@ (%@)", exec.lastPathComponent,
              error.localizedDescription);
        return false;
    }
    NSString *execName = exec.lastPathComponent;
    __block bool removed = false;
    LCParseMachO(view.fileSystemRepresentation, false,
                 ^(const char *path, struct mach_header_64 *header, int fd, void *filePtr) {
        if (header->cputype != CPU_TYPE_ARM64) return;
        struct load_command *command = (struct load_command *)(header + 1);
        for (uint32_t i = 0; i < header->ncmds; i++) {
            if (command->cmdsize < sizeof(struct load_command)) break;
            if (lc_is_container_added_command(command, execName.fileSystemRepresentation)) {
                lc_remove_load_command(header, command);
                removed = true;
                continue; // 后面的命令已经移到这个位置
            }
            command = (struct load_command *)((char *)command + command->cmdsize);
        }
    });
    if (!removed) {
        [fm removeItemAtPath:view error:nil];
        return false;
    }
    NSLog(@"[LC] kept a release view of %@ at %@", exec.lastPathComponent, view.lastPathComponent);
    return true;
}

// iOS 27 的 code signing monitor 会把"已签名文件被就地改写的页"判成非法页,
// 进程直接 SIGKILL-CODESIGNING (Invalid Page)。所以任何对 Mach-O 的写改一律:
// MAP_PRIVATE 私有副本上打补丁 → 整文件写临时路径 → 原子 rename 替换,
// 全程不脏化原签名文件 (原 inode 对已运行的映射仍然有效)。
static NSString *LCPersistPatchedMachO(const char *path, void *map, size_t size, struct stat s) {
    char tmpPath[PATH_MAX];
    snprintf(tmpPath, sizeof(tmpPath), "%s.lcpatch-%d", path, getpid());
    int out = open(tmpPath, O_WRONLY | O_CREAT | O_TRUNC, (mode_t)(s.st_mode & 0777));
    if (out < 0) {
        return [NSString stringWithFormat:@"Failed to create %s: %s", tmpPath, strerror(errno)];
    }
    size_t off = 0;
    while (off < size) {
        ssize_t n = write(out, (char *)map + off, size - off);
        if (n <= 0) {
            close(out);
            unlink(tmpPath);
            return [NSString stringWithFormat:@"Failed to write %s: %s", tmpPath, strerror(errno)];
        }
        off += (size_t)n;
    }
    if (close(out) != 0) {
        unlink(tmpPath);
        return [NSString stringWithFormat:@"Failed to close %s: %s", tmpPath, strerror(errno)];
    }
    if (rename(tmpPath, path) != 0) {
        unlink(tmpPath);
        return [NSString stringWithFormat:@"Failed to replace %s: %s", path, strerror(errno)];
    }
    return nil;
}

NSString *LCParseMachO(const char *path, bool readOnly, LCParseMachOCallback callback) {
    int fd = open(path, readOnly ? O_RDONLY : O_RDWR, (mode_t)readOnly ? 0400 : 0600);
    if (fd < 0) {
        return [NSString stringWithFormat:@"Failed to map %s: %s", path, strerror(errno)];
    }
    struct stat s = {0};
    fstat(fd, &s);
    // 一律 MAP_PRIVATE: 写模式在私有副本上改, 落盘走 LCPersistPatchedMachO, 不再就地脏化签名文件。
    void *map = mmap(NULL, s.st_size, readOnly ? PROT_READ : (PROT_READ | PROT_WRITE), MAP_PRIVATE, fd, 0);
    if (map == MAP_FAILED) {
        NSString *error = [NSString stringWithFormat:@"Failed to map %s: %s", path, strerror(errno)];
        close(fd);
        return error;
    }

    uint32_t magic = *(uint32_t *)map;
    if (magic == FAT_CIGAM) {
        // Find compatible slice
        struct fat_header *header = (struct fat_header *)map;
        struct fat_arch *arch = (struct fat_arch *)(map + sizeof(struct fat_header));
        for (int i = 0; i < OSSwapInt32(header->nfat_arch); i++) {
            int cputype = OSSwapInt32(arch->cputype);
            if (cputype == CPU_TYPE_ARM64 || cputype == CPU_TYPE_ARM) {
                callback(path, (struct mach_header_64 *)(map + OSSwapInt32(arch->offset)), fd, map);
            }
            arch = (struct fat_arch *)((void *)arch + sizeof(struct fat_arch));
        }
    } else if (magic == MH_MAGIC_64 || magic == MH_MAGIC) {
        callback(path, (struct mach_header_64 *)map, fd, map);
    } else {
        munmap(map, s.st_size);
        close(fd);
        return @"Not a Mach-O file";
    }

    if (!readOnly) {
        NSString *persistError = LCPersistPatchedMachO(path, map, (size_t)s.st_size, s);
        munmap(map, s.st_size);
        close(fd);
        return persistError;
    }
    munmap(map, s.st_size);
    close(fd);
    return nil;
}

NSString *LCPatchMachOFixupARM64eSlice(const char *path) {
    int fd = open(path, O_RDWR, 0600);
    if(fd < 0) {
        return [NSString stringWithFormat:@"Failed to open %s: %s", path, strerror(errno)];
    }
    struct stat s = {0};
    fstat(fd, &s);
    void *map = mmap(NULL, s.st_size, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
    if(map == MAP_FAILED) {
        close(fd);
        return [NSString stringWithFormat:@"Failed to map %s: %s", path, strerror(errno)];
    }

    uint32_t magic = *(uint32_t *)map;
    if(magic == FAT_CIGAM) {
        // Find arm64e slice without CPU_SUBTYPE_LIB64
        struct fat_header *header = (struct fat_header *)map;
        struct fat_arch *arch = (struct fat_arch *)(map + sizeof(struct fat_header));
        for(int i = 0; i < OSSwapInt32(header->nfat_arch); i++) {
            if(OSSwapInt32(arch->cputype) == CPU_TYPE_ARM64 && OSSwapInt32(arch->cpusubtype) == CPU_SUBTYPE_ARM64E) {
                struct mach_header_64 *header = (struct mach_header_64 *)(map + OSSwapInt32(arch->offset));
                header->cpusubtype |= CPU_SUBTYPE_LIB64;
                arch->cpusubtype = htonl(header->cpusubtype);
                break;
            }
            arch = (struct fat_arch *)((void *)arch + sizeof(struct fat_arch));
        }
    }

    NSString *persistError = LCPersistPatchedMachO(path, map, (size_t)s.st_size, s);
    munmap(map, s.st_size);
    close(fd);
    return persistError;
}

void LCPatchAppBundleFixupARM64eSlice(NSURL *bundleURL) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:bundleURL includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    for (NSURL *fileURL in enumerator) {
        if ([fileURL.pathExtension isEqualToString:@"dylib"]) {
            LCPatchMachOFixupARM64eSlice(fileURL.path.fileSystemRepresentation);
        } else if ([fileURL.pathExtension isEqualToString:@"framework"]) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[fileURL URLByAppendingPathComponent:@"Info.plist"]];
            NSString *executableName = info[@"CFBundleExecutable"];
            if(!executableName) {
                executableName = fileURL.lastPathComponent.stringByDeletingPathExtension;
            }
            // Patching opens whatever path the name leads to, so skip a framework
            // whose executable isn't one file right inside it
            if(![executableName isKindOfClass:NSString.class] || executableName.length == 0 ||
               [executableName isEqualToString:@"."] || [executableName isEqualToString:@".."] ||
               [executableName containsString:@"/"] ||
               [executableName rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0, 1)]].location != NSNotFound) {
                continue;
            }
            NSURL *executableURL = [fileURL URLByAppendingPathComponent:executableName];
            LCPatchMachOFixupARM64eSlice(executableURL.path.fileSystemRepresentation);
        }
    }
}

void LCChangeMachOUUID(struct mach_header_64 *header) {
    struct load_command *command = (struct load_command *)(header + 1);
    for(int i = 0; i < header->ncmds; i++) {
        if(command->cmd == LC_UUID) {
            struct uuid_command *uuidCmd = (struct uuid_command *)command;
            // let's add the first byte by 1
            uuidCmd->uuid[0] += 1;
            break;
        }
        command = (struct load_command *)((void *)command + command->cmdsize);
    }
}

const uint8_t* LCGetMachOUUID(struct mach_header_64 *header) {
    if (!header) return NULL;
    if(*(uint32_t*)header != 0x646c7964) { // dyld
        // Find load commands
        const struct load_command* command = (const struct load_command*)(header + 1);
        
        // Iterate through load commands to find LC_SYMTAB
        for(uint32_t i = 0; i < header->ncmds; i++) {
            if(command->cmd == LC_UUID) {
                return ((const struct uuid_command*)command)->uuid;
            }
            command = (const struct load_command*)((void *)command + command->cmdsize);
        }
        return NULL;
    } else {
        struct dyld_cache_header* dsc_header = (struct dyld_cache_header*)header;
        return dsc_header->uuid;
    }
}

bool LCIsMachOEncrypted(struct mach_header_64 *header) {
    size_t size = header->cputype==CPU_TYPE_ARM64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header);
    struct load_command *command = (struct load_command *)((uint64_t)header + size);
    for(int i = 0; i < header->ncmds; i++) {
        if(command->cmd == LC_ENCRYPTION_INFO || command->cmd == LC_ENCRYPTION_INFO_64) {
            return ((struct encryption_info_command *)command)->cryptid != 0;
        }
        command = (struct load_command *)((void *)command + command->cmdsize);
    }
    return NO;
}

uint64_t LCFindSymbolOffset(const char *basePath, const char *symbol) {
#if !TARGET_OS_SIMULATOR
    const char *path = basePath;
#else
    char path[PATH_MAX];
    const char *rootPath = getenv("DYLD_ROOT_PATH") ?: "";
    snprintf(path, sizeof(path), "%s%s", rootPath, basePath);
#endif
    __block uint64_t offset = 0;
    LCParseMachO(path, true, ^(const char *path, struct mach_header_64 *header, int fd, void *filePtr) {
        if(header->cputype != CPU_TYPE_ARM64) return;
        void *result = litehook_find_symbol_file(header, symbol);
        if(result) {
            offset = (uint64_t)result - (uint64_t)header;
        }
    });
    NSCAssert(offset != 0, @"Failed to find symbol %s in %s", symbol, path);
    return offset;
}

struct mach_header_64 *LCGetLoadedImageHeader(int i0, const char* name) {
    for(uint32_t i = i0; i < _dyld_image_count(); ++i) {
        const char* imgName = _dyld_get_image_name(i);
        // cover simulator path aswell
        if(imgName && strcmp(imgName + (strlen(imgName) - strlen(name)), name) == 0) {
            return (struct mach_header_64*)_dyld_get_image_header(i);
        }
    }
    return NULL;
}

#if TARGET_OS_SIMULATOR
// Make it init first on simulator to find dyld_sim
__attribute__((constructor))
#endif
void *getDyldBase(void) {
    static void *dyldBase = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dyldBase = (void *)_alt_dyld_get_all_image_infos()->dyldImageLoadAddress;
    });
#if !TARGET_OS_SIMULATOR
    return dyldBase;
#else
    static void *dyldSimBase = NULL;
    if(!dyldSimBase) {
        __block size_t textSize = 0;
        LCParseMachO("/usr/lib/dyld", true, ^(const char *path, struct mach_header_64 *header, int fd, void *filePtr) {
            if(header->cputype != CPU_TYPE_ARM64) return;
            getsegmentdata(header, SEG_TEXT, &textSize);
        });
        NSArray *callStack = [NSThread callStackReturnAddresses];
        for(NSNumber *addr in callStack.reverseObjectEnumerator) {
            // the first addresss outside of dyld's text is dyld_sim
            uintptr_t addrValue = addr.unsignedLongLongValue;
            if(addrValue < (uintptr_t)dyldBase || addrValue >= (uintptr_t)dyldBase + textSize) {
                dyldSimBase = (void *)(addrValue & ~PAGE_MASK);
                while (((mach_header_u *)dyldSimBase)->magic != MH_MAGIC_64) {
                    dyldSimBase -= PAGE_SIZE;
                }
                break;
            }
        }
    }
    return dyldSimBase;
#endif
}

struct code_signature_command {
    uint32_t    cmd;
    uint32_t    cmdsize;
    uint32_t    dataoff;
    uint32_t    datasize;
};

// from zsign
struct ui_CS_BlobIndex {
    uint32_t type;                    /* type of entry */
    uint32_t offset;                /* offset of entry */
};

struct ui_CS_SuperBlob {
    uint32_t magic;                    /* magic number */
    uint32_t length;                /* total length of SuperBlob */
    uint32_t count;                    /* number of index entries following */
    //CS_BlobIndex index[];            /* (count) entries */
    /* followed by Blobs in no particular order as indicated by offsets in index */
};

struct ui_CS_blob {
    uint32_t magic;
    uint32_t length;
};


struct code_signature_command* findSignatureCommand(struct mach_header_64* header) {
    uint8_t *imageHeaderPtr = (uint8_t*)header + sizeof(struct mach_header_64);
    struct load_command *command = (struct load_command *)imageHeaderPtr;
    struct code_signature_command* codeSignCommand = 0;
    for(int i = 0; i < header->ncmds; i++) {
        if(command->cmd == LC_CODE_SIGNATURE) {
            codeSignCommand = (struct code_signature_command*)command;
            break;
        }
        command = (struct load_command *)((void *)command + command->cmdsize);
    }
    return codeSignCommand;
}

NSString* getEntitlementXML(struct mach_header_64* header, void** entitlementXMLPtrOut) {
    struct code_signature_command* codeSignCommand = findSignatureCommand(header);

    if(!codeSignCommand) {
        return @"Unable to find LC_CODE_SIGNATURE command.";
    }
    struct ui_CS_SuperBlob* blob = (void*)header + codeSignCommand->dataoff;
    if(blob->magic != OSSwapInt32(0xfade0cc0)) {
        return [NSString stringWithFormat:@"CodeSign blob magic mismatch %8x.", blob->magic];
    }
    struct ui_CS_BlobIndex* entitlementBlobIndex = 0;
    struct ui_CS_BlobIndex* nowIndex = (void*)blob + sizeof(struct ui_CS_SuperBlob);
    for(int i = 0; i < OSSwapInt32(blob->count); i++) {
        if(OSSwapInt32(nowIndex->type) == 5) {
            entitlementBlobIndex = nowIndex;
            break;
        }
        nowIndex = (void*)nowIndex + sizeof(struct ui_CS_BlobIndex);
    }
    if(entitlementBlobIndex == 0) {
        return @"[LC] entitlement blob index not found.";
    }
    struct ui_CS_blob* entitlementBlob = (void*)blob + OSSwapInt32(entitlementBlobIndex->offset);
    if(entitlementBlob->magic != OSSwapInt32(0xfade7171)) {
        return [NSString stringWithFormat:@"EntitlementBlob magic mismatch %8x.", blob->magic];
    };
    int32_t xmlLength = OSSwapInt32(entitlementBlob->length) - sizeof(struct ui_CS_blob);
    void* xmlPtr = (void*)entitlementBlob + sizeof(struct ui_CS_blob);
    
    if(entitlementXMLPtrOut) {
        *entitlementXMLPtrOut = xmlPtr;
    }

    // entitlement xml in executable don't have \0 so we have to copy it first
    char* xmlString = malloc(xmlLength + 1);
    memcpy(xmlString, xmlPtr, xmlLength);
    xmlString[xmlLength] = 0;

    NSString* ans = [NSString stringWithUTF8String:xmlString];
    free(xmlString);
    return ans;
}

static bool TDReadAt(int fd, void *buffer, size_t length, off_t offset) {
    uint8_t *bytes = (uint8_t *)buffer;
    size_t done = 0;
    while (done < length) {
        ssize_t got = pread(fd, bytes + done, length - done, offset + (off_t)done);
        if (got <= 0) return false;
        done += (size_t)got;
    }
    return true;
}

// Reads only the Mach-O header and load commands into heap memory. Mapping a
// tweak that is not signed yet makes iOS 27 validate the page on
// fault and kill the process (SIGKILL - CODESIGNING); pread has no such
// side effect, while fcntl still checks the signature against the real file.
static bool TDSafeCheckCodeSignature(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(uint32_t)) {
        close(fd);
        return false;
    }

    uint32_t magic = 0;
    off_t sliceOffset = 0;
    off_t sliceSize = st.st_size;
    if (!TDReadAt(fd, &magic, sizeof(magic), 0)) {
        close(fd);
        return false;
    }
    if (magic == FAT_CIGAM) {
        struct fat_header fat;
        if (!TDReadAt(fd, &fat, sizeof(fat), 0)) {
            close(fd);
            return false;
        }
        uint32_t count = OSSwapInt32(fat.nfat_arch);
        bool found = false;
        for (uint32_t i = 0; i < count; i++) {
            struct fat_arch arch;
            off_t at = (off_t)sizeof(fat) + (off_t)i * (off_t)sizeof(arch);
            if (!TDReadAt(fd, &arch, sizeof(arch), at)) break;
            if (OSSwapInt32(arch.cputype) != CPU_TYPE_ARM64) continue;
            sliceOffset = (off_t)OSSwapInt32(arch.offset);
            sliceSize = (off_t)OSSwapInt32(arch.size);
            found = sliceOffset >= 0 && sliceSize > (off_t)sizeof(struct mach_header_64) &&
                    sliceOffset + sliceSize <= st.st_size;
            break;
        }
        if (!found) {
            close(fd);
            return false;
        }
        if (!TDReadAt(fd, &magic, sizeof(magic), sliceOffset)) {
            close(fd);
            return false;
        }
    }
    if (magic != MH_MAGIC_64) {
        close(fd);
        return false;
    }

    struct mach_header_64 header;
    if (!TDReadAt(fd, &header, sizeof(header), sliceOffset) ||
        header.cputype != CPU_TYPE_ARM64 || header.ncmds == 0 ||
        header.sizeofcmds < sizeof(struct load_command) ||
        header.sizeofcmds > (uint32_t)(sliceSize - (off_t)sizeof(header))) {
        close(fd);
        return false;
    }

    void *commands = malloc(header.sizeofcmds);
    if (!commands || !TDReadAt(fd, commands, header.sizeofcmds,
                               sliceOffset + (off_t)sizeof(header))) {
        free(commands);
        close(fd);
        return false;
    }

    struct code_signature_command signature;
    bool foundSignature = false;
    uint8_t *cursor = (uint8_t *)commands;
    uint32_t remaining = header.sizeofcmds;
    for (uint32_t i = 0; i < header.ncmds && remaining >= sizeof(struct load_command); i++) {
        struct load_command command;
        memcpy(&command, cursor, sizeof(command));
        if (command.cmdsize < sizeof(command) || command.cmdsize > remaining) break;
        if (command.cmd == LC_CODE_SIGNATURE && command.cmdsize >= sizeof(signature)) {
            memcpy(&signature, cursor, sizeof(signature));
            foundSignature = true;
            break;
        }
        cursor += command.cmdsize;
        remaining -= command.cmdsize;
    }
    free(commands);
    if (!foundSignature || signature.datasize == 0) {
        close(fd);
        return false;
    }

    fsignatures_t siginfo = {0};
    siginfo.fs_file_start = sliceOffset;
    siginfo.fs_blob_start = (void *)(long)signature.dataoff;
    siginfo.fs_blob_size = signature.datasize;
    if (fcntl(fd, F_ADDFILESIGS_RETURN, &siginfo) == -1) {
        close(fd);
        return false;
    }

    fchecklv_t checkInfo = {0};
    char message[512] = {0};
    checkInfo.lv_error_message_size = sizeof(message);
    checkInfo.lv_error_message = message;
    checkInfo.lv_file_start = sliceOffset;
    int result = fcntl(fd, F_CHECK_LV, &checkInfo);
    close(fd);
    return result == 0;
}

bool checkCodeSignature(const char* path) {
    return TDSafeCheckCodeSignature(path);
}

NSString* getExecutableEntitlementXML(NSString* path) {
    __block NSString* ans = @"Failed to find main executable?";
    // it seems the debug build messes the code signature region up, so we search the executable file on the disk instead.
    LCParseMachO(path.UTF8String, true, ^(const char *path, struct mach_header_64 *header, int fd, void *filePtr) {
        ans = getEntitlementXML(header, 0);
    });
    return ans;
}

#pragma mark - Guest executable Mach-O header restore (anti-tamper)

// DyldHooksInit / LCBootstrap 维护的访客主镜像真实索引; 使用前必须按路径核验,
// 不能盲信 (常驻进程里它可能仍指向上一轮访客或尚未解析).
extern uint32_t appMainImageIndex;

#define LC_TD_ORIG_EXEC_SUFFIX ".td-original.executable"
// load commands 区域上限: __TEXT 空洞远小于此, 更大的 sizeofcmds 必为损坏/伪造.
#define LC_TD_MAX_SIZEOFCMDS (256 * 1024)

static inline uint32_t LC_td_swap32(uint32_t value, bool swap) {
    return swap ? OSSwapInt32(value) : value;
}

// 头文件在 iOS SDK 里不导出 mach_vm_region 的原型, 与运行时 (libsystem_kernel
// 的 MIG 桩) 保持 syscalls.h 中的签名一致.
extern kern_return_t mach_vm_region(vm_map_t target_task,
                                    mach_vm_address_t *address,
                                    mach_vm_size_t *size,
                                    vm_region_flavor_t flavor,
                                    vm_region_info_t info,
                                    mach_msg_type_number_t *infoCnt,
                                    mach_port_t *object_name);

static bool LCIsArm64Header(struct mach_header_64 *header, off_t available) {
    return header->magic == MH_MAGIC_64 &&
           header->cputype == CPU_TYPE_ARM64 &&
           header->ncmds > 0 && header->ncmds <= 4096 &&
           header->sizeofcmds >= (uint32_t)header->ncmds * (uint32_t)sizeof(struct load_command) &&
           header->sizeofcmds <= LC_TD_MAX_SIZEOFCMDS &&
           header->sizeofcmds <= (uint32_t)(available - (off_t)sizeof(struct mach_header_64)) &&
           (off_t)sizeof(struct mach_header_64) + header->sizeofcmds <= available;
}

// 严格走一遍 load command 序列: 每条 cmdsize 至少容纳自身、不超过剩余空间,
// ncmds 条必须全部落在缓冲区里. 防止把越界/截断数据当合法头写回内存.
static bool LCValidateLoadCommands(struct mach_header_64 *header) {
    uint8_t *cursor = (uint8_t *)header + sizeof(struct mach_header_64);
    uint8_t *end = (uint8_t *)header + sizeof(struct mach_header_64) + header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if ((uint8_t *)end - cursor < (ptrdiff_t)sizeof(struct load_command)) return false;
        struct load_command *command = (struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)) return false;
        if (command->cmdsize > (uint32_t)((uint8_t *)end - cursor)) return false;
        cursor += command->cmdsize;
    }
    return true;
}

bool LCLoadOriginalExecutableMachOHeader(const char *execPath,
                                         struct mach_header_64 **outHeader,
                                         uint32_t *outHeaderSize) {
    if (outHeader) *outHeader = NULL;
    if (outHeaderSize) *outHeaderSize = 0;
    if (!execPath || !execPath[0] || !outHeader || !outHeaderSize) return false;

    char backupPath[PATH_MAX];
    int written = snprintf(backupPath, sizeof(backupPath), "%s%s", execPath, LC_TD_ORIG_EXEC_SUFFIX);
    if (written < 0 || (size_t)written >= sizeof(backupPath)) return false;

    // 与 TDSafeCheckCodeSignature 同样的理由: pread 读头, 不 mmap, 避免签名
    // 校验路径上的额外副作用; 备份不存在时保持现状 (no-op, 返回 false).
    int fd = open(backupPath, O_RDONLY);
    if (fd < 0) return false;
    struct stat st = {0};
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(struct mach_header_64)) {
        close(fd);
        return false;
    }

    off_t sliceOffset = 0;
    off_t sliceSize = st.st_size;
    uint32_t magic = 0;
    bool ok = TDReadAt(fd, &magic, sizeof(magic), 0);
    if (ok && (magic == FAT_CIGAM || magic == FAT_MAGIC)) {
        // universal: 找 arm64 slice. 首选 cputype==CPU_TYPE_ARM64; 兼容个别
        // 工具把 64 位 slice 标成 CPU_TYPE_ARM+CPU_SUBTYPE_ARM64_ALL 的写法,
        // 这类候选必须靠 slice 自身的 MH_MAGIC_64 二次确认.
        struct fat_header fat;
        if (!TDReadAt(fd, &fat, sizeof(fat), 0)) {
            close(fd);
            return false;
        }
        bool swapFields = (magic == FAT_CIGAM);
        uint32_t count = LC_td_swap32(fat.nfat_arch, swapFields);
        if (count == 0 || count > 64 ||
            (off_t)sizeof(fat) + (off_t)count * (off_t)sizeof(struct fat_arch) > st.st_size) {
            close(fd);
            return false;
        }
        bool haveExact = false, haveLoose = false;
        off_t looseOffset = 0, looseSize = 0;
        for (uint32_t i = 0; i < count; i++) {
            struct fat_arch arch;
            off_t at = (off_t)sizeof(fat) + (off_t)i * (off_t)sizeof(arch);
            if (!TDReadAt(fd, &arch, sizeof(arch), at)) break;
            uint32_t cputype = LC_td_swap32(arch.cputype, swapFields);
            uint32_t subtype = LC_td_swap32(arch.cpusubtype, swapFields);
            uint32_t offset = LC_td_swap32(arch.offset, swapFields);
            uint32_t size = LC_td_swap32(arch.size, swapFields);
            // offset/size 是 uint32, 转 off_t(64 位)后相加不会溢出 32 位边界;
            // 仍需检查 slice 完整落在文件内.
            bool inBounds = (off_t)offset + (off_t)size <= st.st_size &&
                            size >= (uint32_t)sizeof(struct mach_header_64);
            if (!inBounds) continue;
            if (cputype == CPU_TYPE_ARM64) {
                sliceOffset = (off_t)offset;
                sliceSize = (off_t)size;
                haveExact = true;
                break;
            }
            if (!haveLoose && cputype == CPU_TYPE_ARM && subtype == CPU_SUBTYPE_ARM64_ALL) {
                looseOffset = (off_t)offset;
                looseSize = (off_t)size;
                haveLoose = true;
            }
        }
        if (!haveExact) {
            if (!haveLoose) {
                close(fd);
                return false;
            }
            sliceOffset = looseOffset;
            sliceSize = looseSize;
        }
        if (!TDReadAt(fd, &magic, sizeof(magic), sliceOffset)) {
            close(fd);
            return false;
        }
    }
    if (ok && magic == MH_MAGIC_64) {
        struct mach_header_64 probe;
        if (!TDReadAt(fd, &probe, sizeof(probe), sliceOffset) ||
            !LCIsArm64Header(&probe, sliceSize)) {
            ok = false;
        } else {
            uint32_t total = (uint32_t)sizeof(probe) + probe.sizeofcmds;
            struct mach_header_64 *buffer = (struct mach_header_64 *)malloc(total);
            if (!buffer || !TDReadAt(fd, buffer, total, sliceOffset) ||
                !LCValidateLoadCommands(buffer)) {
                free(buffer);
                ok = false;
            } else {
                *outHeader = buffer;
                *outHeaderSize = total;
            }
        }
    } else {
        ok = false;
    }
    close(fd);
    if (!ok) {
        *outHeader = NULL;
        *outHeaderSize = 0;
    }
    return ok;
}

// dyld 内部表 (all_image_infos) 按真实加载顺序排列且不受 litehook 对
// _dyld_* 的重绑影响; 这里的路径比较容忍 /private 前缀差异 (dlopen 记录
// 的常是 realpath).
static bool LCTDImagePathMatches(const char * imagePath, const char *execPath) {
    if (!imagePath || !execPath) return false;
    if (strcmp(imagePath, execPath) == 0) return true;
    if (strncmp(imagePath, "/private", 8) == 0 && strcmp(imagePath + 8, execPath) == 0) return true;
    if (strncmp(execPath, "/private", 8) == 0 && strcmp(imagePath, execPath + 8) == 0) return true;
    return false;
}

static bool LCTDHeaderLooksLikeGuest(struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) return false;
    // 补丁后的镜像是 MH_DYLIB, 已恢复/未打补丁的是 MH_EXECUTE; 其它一律拒绝.
    return header->filetype == MH_EXECUTE || header->filetype == MH_DYLIB;
}

// 定位当前访客主镜像在内存里的 header, 并给出它在 dyld 表里的路径 (读备份用).
// 优先: 按路径核验过的 appMainImageIndex; 回退: all_image_infos / _dyld 枚举
// 里的 exec path 匹配. 不依赖任何未经验证的全局.
static struct mach_header_64 *LCTDResolveGuestImageHeader(const char *execPath,
                                                          const char **outPath) {
    if (outPath) *outPath = NULL;
    struct dyld_all_image_infos *infos = _alt_dyld_get_all_image_infos();
    if (infos && infos->infoArray && infos->infoArrayCount) {
        uint32_t count = infos->infoArrayCount;
        if (execPath && execPath[0] && appMainImageIndex < count) {
            const char *candidatePath = infos->infoArray[appMainImageIndex].imageFilePath;
            struct mach_header_64 *candidate =
                (struct mach_header_64 *)infos->infoArray[appMainImageIndex].imageLoadAddress;
            if (LCTDImagePathMatches(candidatePath, execPath) &&
                LCTDHeaderLooksLikeGuest(candidate)) {
                if (outPath) *outPath = candidatePath;
                return candidate;
            }
        }
        if (execPath && execPath[0]) {
            // 常驻进程里可能留着上一轮访客的同路径镜像, 从后往前取最新一轮.
            for (uint32_t i = count; i-- > 0;) {
                const char *candidatePath = infos->infoArray[i].imageFilePath;
                struct mach_header_64 *candidate =
                    (struct mach_header_64 *)infos->infoArray[i].imageLoadAddress;
                if (LCTDImagePathMatches(candidatePath, execPath) &&
                    LCTDHeaderLooksLikeGuest(candidate)) {
                    if (outPath) *outPath = candidatePath;
                    return candidate;
                }
            }
        } else {
            // 调用方没给路径: appMainImageIndex 只能靠自身合理性核验
            // (arm64 主可执行/被补丁形态), 无法再对路径.
            if (appMainImageIndex < count) {
                const char *candidatePath = infos->infoArray[appMainImageIndex].imageFilePath;
                struct mach_header_64 *candidate =
                    (struct mach_header_64 *)infos->infoArray[appMainImageIndex].imageLoadAddress;
                if (candidatePath && LCTDHeaderLooksLikeGuest(candidate)) {
                    if (outPath) *outPath = candidatePath;
                    return candidate;
                }
            }
        }
    }
    if (execPath && execPath[0]) {
        // 最后回退: 公开 _dyld 枚举. 它可能已被重绑成"可见清单", 但可见清单
        // 与 header/名称之间自洽, 按路径匹配仍然成立.
        uint32_t count = _dyld_image_count();
        for (uint32_t i = count; i-- > 0;) {
            const char *candidatePath = _dyld_get_image_name(i);
            struct mach_header_64 *candidate =
                (struct mach_header_64 *)_dyld_get_image_header(i);
            if (LCTDImagePathMatches(candidatePath, execPath) &&
                LCTDHeaderLooksLikeGuest(candidate)) {
                if (outPath) *outPath = candidatePath;
                return candidate;
            }
        }
    }
    return NULL;
}

bool LCRestoreGuestExecutableMachOHeader(const char *execPath) {
    const char *imagePath = NULL;
    struct mach_header_64 *guestHeader = LCTDResolveGuestImageHeader(execPath, &imagePath);
    if (!guestHeader) return false;

    struct mach_header_64 *orig = NULL;
    uint32_t origSize = 0;
    // 备份缺失/损坏: 完全 no-op, 保持现有行为.
    if (!LCLoadOriginalExecutableMachOHeader(imagePath ? imagePath : execPath, &orig, &origSize)) {
        return false;
    }

    bool restored = false;
    do {
        if (orig->cputype != guestHeader->cputype) break;
        // LCPatchExecSlice 只会往空洞里加命令, 所以原始头部必然不比当前头大.
        // 若相等即已恢复过 -> memcmp 命中直接成功; 若"当前更小"说明镜像不是
        // 我们认识的那份, 绝不扩大写入范围.
        if (orig->sizeofcmds > guestHeader->sizeofcmds) break;
        if (memcmp(guestHeader, orig, origSize) == 0) {
            restored = true; // 幂等: 已经是原始结构
            break;
        }

        uint64_t start = (uint64_t)guestHeader & ~(uint64_t)(16384 - 1);
        uint64_t end = ((uint64_t)guestHeader + origSize + (16384 - 1)) & ~(uint64_t)(16384 - 1);
        vm_size_t span = (vm_size_t)(end - start);

        // 先查询该页现有保护, 写完按原样恢复; 页里可能同时有 __text,
        // 不能像旧实现那样无条件降级成只读.
        vm_prot_t currentProt = VM_PROT_READ | VM_PROT_EXECUTE;
        mach_vm_address_t regionAddr = (mach_vm_address_t)start;
        mach_vm_size_t regionSize = 0;
        vm_region_basic_info_data_64_t regionInfo = {0};
        mach_msg_type_number_t regionCount = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t regionObject = MACH_PORT_NULL;
        if (mach_vm_region(mach_task_self(), &regionAddr, &regionSize, VM_REGION_BASIC_INFO_64,
                           (vm_region_info_t)&regionInfo, &regionCount, &regionObject) == KERN_SUCCESS) {
            currentProt = regionInfo.protection;
        }
        if (regionObject) mach_port_deallocate(mach_task_self(), regionObject);

        kern_return_t kret = builtin_vm_protect(mach_task_self(), (mach_vm_address_t)start, span,
                                                false, currentProt | VM_PROT_WRITE | VM_PROT_COPY);
        if (kret != KERN_SUCCESS) {
            NSLog(@"[LC] failed to make guest mach header writable: %d", kret);
            break;
        }
        // 只覆盖原始 header+load commands 的字节范围: 保留镜像指针与运行时映射,
        // 不碰 __LINKEDIT, 不做 section 地址重映射.
        memcpy(guestHeader, orig, origSize);
        kret = builtin_vm_protect(mach_task_self(), (mach_vm_address_t)start, span,
                                  false, currentProt);
        if (kret != KERN_SUCCESS) {
            NSLog(@"[LC] failed to restore guest mach header protection: %d", kret);
        }
        restored = true;
    } while (0);

    free(orig);
    return restored;
}
