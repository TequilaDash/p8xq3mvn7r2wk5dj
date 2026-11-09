//
// 本仓适配桥接头 (2026-11-09).
//
// 上游原件: vendor/LiveContainer/LiveContainerSwiftUI/LiveContainerSwiftUI-Bridging-Header.h
// 镜像保持 100% 原样 (便于同步上游); framework 的 SWIFT_OBJC_BRIDGING_HEADER 指向本文件.
//
// 差异 (CI run 42626661044 实测): 上游桥接头第 18 行
//   #include "../LiveContainer/FoundationPrivate.h"
// 与 MultitaskSupport/AppSceneViewController.h:8 / PiPManager.h:10 的
//   #import "FoundationPrivate.h"
// 同时引入两份不同路径但内容相同的 FoundationPrivate.h —— 该文件无 include guard,
// 于是 NSExtension / _CFXPreferences2 / CFPrefsPlistSource2 重复 @interface 定义,
// PCH 生成失败. 上游靠 Xcode 16 自动同步组只编一份规避, 本仓两个 source path 会撞.
//
// 处理: 不再由桥接头单独 include FoundationPrivate.h (多任务头文件已经引入);
//       所有 ../ 相对 include 改裸名, 由 framework 的 HEADER_SEARCH_PATHS 解析,
//       保证同一头文件只解析到一个物理路径.
//
#ifndef TequilaDashLCUI_Bridging_Header_h
#define TequilaDashLCUI_Bridging_Header_h

#include "LCAppInfo.h"
#include "LCSharedUtils.h"
#include "LCUtils.h"
#include "unarchive.h"
#include "AppSceneViewController.h"
#include "DecoratedAppSceneViewController.h"
#include "LCStatusBarManager.h"
#include "PiPManager.h"
#include "VirtualWindowsHostView.h"

#endif
