# vendor/roothide

> roothide/libroothide 的 vendored 副本 (Tier B-3 路径层)。**MIT 许可** (见 LICENSE)，
> 本仓许可面干净：允许随仓再分发，允许修改后闭源使用。

## 来源与核对

- 上游: https://github.com/roothide/libroothide (MIT, "Copyright (c) 2023 RootHide")
- 钉住的 commit: `cb236f9` (main, 2026-11-14 拉取时点)
- LICENSE 逐字保留；除下列「改造台账」外，文件逐字未改。

## 文件清单 (15 个)

| 文件 | 上游角色 | 本仓消费者 |
|---|---|---|
| `LICENSE` | MIT 许可正文 | — (不进编译) |
| `common.h` | jbroot 名字代数常量 + 全局声明 | 主 App / 扩展 / TDLibVrootApi |
| `common.c` | `is_jbroot_name` / `resolve_jbrand_value` 校验代数 | 同上 |
| `cache.h` `cache.c` | 路径换算结果缓存 (线程锁) | 同上 |
| `jbroot.c` | `jbroot_alloc` / `jbrootat_alloc` / `rootfs_alloc` 路径代数核心 | 主 App / TDLibVrootApi |
| `roothide.h` | 公共 API 头 (`jbroot()`/`rootfs()`/`jbrand()`) | TDLibVrootApi |
| `vroot.h` | vroot API 表 (VROOT_API_* 宏驱动) | TDLibVrootApi / symredirect.cpp |
| `vroot.c` | `vroot_*` 实现 (open/stat/realpath/posix_spawn 族…) | TDLibVrootApi |
| `vrootapi.c` | libc 同名裸跳板 (`open`→`b _vroot_open`) | TDLibVrootApi |
| `vroot_mktemp.c` | mkstemp/mkdtemp 族实现 | TDLibVrootApi |
| `vroot_rootfs.c` | readdir/readdir_r 族实现 (rootfs 符号链接改写) | TDLibVrootApi |
| `vroot_exec.c` | execv/execve/execl 族实现 | TDLibVrootApi |
| `vroot_dlfcn.c` | dlopen/dlsym/dladdr 实现 | TDLibVrootApi |
| `symredirect.cpp` | 离线 Mach-O 符号重绑 CLI (35KB, 自包含) | 主 App (TDRootfsUnpack 调用) |
| `TDRootHideInit.h` `TDRootHideInit.c` | **本仓自有** (替代上游 init.c，见下) | 主 App / 扩展 / TDLibVrootApi |

未 vendored 的上游文件与原因：
- `init.c` — 路径推导构造器 (假设库位于 `/var/containers/Bundle/Application/…`)，
  与本仓沙盒环境不成立；`TDRootHideInit.{h,c}` 以「显式 setter + TD_VROOT 环境
  变量」重写其角色（不拷贝推导逻辑）。
- `jbroot.cpp` / `jbroot.m` — C++/NSString 便捷重载，本仓只走 C API。
- `debug.m` / `stub.h` / `roothide-theos.h` / `roothide-xcode.h` / `module.modulemap`
  / `Makefile` / `updatelink*.c*` / `cmdtool.c` / `control*` / `entitlements.plist`
  — devkit/构建期工具，本仓用 xcodegen 目标替代。

## 改造台账 (逐文件)

1. `common.h`
   - 删除 `#define JB_ROOT_PARENT "/var/containers/Bundle/Application"`（上游 init.c
     的推导前提，本仓 jbroot 落在 app 沙盒 Documents 内）。
