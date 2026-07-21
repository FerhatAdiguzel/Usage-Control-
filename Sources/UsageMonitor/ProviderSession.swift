import Foundation
import WebKit
import AppKit

/// Owns one WKWebView per provider, on that provider's origin, backed by a
/// persistent cookie store. Login happens once in a visible window; afterwards
/// usage is fetched silently by running `fetch()` inside the authenticated page.
@MainActor
final class ProviderSession: NSObject, WKNavigationDelegate, NSWindowDelegate {
    let provider: ProviderID
    private let webView: WKWebView
    private var loginWindow: NSWindow?

    /// Called after the user closes the login window (so we can refresh).
    var onLoginWindowClosed: (() -> Void)?

    // Continuation resolved by the navigation delegate on load finish/fail.
    private var navContinuation: CheckedContinuation<Void, Error>?

    init(provider: ProviderID) {
        self.provider = provider

        let config = WKWebViewConfiguration()
        // Standard persistent store — writes cookies to disk under the app's
        // bundle id and survives relaunch. (Cookies are domain-scoped, so both
        // providers sharing one store is fine.) `forIdentifier:` proved
        // unreliable for an ad-hoc-signed app.
        config.websiteDataStore = .default()

        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640),
                                 configuration: config)
        super.init()
        self.webView.navigationDelegate = self
        // A realistic UA reduces the odds of being served a bot-check page.
        self.webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    }

    // MARK: - Login

    func showLogin() {
        let window = loginWindow ?? makeLoginWindow()
        loginWindow = window
        webView.load(URLRequest(url: provider.loginURL))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeLoginWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Log in — \(provider.displayName)"
        window.contentView = webView
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        onLoginWindowClosed?()
    }

    // MARK: - Fetch

    /// Navigate to the provider origin (using stored cookies) then run a
    /// same-origin fetch of `path`, returning the raw response body.
    func fetchJSON(path: String, extraHeaders: [String: String] = [:]) async throws -> String {
        Log.write("[\(provider.rawValue)] fetchJSON \(path) — ensuring \(provider.baseURL.absoluteString) loaded (current=\(webView.url?.absoluteString ?? "nil"))")
        try await ensureLoaded(provider.baseURL)
        Log.write("[\(provider.rawValue)] loaded, now at \(webView.url?.absoluteString ?? "nil")")

        // Return a plain JS object so WebKit bridges it to an NSDictionary.
        let js = """
        const resp = await fetch(path, {
            credentials: 'include',
            headers: headers
        });
        const body = await resp.text();
        return { status: resp.status, body: body };
        """
        let result = try await webView.callAsyncJavaScript(
            js,
            arguments: ["path": path, "headers": extraHeaders],
            contentWorld: .page)

        guard let dict = result as? [String: Any],
              let status = (dict["status"] as? NSNumber)?.intValue,
              let body = dict["body"] as? String else {
            Log.write("[\(provider.rawValue)] BAD JS result: \(String(describing: result))")
            throw ProviderError.badResponse("unexpected JS result")
        }
        // Never log auth payloads — that response carries the access token.
        if path.contains("auth/session") || path.contains("oauth") {
            Log.write("[\(provider.rawValue)] HTTP \(status), body \(body.count) bytes [redacted]")
        } else {
            Log.write("[\(provider.rawValue)] HTTP \(status), body \(body.count) bytes: \(body.prefix(160))")
        }
        if status == 401 || status == 403 {
            throw ProviderError.notAuthenticated
        }
        guard (200..<300).contains(status) else {
            throw ProviderError.badResponse("HTTP \(status)")
        }
        return body
    }

    /// Load `url` if we're not already there, and wait for the load to finish.
    private func ensureLoaded(_ url: URL) async throws {
        if let current = webView.url,
           current.host == url.host,
           !webView.isLoading {
            return
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            navContinuation = cont
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navContinuation?.resume()
        navContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navContinuation?.resume(throwing: error)
        navContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navContinuation?.resume(throwing: error)
        navContinuation = nil
    }
}
