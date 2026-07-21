using System.Text.Json;

namespace UsageMonitorWin;

/// <summary>
/// Turns raw responses from a ProviderSession into a normalized UsageSnapshot.
///
/// NOTE: These are UNOFFICIAL internal endpoints, isolated here so that when a
/// provider changes its API we only touch this file. Keep in sync with the
/// macOS Providers.swift.
/// </summary>
public static class UsageFetcher
{
    public static Task<UsageSnapshot> FetchAsync(ProviderId provider, ProviderSession session)
        => provider switch
        {
            ProviderId.ChatGpt => FetchChatGptAsync(session),
            ProviderId.Claude => FetchClaudeAsync(session),
            _ => throw new ArgumentOutOfRangeException(nameof(provider))
        };

    // MARK: - ChatGPT / Codex

    private static async Task<UsageSnapshot> FetchChatGptAsync(ProviderSession session)
    {
        // /backend-api/* needs a Bearer access token (cookies alone -> 401).
        // The web app first reads it from the Next.js auth session endpoint.
        var sessionBody = await session.FetchJsonAsync("/api/auth/session");

        string? token;
        using (var doc = JsonDocument.Parse(sessionBody))
        {
            token = doc.RootElement.TryGetProperty("accessToken", out var t)
                ? t.GetString()
                : null;
        }
        if (string.IsNullOrEmpty(token)) throw new NotAuthenticatedException();

        // Verified from chatgpt.com traffic: the Codex ("wham") usage endpoint.
        var body = await session.FetchJsonAsync(
            "/backend-api/wham/usage",
            new Dictionary<string, string> { ["Authorization"] = $"Bearer {token}" });

        return ParseChatGpt(body);
    }

    private readonly record struct Window(string Label, double UsedPercent, DateTimeOffset? ResetAt);

    public static UsageSnapshot ParseChatGpt(string body)
    {
        using var doc = JsonDocument.Parse(body);
        var root = doc.RootElement;

        var windows = new List<Window>();
        if (root.TryGetProperty("rate_limit", out var rl) && rl.ValueKind == JsonValueKind.Object)
        {
            foreach (var key in new[] { "primary_window", "secondary_window" })
            {
                if (!rl.TryGetProperty(key, out var w) || w.ValueKind != JsonValueKind.Object)
                    continue;

                var used = w.TryGetProperty("used_percent", out var up) ? up.GetDouble() : 0;
                double? seconds = w.TryGetProperty("limit_window_seconds", out var lws)
                    ? lws.GetDouble() : null;
                DateTimeOffset? resetAt = w.TryGetProperty("reset_at", out var ra)
                    ? DateTimeOffset.FromUnixTimeSeconds(ra.GetInt64()) : null;

                windows.Add(new Window(WindowLabel(seconds), used, resetAt));
            }
        }

        // Headline reflects the most-consumed window (the binding constraint).
        Window? main = windows.Count > 0
            ? windows.OrderByDescending(x => x.UsedPercent).First()
            : null;

        var headline = main is { } m
            ? $"{Math.Round(m.UsedPercent)}% used · {m.Label}"
            : "No active limit";

        var details = windows
            .Select(w =>
            {
                var pct = Math.Round(w.UsedPercent);
                return w.ResetAt is { } r
                    ? $"{w.Label}: {pct}% used · resets {Relative(r)}"
                    : $"{w.Label}: {pct}% used";
            })
            .ToList();

        if (root.TryGetProperty("plan_type", out var plan) && plan.GetString() is { } planName)
            details.Add($"Plan: {Capitalize(planName)}");

        if (root.TryGetProperty("credits", out var credits)
            && credits.ValueKind == JsonValueKind.Object
            && credits.TryGetProperty("has_credits", out var hasCredits)
            && hasCredits.ValueKind == JsonValueKind.True
            && credits.TryGetProperty("balance", out var bal))
        {
            details.Add($"Credits: {bal.GetString()}");
        }

        return new UsageSnapshot(
            ProviderId.ChatGpt,
            headline,
            (main?.UsedPercent ?? 0) / 100.0,
            main?.ResetAt,
            details,
            DateTimeOffset.Now);
    }

    // MARK: - Claude

    private static async Task<UsageSnapshot> FetchClaudeAsync(ProviderSession session)
    {
        // 1) Resolve the org id.
        var orgsBody = await session.FetchJsonAsync("/api/organizations");
        string? orgId;
        using (var doc = JsonDocument.Parse(orgsBody))
        {
            orgId = doc.RootElement.ValueKind == JsonValueKind.Array
                    && doc.RootElement.GetArrayLength() > 0
                    && doc.RootElement[0].TryGetProperty("uuid", out var u)
                ? u.GetString()
                : null;
        }
        if (string.IsNullOrEmpty(orgId))
            throw new InvalidOperationException("no organization found");

        // 2) Usage endpoint — pending verification, same as the macOS build.
        var body = await session.FetchJsonAsync($"/api/bootstrap/{orgId}/statsig");
        return new UsageSnapshot(
            ProviderId.Claude, "Connected", null, null,
            new[]
            {
                $"Raw payload received ({body.Length} bytes).",
                "Usage field mapping pending endpoint verification."
            },
            DateTimeOffset.Now);
    }

    // MARK: - Helpers

    private static string WindowLabel(double? seconds) => seconds switch
    {
        null => "Limit",
        3600 => "Hourly",
        18000 => "5-hour",
        86400 => "Daily",
        604800 => "Weekly",
        _ => $"{(int)(seconds.Value / 3600)}h window"
    };

    private static string Relative(DateTimeOffset when)
    {
        var delta = when - DateTimeOffset.Now;
        if (delta <= TimeSpan.Zero) return "now";
        if (delta.TotalDays >= 1) return $"in {(int)delta.TotalDays}d";
        if (delta.TotalHours >= 1) return $"in {(int)delta.TotalHours}h";
        return $"in {(int)delta.TotalMinutes}m";
    }

    private static string Capitalize(string s)
        => string.IsNullOrEmpty(s) ? s : char.ToUpper(s[0]) + s[1..];
}