2. `jbroot.c`（其余逻辑逐字保留）
   - `__roothideinit_JBROOT` 改为可由外部设置（`TDRootHideSetJBRoot` /
     `TDRootHideInstallFromEnvIfRequested`）；未设置时 `jbrootat_alloc` / `rootfs_alloc`
     恒等返回（上游在构造器 `assert` 推导成功）。
   - `rootfs_alloc` 检测 `.jbroot-<rand>` 名字组件时，父目录由 JBROOT 运行时推导，
     不再 stat 硬编码常量。
   - `jbrootat_alloc` 对已位于 JBROOT 之内的绝对路径恒等返回，防
     `<JBROOT><JBROOT>/…` 双前缀（上游不存在该输入，行为是安全超集）。
   - `jbrand()` 对未初始化 (JBRAND==NULL) 返回 0，不再解引用。
3. `vroot.c`（其余逻辑逐字保留）
   - 去掉 `#include <util.h>`：本仓顶层 HEADER_SEARCH_PATHS 含 `$(SRCROOT)/ZSign/common`，
     角括号 `<util.h>` 先命中 ZSign 的 util.h → 其 common.h → `<set>`（C++ 头）在
     C 编译单元报 "'set' file not found"（CI run 43548247600 实锤）。本文件不使用
     util.h 的任何符号（forkpty/openpty 族），直接移除。
   - iOS 27.2 SDK 把 `posix_spawn_file_actions_addchdir_np` 标记 unavailable；
     定义同签名静态桩（ENOSYS）替换真函数，保持 vroot_* 符号面与跳板层 ABI 完整
     （CI run 43549070193 实锤）。
4. `vroot.h`（API 表逐字保留）
   - `#include <Availability.h>` 与 "ios sdk version too old" #error 改为
     `VROOT_API_ALL`/`__IPHONE_16_0` 双判据门控：vroot.c 尾部符号表与 symredirect.cpp
     的符号表数组把本文件 include 在**初始化器内部**，模块化编译下 Availability.h
     的展开体进初始化器即报 "expected expression/'}'"（CI run 43549070193 实锤）。
     两种上下文都不消费 Availability.h 实体，顶层遍（vrootapi.c / vroot.c 定义遍）
     行为不变。
5. `symredirect.cpp`（改写逻辑逐字保留）
   - CLI `main()` → 库函数 `symredirect_process_file(target, tmpdir, errbuf, errbufsize)`；
     临时目录参数化（iOS 沙盒无可写的 `/tmp`），诊断改 errbuf。
6. `TDRootHideInit.{h,c}`（本仓自有）
   - brand 生成遵守上游 `common.c` 校验代数（低字节 == 高 7 字节异或），
     目录名保持 `.jbroot-<16大写hex>`。
   - TDLibVrootApi.dylib 的 constructor 调 `TDRootHideInstallFromEnvIfRequested()`，
     承担上游 roothideinit.dylib 构造器的角色，但输入是 `TD_VROOT/TD_VROOT_MODE`。

## 编译拓扑

- 主 App target：`common.{c,h}` `cache.{c,h}` `jbroot.c` `roothide.h` `vroot.h`
  `TDRootHideInit.{c,h}` `symredirect.cpp`（见 project.yml 主 target 的 excludes）。
- `TequilaDashLiveProcess` 扩展 target：仅 `TDRootHideInit.c` + `common.c`
  （LCBootstrap 的 roothide init 调用链）。
- `TDLibVroot` dylib target（实现件）：`vroot.c` 族 + jbroot 路径代数 + `TDRootHideInit.c`。
- `TDLibVrootApi` dylib target（跳板件）：`vrootapi.c`，LC_LOAD_DYLIB 指向
  `@loader_path/TDLibVroot.dylib`。**两件不能合一** —— vroot.c 的真 libc 引用会被
  静态链接器绑到同镜像的同名跳板上，形成 `vroot_open -> open -> vroot_open` 无限
  递归；上游 Makefile 正是 libvroot/libvrootapi 分体，本仓 1:1 同构。
  两件都 embed 进主 App（不链接），由 TDRootfsUnpack 拷到
  `<jbroot>/usr/lib/{libvrootapi,TDLibVroot}.dylib`。
- 许可正文另有 NOTICE 第 9 条登记；`Resources/Scripts/swift_precommit_check.py`
  不涉及本目录。
