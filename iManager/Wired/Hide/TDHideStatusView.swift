import SwiftUI

struct TDHideStatusView: View {
    struct LayerRow: Identifiable {
        let id: String
        let icon: String
        let title: String
        let state: State

        enum State {
            case active
            case builtIn
            case partial
            case off
        }
    }

    @State private var rows: [LayerRow] = []

    var body: some View {
        List {
            Section {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        Image(systemName: row.icon)
                            .foregroundColor(color(for: row.state))
                            .frame(width: 22)
                        Text(row.title)
                        Spacer()
                        badge(row.state)
                    }
                }
            }
        }
        .navigationTitle("隐藏状态")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            reload()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                reload()
            }
        }
    }

    private func badge(_ state: LayerRow.State) -> some View {
        Text(label(for: state))
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color(for: state).opacity(0.18))
            .foregroundColor(color(for: state))
            .clipShape(Capsule())
    }

    private func color(for state: LayerRow.State) -> Color {
        switch state {
        case .active: return .green
        case .builtIn: return .blue
        case .partial: return .orange
        case .off: return .gray
        }
    }

    private func label(for state: LayerRow.State) -> String {
        switch state {
        case .active: return "已生效"
        case .builtIn: return "恒开"
        case .partial: return "部分开启"
        case .off: return "未开启"
        }
    }

    private func reload() {
        rows = TDHideStatusProvider.currentRows()
    }
}
