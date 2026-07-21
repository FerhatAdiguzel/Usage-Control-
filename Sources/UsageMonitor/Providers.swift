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

        // 2) Usage windows for that org. Verified from claude.ai traffic:
        //    { "five_hour": { "utilization": 0-100, "resets_at": ISO8601 }, "seven_day": {...} }
        let body = try await session.fetchJSON(path: "/api/organizations/\(orgID)/usage")
        return try parseClaude(body)
    }

    static func parseClaude(_ body: String) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            throw ProviderError.parsing("invalid JSON")
        }

        // Any top-level object carrying "utilization" is a rate-limit window, so
        // model-specific windows show up without code changes. `extra_usage` is
        // excluded deliberately: it's a spend meter, not a window, and would
        // otherwise hijack the headline.
        var windows: [Window] = []
        for (key, value) in root where key != "extra_usage" {
            guard let w = value as? [String: Any],
                  let util = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
            let resetAt = (w["resets_at"] as? String).flatMap(parseISODate)
            windows.append(Window(label: claudeWindowLabel(key), usedPercent: util, resetAt: resetAt))
        }
        guard !windows.isEmpty else {
            throw ProviderError.parsing("no usage windows in response")
        }
        windows.sort { claudeRank($0.label) < claudeRank($1.label) }

        // Headline reflects the most-consumed window (the binding constraint).
        let main = windows.max { $0.usedPercent < $1.usedPercent }!
        let relative = RelativeDateTimeFormatter()
        var details = windows.map { w -> String in
            let pct = Int(w.usedPercent.rounded())
            if let r = w.resetAt {
                return "\(w.label): \(pct)% used · resets \(relative.localizedString(for: r, relativeTo: .now))"
            }
            return "\(w.label): \(pct)% used"
        }

        // Pay-as-you-go credits that kick in past the plan limits.
        if let extra = root["extra_usage"] as? [String: Any],
           (extra["is_enabled"] as? Bool) == true,
           let util = (extra["utilization"] as? NSNumber)?.doubleValue {
            let places = (extra["decimal_places"] as? NSNumber)?.intValue ?? 2
            let divisor = pow(10.0, Double(places))
            let used = ((extra["used_credits"] as? NSNumber)?.doubleValue ?? 0) / divisor
            let limit = ((extra["monthly_limit"] as? NSNumber)?.doubleValue ?? 0) / divisor
            let code = (extra["currency"] as? String) ?? "USD"
            details.append(String(format: "Extra credits: %d%% used (%@ of %@)",
                                  Int(util.rounded()),
                                  money(used, code), money(limit, code)))
        }

        return UsageSnapshot(provider: .claude,
                             headline: "\(Int(main.usedPercent.rounded()))% used · \(main.label)",
                             fractionUsed: main.usedPercent / 100.0,
                             resetsAt: main.resetAt,
                             details: details, updatedAt: .now)
    }

    private static func money(_ amount: Double, _ code: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        return f.string(from: NSNumber(value: amount)) ?? String(format: "%.2f %@", amount, code)
    }

    private static func claudeWindowLabel(_ key: String) -> String {
        switch key {
        case "five_hour": return "5-hour"
        case "seven_day": return "Weekly"
        case "seven_day_opus": return "Weekly (Opus)"
        default:
            return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func claudeRank(_ label: String) -> Int {
        switch label {
        case "5-hour": return 0
        case "Weekly": return 1
        case "Weekly (Opus)": return 2
        default: return 3
        }
    }

    /// claude.ai emits 6-digit fractional seconds, which the strict parser rejects.
    private static func parseISODate(_ s: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }

        if let frac = s.range(of: #"\.\d+"#, options: .regularExpression) {
            var trimmed = s
            trimmed.removeSubrange(frac)
            return plain.date(from: trimmed)
        }
        return nil
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
