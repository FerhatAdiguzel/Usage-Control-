import Foundation

/// Diagnostics log.
///
/// Deliberately NOT in /tmp: that directory is world-writable (a pre-planted
/// symlink would redirect our appends to an arbitrary user-owned file) and
/// world-readable (this log carries account emails). It lives in the user's
/// private Library/Logs directory, 0700 dir + 0600 file, and is size-capped.
enum Log {
    private static let lock = NSLock()
    private static let maxBytes: UInt64 = 512 * 1024

    static let url: URL = {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/UsageMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        // Clean up the old world-readable log, which leaked account emails.
        try? FileManager.default.removeItem(atPath: "/tmp/usagemonitor.log")

        return dir.appendingPathComponent("usagemonitor.log")
    }()

    static func write(_ message: String) {
        guard let data = "\(stamp())  \(message)\n".data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }

        // Keep the log bounded rather than growing without limit.
        if let size = try? handle.seekToEnd(), size > maxBytes {
            try? handle.truncate(atOffset: 0)
            try? handle.seek(toOffset: 0)
        }
        try? handle.write(contentsOf: data)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
