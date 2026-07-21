import SwiftUI

struct MenuContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Usage Monitor").font(.headline)
                Spacer()
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    store.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }

            ForEach(ProviderID.allCases) { provider in
                ProviderRow(store: store, provider: provider)
                if provider != ProviderID.allCases.last {
                    Divider()
                }
            }

            Divider()

            HStack {
                Text("Auto-refresh")
                Spacer()
                Picker("", selection: $store.refreshMinutes) {
                    Text("5 min").tag(5)
                    Text("10 min").tag(10)
                    Text("30 min").tag(30)
                    Text("60 min").tag(60)
                }
                .labelsHidden()
                .frame(width: 100)
            }
            .font(.caption)

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct ProviderRow: View {
    @ObservedObject var store: UsageStore
    let provider: ProviderID

    var body: some View {
        let snap = store.snapshots[provider] ?? .placeholder(provider)
        let err = store.errors[provider]

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider.displayName).font(.subheadline).bold()
                Spacer()
                Button("Log in") { store.login(provider) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            if let err {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(snap.headline)
                    .font(.title3).bold()
                    .foregroundStyle(color(for: snap.fractionUsed))

                if let frac = snap.fractionUsed {
                    ProgressView(value: frac)
                        .tint(color(for: frac))
                }
                ForEach(snap.details, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
                if let reset = snap.resetsAt {
                    Text("Resets \(reset, style: .relative)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Updated \(snap.updatedAt, style: .time)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func color(for fraction: Double?) -> Color {
        guard let f = fraction else { return .primary }
        switch f {
        case ..<0.7: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }
}
