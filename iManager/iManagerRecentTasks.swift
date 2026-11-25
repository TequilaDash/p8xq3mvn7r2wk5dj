//
//  iManagerRecentTasks.swift
//  iManager — zcontainer-test2 源码块
//
//  「最近任务样式」设置页。
//
//  【命名（按用户澄清）】
//    · 「堆叠排布」= 已实现的堆叠后台（iManager/MultitaskStackView.swift）
//    · 「纵向排布」= 尚未接入，只留选项
//  两个示意图必须画得像参考图：卡片是竖向圆角矩形、上下留白、
//  堆叠样式左右各露出一截相邻卡片。
//
//  【模糊预览图有二级界面】逐 App 独立开关，存在 app group 的字典里。
//

import SwiftUI

/// 最近任务的偏好键与取值。
enum IManagerRecentTasks {
    /// 排布方式：stack = 堆叠排布（已实现）/ column = 纵向排布（未接入）。
    static let layoutKey = "iManagerRecentTasksLayout"
    static let layoutStack = "stack"
    static let layoutColumn = "column"
    /// 卡片上是否显示内存占用。沿用堆叠实际读取的键。
    static let showMemoryKey = "TDAppStackShowMemory"
    /// Dock 栏样式：clear（透明/玻璃）/ frosted（磨砂，默认）。
    /// 内存胶囊不透明度（0.2~1.0，默认 0.85）。
    static let capsuleOpacityKey = "iManagerMemoryCapsuleOpacity"
    static let dockStyleKey = "TDAppStackDockStyle"
    static let dockStyleClear = "clear"
    static let dockStyleFrosted = "frosted"
    /// 逐 App 模糊预览开关，存在这个字典键下：{ uuid: Bool }。
    static let blurPerAppKey = "iManagerRecentTasksBlurPerApp"
    /// 是否启用堆叠后台（MultitaskStackManager.isEnabled 读它）。
    static let enabledKey = "TDAppStackEnabled"

    static var isEnabled: Bool { MultitaskStackManager.isEnabled }
    static var showsMemory: Bool {
        LCUtils.appGroupUserDefault.object(forKey: showMemoryKey) as? Bool ?? true
    }
    static var dockStyle: String {
        LCUtils.appGroupUserDefault.string(forKey: dockStyleKey) ?? dockStyleFrosted
    }
    /// 某个 App 是否模糊预览。未设置时跟随全局默认（不模糊）。
    static func blursPreview(uuid: String) -> Bool {
        let map = (LCUtils.appGroupUserDefault.dictionary(forKey: blurPerAppKey) as? [String: Bool]) ?? [:]
        return map[uuid] ?? false
    }
    /// 写入某个 App 的模糊预览开关。
    static func setBlursPreview(_ value: Bool, uuid: String) {
        var map = (LCUtils.appGroupUserDefault.dictionary(forKey: blurPerAppKey) as? [String: Bool]) ?? [:]
        map[uuid] = value
        LCUtils.appGroupUserDefault.set(map, forKey: blurPerAppKey)
        LCUtils.appGroupUserDefault.synchronize()
    }
}

/// 「最近任务样式」设置页。
struct IManagerRecentTasksPage: View {
    @AppStorage(IManagerRecentTasks.enabledKey, store: LCUtils.appGroupUserDefault)
    private var isEnabled = true
    @AppStorage(IManagerRecentTasks.layoutKey, store: LCUtils.appGroupUserDefault)
    private var layout = IManagerRecentTasks.layoutStack
    @AppStorage(IManagerRecentTasks.showMemoryKey, store: LCUtils.appGroupUserDefault)
    private var showsMemory = true
    @AppStorage(IManagerRecentTasks.dockStyleKey, store: LCUtils.appGroupUserDefault)
    private var dockStyle = IManagerRecentTasks.dockStyleFrosted
    @AppStorage(IManagerRecentTasks.capsuleOpacityKey, store: LCUtils.appGroupUserDefault)
    private var capsuleOpacity = 0.85

    var body: some View {
        List {
            Section {
                Toggle("启用最近任务", isOn: $isEnabled)
            } footer: {
                Text("开启后，双击辅助触控按钮打开最近任务。")
                    .font(.footnote)
            }

            if isEnabled {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        layoutOption(IManagerRecentTasks.layoutStack, title: "堆叠排布")
                        layoutOption(IManagerRecentTasks.layoutColumn, title: "纵向排布")
                    }
                    .padding(.vertical, 6)
                    .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                } header: {
                    Text("最近任务样式")
                } footer: {
                    Text("堆叠排布：卡片叠在一起，左右各露出相邻卡片的一截。纵向排布尚未接入，选中后仍是堆叠。")
                        .font(.footnote)
                }

                Section {
                    Toggle("显示内存信息", isOn: $showsMemory)
                } footer: {
                    Text("在最近任务右上角显示选中 App 的内存占用。")
                        .font(.footnote)
                }

            }

