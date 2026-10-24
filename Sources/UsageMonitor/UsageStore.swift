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
    /// Providers with a refresh in flight. The timer, the toolbar button and a
    /// closing login window can all fire at once; without this they piled up
    /// (six concurrent fetches in one second, in the log).
    private var inFlight: Set<ProviderID> = []

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
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Providers are refreshed side by side: they own separate sessions, and
        // running them in sequence meant one stalled provider also held up the
        // other, leaving the whole menu stale.
        let tasks = ProviderID.allCases.map { p in
            Task { @MainActor [weak self] in await self?.refresh(p) }
        }
        for task in tasks {
            await task.value
        }
    }

    func refresh(_ p: ProviderID) async {
        guard let session = sessions[p] else { return }
        guard !inFlight.contains(p) else {
            Log.write("refresh(\(p.rawValue)) skipped — already in flight")
            return
        }
        inFlight.insert(p)
        defer { inFlight.remove(p) }

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
        let fractions = ProviderID.allCases.compactMap { p -> Double? in
            // A provider that is erroring has no current reading, so its last
            // good fraction must not keep standing in for the live number.
            errors[p] == nil ? snapshots[p]?.fractionUsed : nil
        }
        guard let worst = fractions.max() else { return "—" }
        return "\(Int(worst * 100))%"
    }
}
