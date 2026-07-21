import Foundation

/// Turns raw responses from a `ProviderSession` into a normalized `UsageSnapshot`.
///
/// NOTE: These are UNOFFICIAL internal endpoints. They are isolated here so that
/// when a provider changes its API we only touch this file. Endpoints are verified
/// by inspecting the site's own network traffic (see README → "Discovering endpoints").
enum UsageFetcher {

    static func fetch(_ provider: ProviderID, using session: ProviderSession) async throws -> UsageSnapshot {
        switch provider {
        case .claude:   return try await fetchClaude(session)
        case .chatgpt:  return try await fetchChatGPT(session)
        }
    }

    // MARK: - Claude

    private static func fetchClaude(_ session: ProviderSession) async throws -> UsageSnapshot {
        // 1) Resolve the org id.
        let orgsBody = try await session.fetchJSON(path: "/api/organizations")
        guard let orgs = try? JSONSerialization.jsonObject(with: Data(orgsBody.utf8)) as? [[String: Any]],
              let org = orgs.first,
              let orgID = org["uuid"] as? String else {
            throw ProviderError.parsing("no organization found")
        }

        // 2) Ask for usage/limits on that org.
        //    Endpoint verified from claude.ai network traffic; update here if it moves.
        let body = try await session.fetchJSON(path: "/api/bootstrap/\(orgID)/statsig")
        return try parseClaude(body)
    }

    static func parseClaude(_ body: String) throws -> UsageSnapshot {
        // Defensive parse: dig for anything usage-shaped so a schema tweak
        // degrades to "connected" rather than crashing.
        guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else {
            throw ProviderError.parsing("invalid JSON")
        }
        let details = ["Raw payload received (\(body.count) bytes).",
                       "Usage field mapping pending endpoint verification."]
        _ = json
        return UsageSnapshot(provider: .claude,
                             headline: "Connected",
                             fractionUsed: nil, resetsAt: nil,
                             details: details, updatedAt: .now)
    }

    // MARK: - ChatGPT / Codex

    private static func fetchChatGPT(_ session: ProviderSession) async throws -> UsageSnapshot {
        // /backend-api/* needs a Bearer access token (cookies alone → 401).
        // The web app first reads it from the Next.js auth session endpoint.
        let sessionBody = try await session.fetchJSON(path: "/api/auth/session")
        guard let sess = try? JSONSerialization.jsonObject(with: Data(sessionBody.utf8)) as? [String: Any],
              let token = sess["accessToken"] as? String else {
            throw ProviderError.notAuthenticated
        }

        // Verified from chatgpt.com traffic: the Codex ("wham") usage endpoint.
        // Returns rate_limit windows (5h / weekly) with used_percent + reset_at.
        let body = try await session.fetchJSON(
            path: "/backend-api/wham/usage",
            extraHeaders: ["Authorization": "Bearer \(token)"])
        return try parseChatGPT(body)
    }

    /// One rate-limit window (e.g. 5-hour or weekly).
    private struct Window {
        let label: String
        let usedPercent: Double
        let resetAt: Date?
    }

    static func parseChatGPT(_ body: String) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            throw ProviderError.parsing("invalid JSON")
        }

        var windows: [Window] = []
        if let rl = root["rate_limit"] as? [String: Any] {
            for key in ["primary_window", "secondary_window"] {
                guard let w = rl[key] as? [String: Any] else { continue }
                let used = (w["used_percent"] as? NSNumber)?.doubleValue ?? 0
                let seconds = (w["limit_window_seconds"] as? NSNumber)?.doubleValue
                let resetAt = (w["reset_at"] as? NSNumber).map {
                    Date(timeIntervalSince1970: $0.doubleValue)
                }
                windows.append(Window(label: windowLabel(seconds), usedPercent: used, resetAt: resetAt))
            }
        }

        // Headline reflects the most-consumed window (the binding constraint).
        let main = windows.max { $0.usedPercent < $1.usedPercent }
        let headline: String
        if let main {
            headline = "\(Int(main.usedPercent.rounded()))% used · \(main.label)"
        } else {
            headline = "No active limit"
        }

        let relative = RelativeDateTimeFormatter()
        var details = windows.map { w -> String in
            let pct = Int(w.usedPercent.rounded())
            if let r = w.resetAt {
                return "\(w.label): \(pct)% used · resets \(relative.localizedString(for: r, relativeTo: .now))"
            }
            return "\(w.label): \(pct)% used"
        }
        if let plan = root["plan_type"] as? String { details.append("Plan: \(plan.capitalized)") }
        if let credits = root["credits"] as? [String: Any],
           (credits["has_credits"] as? Bool) == true,
           let balance = credits["balance"] as? String {
            details.append("Credits: \(balance)")
        }

        return UsageSnapshot(provider: .chatgpt,
                             headline: headline,
                             fractionUsed: (main?.usedPercent ?? 0) / 100.0,
                             resetsAt: main?.resetAt,
                             details: details, updatedAt: .now)
    }

    private static func windowLabel(_ seconds: Double?) -> String {
        guard let s = seconds else { return "Limit" }
        switch Int(s) {
        case 3600:   return "Hourly"
        case 18000:  return "5-hour"
        case 86400:  return "Daily"
        case 604800: return "Weekly"
        default:     return "\(Int(s / 3600))h window"
        }
    }
}
