import SwiftUI
import UIKit

/// 日志面板（沙盒容器 → 设置 → 右上角「日志」）.
///
/// 只做两件事：看最近日志、告诉你在 SSH 里怎么读到同一份日志。
/// **不在这里启停 SSH** —— SSH 有自己的页面（更多 → 小型 SSH 服务），
/// 这里只显示它当前是否在跑、连上后用哪条命令读日志.
///
/// 宿主类由 LC 侧（LiveContainerSwiftUI 框架）用 `NSClassFromString("TDLogPanelHost")`
/// 反射取得 —— 框架不能 import 主 App 的类型.
@MainActor
struct TDLogPanelView: View {
    @ObservedObject private var ssh = SSHServerService.shared
    @State private var logText = ""

    var body: some View {
        List {
            Section {
                ScrollView {
                    Text(logText.isEmpty ? "（暂无日志）" : logText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 320)
            } header: {
                HStack {
                    Text("最近 300 行")
                    Spacer()
                    Button("刷新") { reload() }
                        .font(.footnote)
                }
            } footer: {
                Text("日志文件与 SSH `logs` 命令读取的是同一份（LoginLogger）.")
            }

            Section {
                LabeledContent("SSH 服务", value: ssh.isRunning ? "运行中" : "未启动")
                if ssh.isRunning {
                    LabeledContent("地址", value: "\(ssh.lanIP):\(ssh.port)")
                    Text("ssh \(ssh.username)@\(ssh.lanIP) -p \(ssh.port)")
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Text("连上后输入 `logs 200` 读取同一份日志；`help` 看全部诊断命令.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    Text("到「更多 → 小型 SSH 服务」启动后即可远程读日志.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("远程读取")
            }
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("关闭") {
                    NotificationCenter.default.post(
                        name: Notification.Name("TDLogPanelCloseRequested"), object: nil)
                }
            }
        }
        .task {
            reload()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                reload()
            }
        }
    }

    private func reload() {
        let lines = LoginLogger.shared.fullLog().components(separatedBy: "\n")
        logText = lines.suffix(300).joined(separator: "\n")
    }
}

/// 供 LiveContainerSwiftUI 框架用 `NSClassFromString("TDLogPanelHost")` 反射调用.
@objc(TDLogPanelHost)
@MainActor
public final class TDLogPanelHost: NSObject {
    @objc public static func makeViewController() -> UIViewController {
        UIHostingController(rootView: NavigationStack { TDLogPanelView() })
    }
}