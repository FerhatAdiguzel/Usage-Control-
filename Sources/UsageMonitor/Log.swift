import Foundation

/// Diagnostics log.
///
/// Deliberately NOT in /tmp: that directory is world-writable (a pre-planted
/// symlink would redirect our appends to an arbitrary user-owned file) and
/// world-readable, while this log carries account identifiers. It lives in the
/// user's private Library/Logs directory, 0700 dir + 0600 file, and is capped.
enum Log {
    private static let lock = NSLock()
    private static let maxBytes: UInt64 = 512 * 1024

    private static let url: URL = {
        let fm = FileManager.default
        let directory = fm
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/UsageMonitor", isDirectory: true)

        try? fm.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Re-assert: create* only applies these attributes when it actually
        // creates the item, so an existing loose-permission dir would persist.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let file = directory.appendingPathComponent("usagemonitor.log")
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(
                atPath: file.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600])
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        // Remove the superseded world-readable log, which leaked account data.
        try? fm.removeItem(atPath: "/tmp/usagemonitor.log")

        return file
    }()

    static var path: String { url.path }

    static func write(_ message: String) {
        guard let data = "\(Self.stamp())  \(message)\n".data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }

        do {
            // Keep the log bounded rather than growing without limit.
            if try handle.seekToEnd() > maxBytes {
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
            }
            try handle.write(contentsOf: data)
        } catch {
            // Logging must never interrupt the application.
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
