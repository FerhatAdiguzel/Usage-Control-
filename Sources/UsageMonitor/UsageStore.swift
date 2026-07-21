import Foundation
import SwiftUI

/// Central state: holds a session per provider, the latest snapshots, and the
/// auto-refresh timer.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshots: [ProviderID: UsageSnapshot] = [:]
    @Published private(set) var errors: [ProviderID: String] = [:]
    @Published private(set) var isRefreshing = false
    @Published var refreshMinutes: Int = 10 {
        didSet { restartTimer() }
    }

    private var sessions: [ProviderID: ProviderSession] = [:]
    private var timer: Timer?

    init() {
        for p in ProviderID.allCases {
            let session = ProviderSession(provider: p)
            sessions[p] = session
            snapshots[p] = .placeholder(p)
        }
        // Refresh that provider once its login window is dismissed.
        for p in ProviderID.allCases {
            sessions[p]?.onLoginWindowClosed = { [weak self] in
                Task { @MainActor in await self?.refresh(p) }
            }
        }
        restartTimer()
        // Initial pull shortly after launch (cookies from a prior session persist).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            await refreshAllAsync()
        }
    }

    func session(for p: ProviderID) -> ProviderSession {
        sessions[p]!
    }

    func login(_ p: ProviderID) {
        sessions[p]?.showLogin()
    }

    func refreshAll() {
        Task { await refreshAllAsync() }
    }

    func refreshAllAsync() async {
        isRefreshing = true
        defer { isRefreshing = false }
        for p in ProviderID.allCases {
            await refresh(p)
        }
    }

    func refresh(_ p: ProviderID) async {
        guard let session = sessions[p] else { return }
        Log.write("refresh(\(p.rawValue)) start")
        do {
            let snap = try await UsageFetcher.fetch(p, using: session)
            snapshots[p] = snap
            errors[p] = nil
            Log.write("refresh(\(p.rawValue)) OK: \(snap.headline)")
        } catch {
            errors[p] = error.localizedDescription
            Log.write("refresh(\(p.rawValue)) ERROR: \(error.localizedDescription)")
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(1, refreshMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAllAsync() }
        }
    }

    /// Short status string for the menu bar title.
    var menuBarTitle: String {
        let fractions = ProviderID.allCases.compactMap { snapshots[$0]?.fractionUsed }
        guard let worst = fractions.max() else { return "—" }
        return "\(Int(worst * 100))%"
    }
}
