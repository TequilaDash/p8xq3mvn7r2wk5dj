//
//  iManagerPatches.swift
//  iManager — zcontainer-test2 源码块
//
//  iManager 设置页的「补丁管理」二级界面：只列**修补类**改动
//  （替换/加固上游既有行为的），不列功能性新增。
//
//  【为什么要有编号】上游 getzeusapp/LiveContainer 以后可能自己修掉同样的
//  问题。那时我们要能精确撤掉自己那一块，而不是靠回忆。编号就是撤销的锚点：
//      ZC-PATCH-001  补丁名  撤销时删哪个文件 / 还哪几行
//
//  【编号规则】
//      ZC-PATCH-NNN   修补（改上游既有逻辑的行为）
//      功能性新增不进这个列表，也不占编号
//  编号一旦发出不再复用；撤销后该号作废并标注 retired。
//
//  【引用点】iManagerPatchesPage 由 iManagerSettingsPage 打开。
//

import SwiftUI

/// 一条 iManager 修补的记录。编号是撤销锚点，不是版本号。
struct IManagerPatch: Identifiable {
    /// 例如 "ZC-PATCH-001"。发出后不复用。
    let id: String
    /// 界面上显示的名字。
    let title: String
    /// 一句话说明修了什么。
    let summary: String
    /// 这块补丁落在哪些源码文件里（撤销时要动的地方）。
    let files: [String]
    /// 是否已撤销（上游自己修掉后我们撤掉自己的那份）。
    let isRetired: Bool

    init(id: String, title: String, summary: String, files: [String], isRetired: Bool = false) {
        self.id = id
        self.title = title
        self.summary = summary
        self.files = files
        self.isRetired = isRetired
    }
}

/// iManager 目前合入的全部修补。**新增修补只在这里加一条**，界面自动列出。
enum IManagerPatchRegistry {
    /// 仍在生效的修补。
    static var active: [IManagerPatch] { all.filter { !$0.isRetired } }

    static let all: [IManagerPatch] = [
        IManagerPatch(
            id: "ZC-PATCH-001",
            title: "Mach-O 依赖名写入",
            summary: "上游写 load command 名字不保证 NUL 结尾、且有一处无条件 strcpy 会越界，真机表现为 TweakLoader.dylibC 找不到文件。",
            files: [
                "iManager/MachONameFix.h",
                "LiveContainer/LCMachOUtils.m（3 个调用点 + 1 行 import）",
            ]
        ),
        IManagerPatch(
            id: "ZC-PATCH-002",
            title: "load command 扫描步长",
            summary: "上游扫描循环完全信任命令自报的 cmdsize；被旧版补丁压坏的邻居会让它跳进任意内存。现在每步校验，不可信就停止扫描。",
            files: [
                "iManager/LoadCommandScanGuard.h",
                "LiveContainer/LCMachOUtils.m（扫描循环入口 1 处）",
            ]
        ),
        IManagerPatch(
            id: "ZC-PATCH-003",
            title: "已装 app 的脏依赖名重打",
            summary: "上游按 LCPatchRevision 门控是否重打补丁，已装 app 的号已达旧值就不再执行，旧版写坏的脏名永远留着。现在按事实判断：二进制里 .dylib 后面粘了字符就重打一次。",
            files: [
                "iManager/DirtyLoadCommandRepatch.h",
                "LiveContainerSwiftUI/Models/LCAppInfo.m（门控后加 1 段判断）",
            ]
        ),
        IManagerPatch(
            id: "ZC-PATCH-004",
            title: "多任务窗口恢复时的 scene 判定",
            summary: "上游 bringMultitaskViewToFront 要求目标窗口与 keyWindow 同一个 scene；deck 成为 key 后两者不同，函数返回 false，窗口被恢复出来却没置前，主屏上多出一张缩小的小卡。现在以目标窗口自己的 scene 为准。",
            files: [
                "MultitaskSupport/MultitaskDockView.swift（1 行：window.windowScene ?? keyWindow?.windowScene）",
            ]
        ),
        IManagerPatch(
            id: "ZC-PATCH-005",
            title: "窗口化访客回到前台的那一帧",
            summary: "访客窗口可能是窗口化状态（isMaximized == false），从 deck 恢复可见的那一帧会露出居中小卡与上下黑边（用户截图 IMG_0666）。现在恢复可见之前先铺满。",
            files: [
                "iManager/MultitaskStackView.swift（选卡回前台处 1 行）",
                "MultitaskSupport/DecoratedAppSceneViewController.h（补 maximizeWindow 声明）",
            ]
        ),
    ]
}

/// 「补丁管理」页面：列出 iManager 合入的修补，点进去看它改了哪些文件。
struct IManagerPatchesPage: View {
    private var active: [IManagerPatch] { IManagerPatchRegistry.active }
    private var retired: [IManagerPatch] { IManagerPatchRegistry.all.filter { $0.isRetired } }

    var body: some View {
        List {
            if !active.isEmpty {
                Section {
                    ForEach(active) { patch in
                        NavigationLink {
                            IManagerPatchDetailPage(patch: patch)
                        } label: {
                            IManagerPatchRow(patch: patch)
                        }
                    }
                } footer: {
                    Text("这些是 iManager 对上游 zContainer 的修补。上游自己修掉同样的问题后，按编号撤掉我们这一份。")
                        .font(.footnote)
                }
            }

            if !retired.isEmpty {
                Section("已撤销") {
                    ForEach(retired) { patch in
                        IManagerPatchRow(patch: patch)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("补丁管理")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 补丁列表的一行：编号 + 名字，编号用等宽字，方便对照代码。
private struct IManagerPatchRow: View {
    let patch: IManagerPatch

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(patch.title)
                .font(.body)
            Text(patch.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// 一条补丁的详情：说明 + 落在哪些文件。
private struct IManagerPatchDetailPage: View {
    let patch: IManagerPatch

    var body: some View {
        List {
            Section {
                Text(patch.summary)
                    .font(.callout)
            } header: {
                Text(patch.id)
                    .font(.caption.monospaced())
            }

            Section("改动的文件") {
                ForEach(patch.files, id: \.self) { file in
                    Text(file)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section {
                Text("撤销这一块：删掉上面的 iManager 文件，并把上游文件里的调用点改回原样。上游源码本身没有被重写过。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(patch.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
