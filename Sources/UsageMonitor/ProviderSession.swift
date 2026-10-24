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
    /// Fires if the navigation never calls back at all, so a refresh can never
    /// hang forever (observed after the machine wakes from sleep).
    private var navWatchdog: Task<Void, Never>?
    /// When the origin was last loaded successfully. A page left sitting for a
    /// long time can be backed by a WebContent process macOS has since killed,
    /// and `callAsyncJavaScript` then fails, so we reload instead of reusing it.
    private var lastLoadedAt: Date?

    /// Tail of the per-session fetch chain. Fetches on one session share a
    /// single WKWebView and a single `navContinuation` slot, so they must not
    /// overlap: a second concurrent fetch used to overwrite the first one's
    /// continuation, leaving it suspended forever.
    private var fetchTail: Task<Void, Never> = Task {}

    private let navTimeout: TimeInterval = 30
    private let jsTimeout: TimeInterval = 30
    private let maxPageAge: TimeInterval = 120

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
        // The login navigation replaces whatever a pending fetch was waiting
        // for, so hand that waiter an error rather than let it be resumed by
        // the login page's own didFinish.
        finishNavigation(.failure(ProviderError.badResponse("navigation superseded by login")))
        lastLoadedAt = nil
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
    ///
    /// Calls are serialized per session: the WKWebView and its navigation
    /// continuation are single-slot resources.
    func fetchJSON(path: String, extraHeaders: [String: String] = [:]) async throws -> String {
        let predecessor = fetchTail
        let work = Task { @MainActor [weak self] () throws -> String in
            _ = await predecessor.value
            guard let self else { throw ProviderError.badResponse("session released") }
            return try await self.runFetch(path: path, extraHeaders: extraHeaders)
        }
        fetchTail = Task { _ = try? await work.value }
        return try await work.value
    }

    /// One fetch attempt, retried once on a transport/JS failure with a forced
    /// reload — a stale page is the common cause and a reload cures it.
    private func runFetch(path: String, extraHeaders: [String: String]) async throws -> String {
        do {
            return try await performFetch(path: path, extraHeaders: extraHeaders)
        } catch let error as ProviderError {
            // Auth answers are real answers; don't retry them.
            switch error {
            case .notAuthenticated, .sessionExpired, .forbidden, .parsing:
                throw error
            case .badResponse:
                break
            }
            Log.write("[\(provider.rawValue)] retrying after: \(error.localizedDescription)")
            lastLoadedAt = nil
            return try await performFetch(path: path, extraHeaders: extraHeaders)
        } catch {
            Log.write("[\(provider.rawValue)] retrying after JS/transport failure")
            lastLoadedAt = nil
            return try await performFetch(path: path, extraHeaders: extraHeaders)
        }
    }

    private func performFetch(path: String, extraHeaders: [String: String]) async throws -> String {
        Log.write("[\(provider.rawValue)] request started")
        try await ensureLoaded(provider.baseURL)
        Log.write("[\(provider.rawValue)] provider origin loaded")

        // Return a plain JS object so WebKit bridges it to an NSDictionary.
        // AbortController caps the request in-page: a `fetch` that never
        // settles used to leave this call — and the whole refresh — suspended.
        let js = """
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), timeoutMs);
        try {
            const resp = await fetch(path, {
                credentials: 'include',
                headers: headers,
                signal: controller.signal
            });
            const body = await resp.text();
            return { status: resp.status, body: body };
        } finally {
            clearTimeout(timer);
        }
        """
        // `.defaultClient` is an isolated content world: page scripts cannot
        // read our arguments (which carry the bearer token) or hook the fetch
        // we call. Cookies still apply — this is still a same-origin request.
        let result = try await withJSWatchdog {
            try await self.webView.callAsyncJavaScript(
                js,
                arguments: ["path": path,
                            "headers": extraHeaders,
                            "timeoutMs": Int(self.jsTimeout * 1000) - 2000],
                contentWorld: .defaultClient)
        }

        guard let dict = result as? [String: Any],
              let status = (dict["status"] as? NSNumber)?.intValue,
              let body = dict["body"] as? String else {
            // The raw result carries the response body — and therefore possibly
            // the access token — so it is never written out.
            Log.write("[\(provider.rawValue)] BAD JS result [content omitted]")
            throw ProviderError.badResponse("unexpected JS result")
        }
        // Never log authenticated response bodies, endpoint identifiers, or URLs.
        Log.write("[\(provider.rawValue)] HTTP \(status), body \(body.utf8.count) bytes [content omitted]")
        // 401 and 403 mean different things here and used to collapse into one
        // misleading "Not logged in": 401 is an expired/rejected session, while
        // 403 on an endpoint the cookies should cover points at a client/bot
        // check rather than a missing login.
        if status == 401 { throw ProviderError.sessionExpired }
        if status == 403 { throw ProviderError.forbidden }
        guard (200..<300).contains(status) else {
            throw ProviderError.badResponse("HTTP \(status)")
        }
        return body
    }

    /// Runs `body`, reloading the page if it has not come back in time. The
    /// reload tears down the pending promise, so the await below fails instead
    /// of hanging — WebKit gives us no way to cancel the call directly.
    private func withJSWatchdog<T>(_ body: () async throws -> T) async throws -> T {
        let deadline = jsTimeout
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(deadline))
            guard let self, !Task.isCancelled else { return }
            Log.write("[\(self.provider.rawValue)] JS call timed out — reloading page")
            self.lastLoadedAt = nil
            self.webView.stopLoading()
            self.webView.reload()
        }
        defer { watchdog.cancel() }
        return try await body()
    }

    /// Load `url` if we're not already there on a recent, still-live page, and
    /// wait for the load to finish.
    private func ensureLoaded(_ url: URL) async throws {
        if let current = webView.url,
           current.host == url.host,
           !webView.isLoading,
           let loaded = lastLoadedAt,
           Date().timeIntervalSince(loaded) < maxPageAge {
            return
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Never drop a waiter on the floor: that leak is what left refreshes
            // logging "provider origin loaded" and then nothing at all.
            if let stale = navContinuation {
                navContinuation = nil
                stale.resume(throwing: ProviderError.badResponse("navigation superseded"))
            }
            navWatchdog?.cancel()
            navContinuation = cont
            let deadline = navTimeout
            navWatchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(deadline))
                guard let self, !Task.isCancelled else { return }
                Log.write("[\(self.provider.rawValue)] navigation timed out")
                self.webView.stopLoading()
                self.finishNavigation(.failure(ProviderError.badResponse("navigation timed out")))
            }
            webView.load(URLRequest(url: url))
        }
    }

    /// Resumes the pending navigation waiter exactly once.
    private func finishNavigation(_ result: Result<Void, Error>) {
        navWatchdog?.cancel()
        navWatchdog = nil
        guard let cont = navContinuation else { return }
        navContinuation = nil
        cont.resume(with: result)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastLoadedAt = Date()
        finishNavigation(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        lastLoadedAt = nil
        finishNavigation(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        lastLoadedAt = nil
        finishNavigation(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page is gone; anything waiting on it will never be called back.
        Log.write("[\(provider.rawValue)] web content process terminated")
        lastLoadedAt = nil
        finishNavigation(.failure(ProviderError.badResponse("web content process terminated")))
    }
}
