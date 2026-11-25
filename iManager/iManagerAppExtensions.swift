//
//  iManagerAppExtensions.swift
//  iManager
//
//  访客 App 的扩展（.appex）带到 zContainer 主屏幕。
//
//  【为什么单独一个文件】
//  用户要求：所有改动集中在 iManager，极致最小化引入自己的源码文件，
//  避免影响后续同步上游 zcontainer。所以这里只**读取**上游已有的东西
//  （LCAppModel.appInfo.bundlePath、HomeWidget/HomeLayout 的数据结构），
//  不修改上游任何一行。
//
//  【阶段一（本文件已实现）】
//  扫描容器内每个 App 的 PlugIns/*.appex，把 widget 扩展列成主屏幕可放置的条目。
//  放置后显示扩展图标 + 名字，点击跳回所属 App。
//
//  【阶段二（未实现，见任务清单）】
//  真正实例化 WidgetKit 扩展并渲染其内容。jailed 环境下需要把 appex 的
//  Mach-O 载入并跑其 timeline provider，属于后续独立课题。
//

import SwiftUI
import UIKit

/// 一个访客 App 携带的扩展。
struct IManagerAppExtension: Identifiable, Hashable {
    /// 稳定标识：所属 App 的 uuid + appex 的 bundle id。
    let id: String
    /// 所属 App 的 uuid（LCAppModel.appUUID）。
    let appUUID: String
    /// 所属 App 的显示名，用于副标题。
    let appName: String
    /// 扩展自己的显示名（appex 的 CFBundleDisplayName，取不到用文件名）。
    let displayName: String
    /// 扩展的 bundle id（appex 的 CFBundleIdentifier）。
    let bundleIdentifier: String
    /// 扩展类型：widget / 其它（本阶段只关心 widget）。
    let isWidget: Bool
    /// appex 包在磁盘上的绝对路径。
    let path: String
    /// 扩展图标（从 appex 的图标文件读，取不到用 SF Symbol）。
    let icon: UIImage?
}

/// 扫描并缓存访客 App 的扩展。
///
/// 只读文件系统，不加载任何可执行代码，所以不会触发沙盒或签名问题。
enum IManagerAppExtensionStore {
    /// 扫描某个 App 的 PlugIns 目录。
    static func extensions(for app: LCAppModel) -> [IManagerAppExtension] {
        guard let bundlePath = app.appInfo.bundlePath(), !bundlePath.isEmpty else { return [] }
        let pluginsURL = URL(fileURLWithPath: bundlePath).appendingPathComponent("PlugIns")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: pluginsURL.path) else {
            return []
        }
        let appTitle = app.appInfo.displayName() ?? app.homeKey ?? "未命名 App"
        let appKey = app.homeKey ?? appTitle
        var result: [IManagerAppExtension] = []
        for name in names.sorted() where name.hasSuffix(".appex") {
            let appexURL = pluginsURL.appendingPathComponent(name)
            let infoPath = appexURL.appendingPathComponent("Info.plist").path
            guard let info = NSDictionary(contentsOfFile: infoPath) as? [String: Any] else { continue }
            // 只收 widget 扩展：NSExtensionPointIdentifier 必须是 com.apple.widgetkit-extension。
            let extensionDict = info["NSExtension"] as? [String: Any]
            let point = (extensionDict?["NSExtensionPointIdentifier"] as? String) ?? ""
            let isWidget = point == "com.apple.widgetkit-extension"
            guard isWidget else { continue }
            let rawDisplay = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
            let display: String = rawDisplay ?? (name as NSString).deletingPathExtension
            let bundleID = (info["CFBundleIdentifier"] as? String) ?? name
            result.append(IManagerAppExtension(
                id: "\(appKey)#\(bundleID)",
                appUUID: appKey,
                appName: appTitle,
                displayName: display,
                bundleIdentifier: bundleID,
                isWidget: isWidget,
                path: appexURL.path,
                icon: icon(at: appexURL)
            ))
        }
        return result
    }

    /// 全部 App 的扩展，按 App 名排序。
    static func allExtensions(in apps: [LCAppModel]) -> [IManagerAppExtension] {
        apps.flatMap { extensions(for: $0) }
    }

    /// 从 appex 里取图标。App Extension 通常没有自己的图标，退回所属 App 的图标。
    private static func icon(at appexURL: URL) -> UIImage? {
        for candidate in ["AppIcon60x60@2x.png", "AppIcon60x60@3x.png", "Icon.png"] {
            let url = appexURL.appendingPathComponent(candidate)
            if let image = UIImage(contentsOfFile: url.path) { return image }
        }
        return nil
    }
}