                    Section {
                        NavigationLink {
                            IManagerBlurPreviewPage()
                        } label: {
                            LabeledContent {
                                Text(blurSummary)
                                    .foregroundStyle(.secondary)
                            } label: {
                                Text("模糊预览图")
                            }
                        }
                    } footer: {
                        Text("将最近任务的卡片内容模糊处理，保护隐私安全。可为每个 App 单独设置。")
                            .font(.footnote)
                    }

                    Section {
                        Picker("Dock 栏样式", selection: $dockStyle) {
                            Text("透明（玻璃）").tag(IManagerRecentTasks.dockStyleClear)
                            Text("磨砂").tag(IManagerRecentTasks.dockStyleFrosted)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Dock 栏样式")
                    } footer: {
                        Text("透明：玻璃质感，能看见背后的壁纸或应用。磨砂：默认的模糊底，与系统多任务栏一致。")
                            .font(.footnote)
                    }

                    Section {
                        HStack {
                            Text("内存胶囊透明度")
                            Spacer()
                            Text("\(Int(capsuleOpacity * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $capsuleOpacity, in: 0.2...1.0, step: 0.05) {
                            Text("内存胶囊透明度")
                        } minimumValueLabel: {
                            Image(systemName: "circle.dotted")
                        } maximumValueLabel: {
                            Image(systemName: "circle.fill")
                        }
                        .disabled(!showsMemory)
                    } header: {
                        Text("内存胶囊")
                    } footer: {
                        Text("右上角内存胶囊的不透明度。关掉上面的「显示内存信息」时此项不可用。")
                            .font(.footnote)
                    }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("最近任务样式")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 模糊预览的摘要：已开几个。
    private var blurSummary: String {
        let map = (LCUtils.appGroupUserDefault.dictionary(forKey: IManagerRecentTasks.blurPerAppKey) as? [String: Bool]) ?? [:]
        let on = map.values.filter { $0 }.count
        return on == 0 ? "未开启" : "\(on) 个 App"
    }

    /// 一个排布选项：示意图 + 标题，选中时蓝色描边。
    private func layoutOption(_ value: String, title: String) -> some View {
        Button {
            layout = value
        } label: {
            VStack(spacing: 6) {
                LayoutPreview(kind: value)
                    .frame(height: 168)
                    .overlay {
                        if layout == value {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                        }
                    }
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(layout == value ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 排布示意图：照参考图画——整块蓝色圆角底，里面竖向卡片。
///   stack（堆叠排布）：中间一张大卡，左右各露出一截相邻卡片
///   column（纵向排布）：上下两排、每排两张，各自独立
private struct LayoutPreview: View {
    let kind: String

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let corner = w * 0.11

            ZStack {
                // 蓝色渐变底
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.33, green: 0.53, blue: 0.98),
                                Color(red: 0.52, green: 0.74, blue: 1.00),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                if kind == IManagerRecentTasks.layoutStack {
                    // 堆叠排布：中间一张大卡，左右各露一截（相邻卡片的一部分）
                    HStack(spacing: w * 0.025) {
                        card(width: w * 0.16, height: h * 0.52, corner: w * 0.05)
                        card(width: w * 0.40, height: h * 0.64, corner: w * 0.06)
                        card(width: w * 0.16, height: h * 0.52, corner: w * 0.05)
                    }
                } else {
                    // 纵向排布：上下两排，每排两张，中间留白
                    VStack(spacing: h * 0.10) {
                        HStack(spacing: w * 0.06) {
                            card(width: w * 0.28, height: h * 0.24, corner: w * 0.05)
                            card(width: w * 0.28, height: h * 0.24, corner: w * 0.05)
                        }
                        HStack(spacing: w * 0.06) {
                            card(width: w * 0.28, height: h * 0.24, corner: w * 0.05)
                            card(width: w * 0.28, height: h * 0.24, corner: w * 0.05)
                        }
                    }
                }
            }
        }
    }

    private func card(width: CGFloat, height: CGFloat, corner: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color.white.opacity(0.34))
    }
}

/// 「模糊预览图」二级页：逐 App 独立开关。
struct IManagerBlurPreviewPage: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @State private var map: [String: Bool] = [:]
    /// 搜索框内容：按 App 名字过滤。
    @State private var query = ""

    /// 过滤后的 App 列表。
    private var filteredApps: [LCAppModel] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return sharedModel.apps }
        return sharedModel.apps.filter {
            ($0.appInfo.displayName()).localizedStandardContains(text)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(filteredApps, id: \.self) { app in
                    if let uuid = app.appInfo.dataUUID as String? {
                        Toggle(app.appInfo.displayName(), isOn: Binding(
                            get: { map[uuid] ?? false },
                            set: { newValue in
                                map[uuid] = newValue
                                IManagerRecentTasks.setBlursPreview(newValue, uuid: uuid)
                            }
                        ))
                    }
                }
            } footer: {
                Text("打开后，这个 App 在最近任务里的卡片内容会被模糊处理。")
                    .font(.footnote)
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索应用")
        .navigationTitle("模糊预览图")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            map = (LCUtils.appGroupUserDefault.dictionary(forKey: IManagerRecentTasks.blurPerAppKey) as? [String: Bool]) ?? [:]
        }
    }
}
