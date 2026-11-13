import SwiftUI
import UIKit

/// 日志面板（沙盒容器 → 设置 → 右上角「日志」）.
///
/// 两件事：
/// 1. 直接看最近日志（与 SSH `logs` 命令**同一份** `LoginLogger`，不另开文件）；
/// 2. 一键启停 SSH 服务并给出连接命令，方便电脑侧 `ssh <user>@<IP> -p <port>` 看完整日志.
///
/// 宿主类由 LC 侧（LiveContainerSwiftUI 框架）用 `NSClassFromString("TDLogPanelHost")`
/// 反射取得 —— 框架不能 import 主 App 的类型.
@MainActor
struct TDLogPanelView: View {
    @ObservedObject private var ssh = SSHServerService.shared
    @State private var logText = ""

    private var sshCommand: String {
        "ssh \(ssh.username)@\(ssh.lanIP) -p \(ssh.port)"
    }

    var body: some View {
        List {
            Section {
                LabeledContent("状态", value: ssh.isRunning ? "运行中" : "已停止")
                LabeledContent("地址", value: "\(ssh.lanIP):\(ssh.port)")
                LabeledContent("用户", value: ssh.username)
                if ssh.hasSetPassword {
                    LabeledContent("密码", value: ssh.password)
                } else {
                    Text("尚未设置 SSH 密码：请到「更多 → SSH 调试」设置")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                if let err = ssh.lastError {
                    Text(err).font(.footnote).foregroundColor(.red)
                }
                Button {
                    ssh.isRunning ? ssh.stop() : ssh.start()
                } label: {
                    Label(ssh.isRunning ? "停止 SSH" : "启动 SSH",
                          systemImage: ssh.isRunning ? "stop.circle" : "play.circle")
                }
                .disabled(!ssh.hasSetPassword)
                Button {
                    UIPasteboard.general.string = sshCommand
                } label: {
                    Label("复制连接命令", systemImage: "doc.on.doc")
                }
                .disabled(!ssh.isRunning)
            } header: {
                Text("SSH（电脑侧看日志）")
            } footer: {
                Text(sshCommand).font(.footnote.monospaced()).textSelection(.enabled)
            }

            Section {
                ScrollView {
                    Text(logText.isEmpty ? "（暂无日志）" : logText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 260)
            } header: {
                HStack {
                    Text("最近日志")
                    Spacer()
                    Button("刷新") { reload() }
                        .font(.footnote)
                }
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