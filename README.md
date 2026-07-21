# Usage Monitor

A personal menu-bar / system-tray app that shows remaining usage for
**Claude Pro** and **ChatGPT Plus / Codex**.

- **macOS** — Swift + SwiftUI (`MenuBarExtra` + `WKWebView`) — *built and working*
- **Windows** — C# + WinForms (`NotifyIcon` + `WebView2`) — *compiles; not yet run on real hardware*

Personal use only — it reads your own logged-in sessions. It is **not** built for
distribution (it relies on unofficial internal endpoints and your own cookies).

## How it works

Both platforms use the same trick:

1. You **log in once** in an embedded browser window (you type the password, never the app).
2. Cookies persist in the app's own browser profile.
3. Usage is fetched silently by running `fetch()` *inside* the authenticated page,
   so every request is same-origin and correctly signed.
4. A timer auto-refreshes (5 / 10 / 30 / 60 min).

| Concern | macOS | Windows |
|---|---|---|
| Embedded browser | `WKWebView` | `WebView2` |
| Persistent cookies | `WKWebsiteDataStore.default()` | WebView2 `UserDataFolder` |
| Run JS, get result | `callAsyncJavaScript` | `ExecuteScriptAsync` + `postMessage` |
| Tray UI | `MenuBarExtra` | `NotifyIcon` |
| Log file | `~/Library/Logs/UsageMonitor/usagemonitor.log` (0600) | `%LOCALAPPDATA%\UsageMonitor\usagemonitor.log` |

## Build & run

### macOS
```bash
./scripts/make_app.sh release
open build/UsageMonitor.app
```
Development: `swift build && swift run`

### Windows
```powershell
cd windows
dotnet build -c Release
dotnet run -c Release
```
Requires the **WebView2 runtime** (preinstalled on Windows 11; on Windows 10 grab
the Evergreen runtime from Microsoft).

## Status

| Piece | macOS | Windows |
|-------|-------|---------|
| Tray/menu UI, rows, auto-refresh | ✅ | ✅ (compiles) |
| Persistent login via embedded browser | ✅ | ✅ (compiles) |
| **ChatGPT / Codex real usage** | ✅ **working** | ✅ (same logic, untested) |
| **Claude Pro real usage** | ✅ **working** | ✅ (same logic, untested) |

## Endpoints

All endpoint/parsing logic is isolated in **one file per platform**:
`Sources/UsageMonitor/Providers.swift` and `windows/Providers.cs`.

### ChatGPT / Codex — verified
`/backend-api/*` rejects cookies alone (401). The web app first reads a bearer
token, then calls the Codex ("wham") usage endpoint:

1. `GET /api/auth/session` → `{ "accessToken": "..." }`
2. `GET /backend-api/wham/usage` with `Authorization: Bearer <token>`

Response shape:
```jsonc
{
  "plan_type": "plus",
  "rate_limit": {
    "primary_window":   { "used_percent": 0, "limit_window_seconds": 604800,
                          "reset_at": 1785086891 },
    "secondary_window": null   // the 5-hour window, once there's recent activity
  },
  "credits": { "has_credits": false, "balance": "0" }
}
```
`limit_window_seconds`: `18000` = 5-hour, `604800` = weekly.

### Claude — verified
1. `GET /api/organizations` → `[{ "uuid": "<org-id>", ... }]`
2. `GET /api/organizations/<org-id>/usage`

Response shape:
```jsonc
{
  "five_hour":  { "utilization": 5.0,  "resets_at": "2026-07-21T17:09:59.565625+00:00" },
  "seven_day":  { "utilization": 33.0, "resets_at": "2026-07-23T22:59:59.565644+00:00" },
  "seven_day_opus": null,        // model-specific windows, null when unused
  "extra_usage": {               // NOT a rate-limit window — a spend meter
    "is_enabled": true, "monthly_limit": 3000,
    "used_credits": 2539.0, "utilization": 84.6, "decimal_places": 2
  }
}
```

Two gotchas worth knowing:
- Any top-level object with a `utilization` field is treated as a window, so
  model-specific windows appear automatically. **`extra_usage` is excluded on
  purpose** — it's pay-as-you-go credit spend, and left in it would hijack the
  headline (85% credits vs. the real 33% weekly limit).
- `resets_at` uses **6-digit fractional seconds**, which `ISO8601DateFormatter`
  rejects by default; the parser falls back to stripping them.

## Discovering endpoints

1. Open the site logged-in, DevTools → **Network** → filter **Fetch/XHR**.
2. Open the surface that displays usage; find the request whose **Response**
   contains the real numbers (not a `pageConfigs`-style feature flag).
3. Map its fields onto `UsageSnapshot` in the platform's `Providers` file.

Everything downstream (UI, colors, refresh) consumes `UsageSnapshot`, so only
that one file changes.

## Security notes

The app holds live session cookies and (for ChatGPT) a bearer access token, so
a few things are deliberate and should stay that way:

- **Injected JS runs in an isolated content world** (`.defaultClient` on macOS).
  Page scripts cannot read the arguments we pass in — which include the bearer
  token — or hook the `fetch` we call. Never switch this back to `.page`.
- **Auth responses are never logged.** The redaction decision is made *before*
  any log statement, including the malformed-result branch, so there is no path
  that writes the token to disk.
- **The log lives in a user-private directory** (`0700` dir, `0600` file), not
  `/tmp`. `/tmp` is world-writable — a pre-planted symlink would have redirected
  our appends to an arbitrary user-owned file — and world-readable, while the
  log contains account emails. It is also size-capped.
- **The Windows JS→native channel is authenticated** with a per-call nonce plus
  an origin check, so unsolicited `postMessage` traffic from the page cannot be
  accepted as a fetch result.

Residual risks, accepted by design: the embedded browser profile stores
long-lived auth cookies on disk (same posture as a real browser profile), and
the log retains account emails — both readable by anything already running as
your user. WebView2 has no true isolated-world equivalent, so the Windows nonce
reduces but does not fully eliminate a compromised-page spoofing scenario.
