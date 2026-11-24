//
//  PatchRevision.h
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
//  原封不动留在原处。所以修复代码写得再对也不会生效。
//
//  【本块】把门控版本号收进 iManager，升级补丁逻辑时只改这里一个数：
//  数字一加，所有已安装 app 下次启动都会重打补丁，走到修好的写名字路径。
//
//  【为什么重打安全】脏名只是名字字段多了尾巴（"…dylibC"），cmdsize 结构完好；
//  LCPatchExecSlice 用 strncmp 前缀匹配能找到这条命令，再由
//  iManagerSettleLoaderDylibCommand 原地清空名字字段、写入干净路径。
//
//  【引用点】LiveContainerSwiftUI/Models/LCAppInfo.m
//      int currentPatchRev = iManagerCurrentPatchRevision();
//

#ifndef IMANAGER_PATCH_REVISION_H
#define IMANAGER_PATCH_REVISION_H

// 每次改动补丁逻辑（MachO 打补丁相关）就把这个数 +1。
// 8 = 首个 iManager 补丁版本：load command 名字写入全部有界化（MachONameFix）。
static inline int iManagerCurrentPatchRevision(void) {
    return 8;
}

#endif /* IMANAGER_PATCH_REVISION_H */