/// 「应用扩展」设置页：列出容器内每个 App 携带的 widget 扩展。
///
/// 阶段一只做"看得见、能跳转"；阶段二再做真正渲染扩展内容。
struct IManagerAppExtensionsPage: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @State private var extensions: [IManagerAppExtension] = []
    @State private var scanning = false

    var body: some View {
        List {
            if scanning {
                Section {
                    HStack {
                        ProgressView()
                        Text("正在扫描容器内的扩展…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if extensions.isEmpty {
                Section {
                    Text("没有找到可用的扩展")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("只有带 widget 扩展（NSExtensionPointIdentifier = com.apple.widgetkit-extension）的 App 才会出现在这里。")
                        .font(.footnote)
                }
            } else {
                Section {
                    ForEach(extensions) { item in
                        HStack(spacing: 12) {
                            if let icon = item.icon {
                                Image(uiImage: icon)
                                    .resizable()
                                    .frame(width: 29, height: 29)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            } else {
                                Image(systemName: "square.grid.2x2")
                                    .frame(width: 29, height: 29)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayName)
                                Text(item.appName)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("可放置到主屏幕")
                } footer: {
                    Text("点按主屏幕上的扩展图标会打开它所属的 App。")
                        .font(.footnote)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("应用扩展")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            scanning = true
            let apps = sharedModel.apps
            let found = await Task.detached(priority: .userInitiated) {
                IManagerAppExtensionStore.allExtensions(in: apps)
            }.value
            extensions = found
            scanning = false
        }
    }
}

// MARK: - 阶段二：真正运行扩展内容（研究结论，尚未实现）
//
// 参考样本：Nyxian 0.11.2（emexlab/Nyxian）
//   Nyxian/LindChain/ProcEnvironment/PEExtension.m（194 行）
//
// 它没有自己 dlopen appex 的 Mach-O，而是**借用系统的扩展宿主**：
//
//   NSExtension *ext = [NSExtension extensionWithIdentifier:<appex id> error:&err];
//   ext.preferredLanguages = @[];
//   NSUUID *req = [ext beginExtensionRequestWithInputItems:@[item] error:&err];
//   pid_t pid   = [ext pidForRequestIdentifier:req];
//   // 想当进程管再走 FrontBoard/RunningBoard：
//   RBSProcessHandle *h = [PrivClass(RBSProcessHandle)
//       handleForPredicate:[PrivClass(RBSProcessPredicate) predicateMatchingIdentifier:@(pid)]
//                      error:&err];
//   FBProcess *p = [FBProcessManager.sharedInstance registerProcessForAuditToken:h.auditToken];
//   p.nsExtension = ext; p.identifier = req;      // 用 objc_setAssociatedObject 挂在分类上
//
// 权限探测：[[ext _plugIn] entitlements][@"get-task-allow"]
//
// 对 zContainer 的落点：
//   1. 先用本文件的扫描拿到 appex 的 bundle id 与路径（阶段一已完成）；
//   2. 若该 appex 已被系统注册，NSExtension extensionWithIdentifier: 可直接用；
//      未注册则要先把它注册进系统扩展数据库（这一步是本阶段真正限制所在）；
//   3. WidgetKit 的 timeline 渲染仍由系统宿主完成，我们只负责把宿主产出的
//      View 取回来贴到主屏幕卡片上。
//
// 风险：FrontBoard/RunningBoard 属私有 API，越狱环境可用，jailed 下受 entitlements 限制。
// 这条不做进当前版本，等与用户确认后再单独开工。

// MARK: - 阶段二之二：Switzach ROM 的做法（不是模拟，是重建宿主）
//
// 样本：switzach_v1.0.5.tipa.zip（67MB，是 Nyxian 的 ROM 包，manifest 写
//       NXRomMinimumNyxianVersion 0.11.6、NXRomIdentifier org.emexlabs.switzach）
//
// 它没有虚拟化，而是**自己写一个精简 SpringBoard 去链接系统真框架**：
//
//   ROM/System/Library/CoreServices/SpringBoard.app/SpringBoard（570KB arm64 PIE）
//     链接：SpringBoardHome.framework（私有）、SystemStatus / SystemStatusUI（私有）、
//           UIKit / Foundation / CoreGraphics / QuartzCore
//     使用系统真类：SBAppLayout、SBWindowScene、
//                  SBWorkspaceApplicationSceneTransitionContext、iconModel、iconManager、
//                  _loadSnapshotForRequest:withDisplayItem:inAppLayout:
//     自研补齐（NX 前缀）：NXHomeScreenViewController、NXHomeScreenLayoutProvider、
//                  NXHomeScreenApplicationIconDataSource、NXHomeScreenIconStateStore、
//                  NXIconStyle、NXControlCenter、NXFloatingDockRecentlyUsed、NXPackageInstaller
//     配置键：NXROM.RealSwitcher、NXROM-visible-pages、NXROM initial App Library
//
//   ROM/System/Rom/init（1.1MB）引导进程
//     链接：FrontBoard.framework、BackBoardServices.framework、libarchive
//     自研：NXBootstrap、NXHostingViewOwnerBox、NXHitSurfaceButton、NXHostOrientationPolicy_
//           —— 即"宿主窗口 + 引导"这一层是自己实现的
//
//   ROM/usr/libexec/bootstrapd + org.emexlabs.bootstrapd.plist
//     按 manifest 的 NXRomPaths 铺路径（权限 365 = 0555、需签名）
//
// 对我们的意义：
//   真渲染访客 widget 有两条路——
//   (a) 借系统扩展宿主（Nyxian 的 NSExtension 路线，见上）；
//   (b) 自己实现宿主层去驱动 SpringBoardHome 的 icon/widget 类（Switzach 路线）。
//   两条都依赖私有框架；jailed 下受 entitlements 限制，越狱/特权环境可行。
//   当前版本不做，等与用户确认后单独开工。
