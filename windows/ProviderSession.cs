using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace UsageMonitorWin;

/// <summary>
/// Owns one WebView2 per provider, on that provider's origin, backed by a
/// persistent user-data folder. Login happens once in a visible window;
/// afterwards usage is fetched silently by running fetch() inside the
/// authenticated page. (Windows counterpart of ProviderSession.swift.)
/// </summary>
public sealed class ProviderSession : IDisposable
{
    public ProviderId Provider { get; }

    /// <summary>Raised after the user closes the login window, so we can refresh.</summary>
    public event Action? LoginWindowClosed;

    private readonly Form _host;
    private readonly WebView2 _web;
    private bool _initialized;

    public ProviderSession(ProviderId provider)
    {
        Provider = provider;

        _web = new WebView2 { Dock = DockStyle.Fill };
        _host = new Form
        {
            Text = $"Log in — {provider.DisplayName()}",
            Width = 520,
            Height = 700,
            StartPosition = FormStartPosition.CenterScreen,
            ShowInTaskbar = true
        };
        _host.Controls.Add(_web);

        // Keep the WebView alive across logins: hide instead of destroying.
        _host.FormClosing += (_, e) =>
        {
            if (e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                _host.Hide();
                LoginWindowClosed?.Invoke();
            }
        };
    }

    private async Task EnsureInitializedAsync()
    {
        if (_initialized) return;

        var env = await CoreWebView2Environment.CreateAsync(
            browserExecutableFolder: null,
            userDataFolder: Provider.UserDataFolder());
        await _web.EnsureCoreWebView2Async(env);
        _initialized = true;
    }

    // MARK: - Login

    public async Task ShowLoginAsync()
    {
        await EnsureInitializedAsync();
        _web.CoreWebView2.Navigate(Provider.LoginUrl());
        _host.Show();
        _host.BringToFront();
        _host.Activate();
    }

    // MARK: - Fetch

    /// <summary>
    /// Navigate to the provider origin (using stored cookies) then run a
    /// same-origin fetch of <paramref name="path"/>, returning the body.
    /// </summary>
    public async Task<string> FetchJsonAsync(
        string path,
        IReadOnlyDictionary<string, string>? extraHeaders = null)
    {
        await EnsureInitializedAsync();
        await EnsureLoadedAsync(Provider.BaseUrl());

        var headersJson = JsonSerializer.Serialize(
            extraHeaders ?? new Dictionary<string, string>());
        var pathJson = JsonSerializer.Serialize(path);

        // A per-call nonce lets us reject unsolicited postMessage traffic from
        // the page, which would otherwise be accepted as our fetch result.
        var nonce = Guid.NewGuid().ToString("N");
        var nonceJson = JsonSerializer.Serialize(nonce);

        var js = $$"""
        (async () => {
          const n = {{nonceJson}};
          try {
            const r = await fetch({{pathJson}}, { credentials: 'include', headers: {{headersJson}} });
            const b = await r.text();
            window.chrome.webview.postMessage(JSON.stringify({ nonce: n, status: r.status, body: b }));
          } catch (e) {
            window.chrome.webview.postMessage(JSON.stringify({ nonce: n, status: -1, body: String(e) }));
          }
        })();
        """;

        var raw = await RunAndAwaitMessageAsync(js, nonce, TimeSpan.FromSeconds(30));

        using var doc = JsonDocument.Parse(raw);
        var status = doc.RootElement.GetProperty("status").GetInt32();
        var body = doc.RootElement.GetProperty("body").GetString() ?? "";

        Log.Write($"[{Provider}] HTTP {status}, body {body.Length} bytes");

        if (status is 401 or 403) throw new NotAuthenticatedException();
        if (status is < 200 or >= 300) throw new InvalidOperationException($"HTTP {status}");
        return body;
    }

    /// <summary>
    /// WebView2's ExecuteScriptAsync does not await promises, so the script
    /// posts its result back via window.chrome.webview.postMessage instead.
    /// </summary>
    private async Task<string> RunAndAwaitMessageAsync(string js, string nonce, TimeSpan timeout)
    {
        var tcs = new TaskCompletionSource<string>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var expectedHost = new Uri(Provider.BaseUrl()).Host;

        void Handler(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
        {
            try
            {
                // Only accept messages from the provider origin...
                if (!Uri.TryCreate(e.Source, UriKind.Absolute, out var src)
                    || !string.Equals(src.Host, expectedHost, StringComparison.OrdinalIgnoreCase))
                    return;

                var raw = e.TryGetWebMessageAsString();
                using var doc = JsonDocument.Parse(raw);

                // ...and only the reply carrying this call's nonce.
                if (!doc.RootElement.TryGetProperty("nonce", out var n)
                    || !string.Equals(n.GetString(), nonce, StringComparison.Ordinal))
                    return;

                tcs.TrySetResult(raw);
            }
            catch
            {
                // Malformed chatter from the page — ignore, let the timeout rule.
            }
        }

        _web.CoreWebView2.WebMessageReceived += Handler;
        try
        {
            await _web.CoreWebView2.ExecuteScriptAsync(js);
            var completed = await Task.WhenAny(tcs.Task, Task.Delay(timeout));
            if (completed != tcs.Task)
                throw new TimeoutException("Timed out waiting for fetch result");
            return await tcs.Task;
        }
        finally
        {
            _web.CoreWebView2.WebMessageReceived -= Handler;
        }
    }

    /// <summary>Load <paramref name="url"/> if we're not already there, and wait for it.</summary>
    private async Task EnsureLoadedAsync(string url)
    {
        var target = new Uri(url);
        var current = _web.CoreWebView2.Source;

        if (!string.IsNullOrEmpty(current)
            && Uri.TryCreate(current, UriKind.Absolute, out var cur)
            && cur.Host == target.Host)
        {
            return;
        }

        var tcs = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);

        void Handler(object? sender, CoreWebView2NavigationCompletedEventArgs e)
            => tcs.TrySetResult(e.IsSuccess);

        _web.CoreWebView2.NavigationCompleted += Handler;
        try
        {
            Log.Write($"[{Provider}] navigating to {url}");
            _web.CoreWebView2.Navigate(url);
            var completed = await Task.WhenAny(tcs.Task, Task.Delay(TimeSpan.FromSeconds(30)));
            if (completed != tcs.Task)
                throw new TimeoutException($"Timed out loading {url}");
        }
        finally
        {
            _web.CoreWebView2.NavigationCompleted -= Handler;
        }
    }

    public void Dispose()
    {
        _web.Dispose();
        _host.Dispose();
    }
}
