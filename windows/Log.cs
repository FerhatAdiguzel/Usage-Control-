namespace UsageMonitorWin;

/// <summary>
/// Minimal file logger so we can diagnose fetches without a console.
/// Writes to %LOCALAPPDATA%\UsageMonitor\usagemonitor.log
/// </summary>
public static class Log
{
    private static readonly object Gate = new();

    public static string Path { get; } = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "UsageMonitor", "usagemonitor.log");

    public static void Write(string message)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
                File.AppendAllText(Path, $"{DateTime.Now:HH:mm:ss}  {message}{Environment.NewLine}");
            }
        }
        catch
        {
            // Logging must never break the app.
        }
    }
}
