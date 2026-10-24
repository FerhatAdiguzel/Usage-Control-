import Foundation

/// Diagnostics log.
///
/// Deliberately NOT in /tmp: that directory is world-writable (a pre-planted
/// symlink would redirect our appends to an arbitrary user-owned file) and
/// world-readable, while this log carries account identifiers. It lives in the
/// user's private Library/Logs directory, 0700 dir + 0600 file, and is capped.
enum Log {
    private static let lock = NSLock()
    /// Not private: the rotation test asserts against this cap.
    static let maxBytes: UInt64 = 512 * 1024

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

        // forUpdating, not forWritingTo: trimming has to read the tail back,
        // and a write-only descriptor fails that read with EBADF.
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }

        do {
            // Keep the log bounded rather than growing without limit.
            let size = try handle.seekToEnd()
            if size > maxBytes {
                try trim(handle, from: size)
            }
            try handle.write(contentsOf: data)
        } catch {
            // Logging must never interrupt the application.
        }
    }

    /// Dated on purpose: with a time alone, an entry from one day was
    /// indistinguishable from the next day's, and the only clue that the log
    /// had crossed midnight was the clock appearing to run backwards. That
    /// made two failures days apart look like one simultaneous event.
    /// Drops the oldest half of the log and keeps the newest.
    ///
    /// This used to truncate to zero, which threw away every entry the moment
    /// the cap was reached. That is the opposite of what a diagnostic log is
    /// for: the history needed to date the start of a failure was exactly what
    /// got discarded. Leaves the handle at the end, ready to append.
    static func trim(_ handle: FileHandle, from size: UInt64) throws {
        let keep = maxBytes / 2
        try handle.seek(toOffset: size - keep)
        var tail = try handle.readToEnd() ?? Data()
        // The cut lands mid-line, so drop that partial first entry rather than
        // leave a fragment that reads like a real one.
        if let newline = tail.firstIndex(of: 0x0A) {
            tail = Data(tail[(newline + 1)...])
        }

        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        let marker = "\(stamp())  --- trimmed: earlier entries dropped ---\n"
        try handle.write(contentsOf: Data(marker.utf8))
        try handle.write(contentsOf: tail)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        // Fixed locale so the stamp is stable whatever the user's region and
        // calendar are set to.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
