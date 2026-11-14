//
//  TDRootHideInit.h
//  TequilaDash
//
//  roothide 路径层 (Tier B-3) 的 init 替身 —— 本仓自有代码.
//
//  上游 roothide/libroothide 的 init.c 用一个构造器断言「roothideinit.dylib 自身路径
//  形如 /var/containers/Bundle/Application/.jbroot-<rand>/usr/lib/roothideinit.dylib」
//  来推导 __roothideinit_JBROOT / __roothideinit_JBRAND; 我们的 jbroot 落在 app 沙盒
//  Documents 内, 该推导链不存在, 因此改成两条显式通道:
//    1. 宿主/扩展在 TDVRootInstallIfRequested 同点调 TDRootHideInstallFromEnvIfRequested()
//       (读 TD_VROOT / TD_VROOT_MODE, 与 Tier A 同一门控, 默认关);
//    2. TDLibVrootApi.dylib (symredirect 的 shim 库) 加载时由本文件的构造器自动走同一
//       环境变量通道 —— 被改写的 rootfs 二进制载入任何进程都能拿到正确的 JBROOT.
//
//  差异点 (对上游 init.c):
//    · 不再从库路径推导, 不再 assert; 环境未设置时保持 NULL, jbroot_alloc/rootfs_alloc
//      对 NULL 恒等返回 (vendored jbroot.c 改造点 1).
//    · brand 仍遵守上游 common.c 的校验代数 (低字节 == 高 7 字节异或), 目录名保持
//      .jbroot-<16大写hex>, 让 is_jbroot_name / rootfs_alloc 的名字组件识别继续成立.
//

#ifndef TDRootHideInit_h
#define TDRootHideInit_h

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 显式设置 jbroot 根 (绝对路径; 通常以 .jbroot-<16hex> 目录名结尾).
/// 首次调用生成随机 brand; 同根幂等, 换根更新全局 (旧串不回收).
/// 根为 NULL / 非绝对路径 / 以 "/" 结尾整体视作未安装 (返回 false, 不改动全局).
bool TDRootHideSetJBRoot(const char *jbrootPath);

/// 读 TD_VROOT (绝对路径) + TD_VROOT_MODE (off -> 不安装); 安装成功返回 true.
/// 幂等: 已设置同一根时直接返回 true.
bool TDRootHideInstallFromEnvIfRequested(void);

/// 当前 __roothideinit_JBROOT; 未安装返回 NULL.
const char *TDRootHideJBRootPath(void);

/// 当前 __roothideinit_JBRAND (16 位大写 hex); 未安装返回 NULL.
const char *TDRootHideJBRootBrand(void);

/// 生成随机 jbroot 目录名 ".jbroot-<16大写hex>" (brand 校验字节合法).
/// outSize 不足返回 false; TDRootfsUnpack 用它落 per-guest 随机根.
bool TDRootHideMakeRandomRootName(char *out, size_t outSize);

#ifdef __cplusplus
}
#endif

#endif /* TDRootHideInit_h */
