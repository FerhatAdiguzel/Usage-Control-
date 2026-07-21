import Foundation

/// Identifies a subscription we track.
enum ProviderID: String, CaseIterable, Identifiable, Codable {
    case claude
    case chatgpt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Pro"
        case .chatgpt: return "ChatGPT / Codex"
        }
    }

    /// Origin the WebView lives on so fetches are same-origin + cookie-authenticated.
    var baseURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai")!
        case .chatgpt: return URL(string: "https://chatgpt.com")!
        }
    }

    /// URL we open for the interactive one-time login.
    var loginURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/login")!
        case .chatgpt: return URL(string: "https://chatgpt.com/")!
        }
    }
}

/// A normalized usage reading shown in the menu.
struct UsageSnapshot: Codable, Equatable {
    var provider: ProviderID
    /// Human headline, e.g. "42% used" or "3h 12m to reset".
    var headline: String
    /// 0.0...1.0 fraction of the limit consumed, if known.
    var fractionUsed: Double?
    /// When the current window resets, if known.
    var resetsAt: Date?
    /// Extra lines for the detail view.
    var details: [String]
    var updatedAt: Date

    static func placeholder(_ p: ProviderID) -> UsageSnapshot {
        UsageSnapshot(provider: p, headline: "Not connected",
                      fractionUsed: nil, resetsAt: nil,
                      details: ["Log in to start tracking."], updatedAt: .now)
    }
}

enum ProviderError: LocalizedError {
    case notAuthenticated
    case badResponse(String)
    case parsing(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not logged in"
        case .badResponse(let s): return "Request failed: \(s)"
        case .parsing(let s): return "Could not read usage: \(s)"
        }
    }
}
