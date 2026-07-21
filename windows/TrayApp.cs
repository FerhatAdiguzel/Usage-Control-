using System.Drawing;

namespace UsageMonitorWin;

/// <summary>
/// System-tray equivalent of the macOS MenuBarExtra: holds a session per
/// provider, the latest snapshots, and the auto-refresh timer.
/// </summary>
public sealed class TrayAppContext : ApplicationContext
{
    private readonly NotifyIcon _icon;
    private readonly Dictionary<ProviderId, ProviderSession> _sessions = new();
    private readonly Dictionary<ProviderId, UsageSnapshot> _snapshots = new();
    private readonly Dictionary<ProviderId, string> _errors = new();
    private readonly System.Windows.Forms.Timer _timer = new();

    private int _refreshMinutes = 10;
    private bool _isRefreshing;

    private static readonly ProviderId[] AllProviders =
        [ProviderId.Claude, ProviderId.ChatGpt];

    public TrayAppContext()
    {
        foreach (var p in AllProviders)
        {
            var session = new ProviderSession(p);
            var captured = p;
            session.LoginWindowClosed += async () => await RefreshAsync(captured);
            _sessions[p] = session;
            _snapshots[p] = UsageSnapshot.Placeholder(p);
        }

        _icon = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Visible = true,
            Text = "Usage Monitor"
        };
        RebuildMenu();

        _timer.Interval = _refreshMinutes * 60 * 1000;
        _timer.Tick += async (_, _) => await RefreshAllAsync();
        _timer.Start();

        // Initial pull shortly after launch (cookies from a prior run persist).
        _ = InitialRefreshAsync();
    }

    private async Task InitialRefreshAsync()
    {
        await Task.Delay(TimeSpan.FromSeconds(2));
        await RefreshAllAsync();
    }

    // MARK: - Refresh

    private async Task RefreshAllAsync()
    {
        if (_isRefreshing) return;
        _isRefreshing = true;
        try
        {
            foreach (var p in AllProviders) await RefreshAsync(p);
        }
        finally
        {
            _isRefreshing = false;
        }
    }

    private async Task RefreshAsync(ProviderId p)
    {
        Log.Write($"refresh({p}) start");
        try
        {
            var snap = await UsageFetcher.FetchAsync(p, _sessions[p]);
            _snapshots[p] = snap;
            _errors.Remove(p);
            Log.Write($"refresh({p}) OK: {snap.Headline}");
        }
        catch (Exception ex)
        {
            _errors[p] = ex is NotAuthenticatedException ? "Not logged in" : ex.Message;
            Log.Write($"refresh({p}) ERROR: {ex.Message}");
        }
        RebuildMenu();
    }

    // MARK: - Menu

    private void RebuildMenu()
    {
        var menu = new ContextMenuStrip();

        foreach (var p in AllProviders)
        {
            var snap = _snapshots[p];
            var hasError = _errors.TryGetValue(p, out var err);

            menu.Items.Add(new ToolStripMenuItem(p.DisplayName()) { Enabled = false });
            menu.Items.Add(new ToolStripMenuItem(
                hasError ? $"   ⚠ {err}" : $"   {snap.Headline}")
            { Enabled = false });

            if (!hasError)
            {
                foreach (var line in snap.Details)
                    menu.Items.Add(new ToolStripMenuItem($"   {line}") { Enabled = false });
            }

            var login = new ToolStripMenuItem("   Log in…");
            var captured = p;
            login.Click += async (_, _) =>
            {
                // Awaited with a guard: an unobserved exception here would
                // otherwise tear down the process.
                try { await _sessions[captured].ShowLoginAsync(); }
                catch (Exception ex) { Log.Write($"login({captured}) ERROR: {ex.Message}"); }
            };
            menu.Items.Add(login);
            menu.Items.Add(new ToolStripSeparator());
        }

        var refresh = new ToolStripMenuItem("Refresh now");
        refresh.Click += async (_, _) => await RefreshAllAsync();
        menu.Items.Add(refresh);

        var interval = new ToolStripMenuItem("Auto-refresh");
        foreach (var minutes in new[] { 5, 10, 30, 60 })
        {
            var item = new ToolStripMenuItem($"{minutes} min")
            {
                Checked = minutes == _refreshMinutes
            };
            var captured = minutes;
            item.Click += (_, _) =>
            {
                _refreshMinutes = captured;
                _timer.Interval = captured * 60 * 1000;
                RebuildMenu();
            };
            interval.DropDownItems.Add(item);
        }
        menu.Items.Add(interval);

        menu.Items.Add(new ToolStripSeparator());
        var quit = new ToolStripMenuItem("Quit");
        quit.Click += (_, _) => ExitApp();
        menu.Items.Add(quit);

        _icon.ContextMenuStrip?.Dispose();
        _icon.ContextMenuStrip = menu;

        // Tooltip is capped at 63 chars by Windows.
        var worst = AllProviders
            .Select(p => _snapshots[p].FractionUsed)
            .Where(f => f.HasValue)
            .Select(f => f!.Value)
            .DefaultIfEmpty(0)
            .Max();
        var tip = $"Usage Monitor — {Math.Round(worst * 100)}% used";
        _icon.Text = tip.Length > 63 ? tip[..63] : tip;
    }

    private void ExitApp()
    {
        _timer.Stop();
        _icon.Visible = false;
        _icon.Dispose();
        foreach (var s in _sessions.Values) s.Dispose();
        ExitThread();
    }
}
