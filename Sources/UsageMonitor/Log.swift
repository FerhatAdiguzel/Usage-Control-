import Foundation

/// Minimal private file logger so we can diagnose fetches without a visible console.
enum Log {
    private static let url: URL = {
        let fileManager = FileManager.default
        let directory = fileManager
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/UsageMonitor", isDirectory: true)

        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path)

        let file = directory.appendingPathComponent("usagemonitor.log")
        if !fileManager.fileExists(atPath: file.path) {
            fileManager.createFile(
                atPath: file.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600])
        }
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path)
        return file
    }()

    static var path: String { url.path }

    static func write(_ message: String) {
        let line = "\(Self.stamp())  \(message)\n"
        guard let data = line.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else {
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
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
