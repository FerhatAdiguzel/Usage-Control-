namespace UsageMonitorWin;

/// <summary>Identifies a subscription we track. Mirrors ProviderID in the macOS app.</summary>
public enum ProviderId
{
    Claude,
    ChatGpt
}

public static class ProviderInfo
{
    public static string DisplayName(this ProviderId p) => p switch
    {
        ProviderId.Claude => "Claude Pro",
        ProviderId.ChatGpt => "ChatGPT / Codex",
        _ => p.ToString()
    };

    /// <summary>Origin the WebView lives on so fetches are same-origin + cookie-authenticated.</summary>
    public static string BaseUrl(this ProviderId p) => p switch
    {
        ProviderId.Claude => "https://claude.ai",
        ProviderId.ChatGpt => "https://chatgpt.com",
        _ => throw new ArgumentOutOfRangeException(nameof(p))
    };

    public static string LoginUrl(this ProviderId p) => p switch
    {
        ProviderId.Claude => "https://claude.ai/login",
        ProviderId.ChatGpt => "https://chatgpt.com/",
        _ => throw new ArgumentOutOfRangeException(nameof(p))
    };

    /// <summary>Per-provider folder for persistent cookies.</summary>
    public static string UserDataFolder(this ProviderId p)
    {
        var root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "UsageMonitor", "WebView2", p.ToString());
        Directory.CreateDirectory(root);
        return root;
    }
}

/// <summary>A normalized usage reading shown in the tray menu.</summary>
public sealed record UsageSnapshot(
    ProviderId Provider,
    string Headline,
    double? FractionUsed,
    DateTimeOffset? ResetsAt,
    IReadOnlyList<string> Details,
    DateTimeOffset UpdatedAt)
{
    public static UsageSnapshot Placeholder(ProviderId p) => new(
        p, "Not connected", null, null,
        new[] { "Log in to start tracking." }, DateTimeOffset.Now);
}

public sealed class NotAuthenticatedException : Exception
{
    public NotAuthenticatedException() : base("Not logged in") { }
}
