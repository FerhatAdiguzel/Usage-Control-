import Foundation

/// Minimal file logger so we can diagnose fetches without a visible console.
/// Tail with:  tail -f /tmp/usagemonitor.log
enum Log {
    static let path = "/tmp/usagemonitor.log"

    static func write(_ message: String) {
        let line = "\(Self.stamp())  \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
