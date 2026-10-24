import XCTest
@testable import UsageMonitor

final class LogTests: XCTestCase {

    /// Trimming must keep the newest entries and drop the oldest. The earlier
    /// implementation truncated to zero, throwing away the very history a
    /// diagnostic log exists to provide.
    func testTrimKeepsNewestHalfAndDropsOldest() throws {
        let url = try makeLog(ofAtLeast: Int(Log.maxBytes) + 88 * 1024)
        defer { try? FileManager.default.removeItem(at: url) }

        let before = try String(contentsOf: url, encoding: .utf8)
        let beforeLines = lines(of: before)
        XCTAssertGreaterThan(UInt64(before.utf8.count), Log.maxBytes)

        let handle = try FileHandle(forUpdating: url)
        let size = try handle.seekToEnd()
        try Log.trim(handle, from: size)
        // A write right after trimming must still land at the end.
        try handle.write(contentsOf: Data("APPENDED\n".utf8))
        try handle.close()

        let after = try String(contentsOf: url, encoding: .utf8)
        let afterLines = lines(of: after)

        XCTAssertLessThanOrEqual(UInt64(after.utf8.count), Log.maxBytes,
                                 "trim must bring the file back under the cap")
        XCTAssertGreaterThan(afterLines.count, 1,
                             "history must survive: this is the bug that truncate(0) had")
        XCTAssertTrue(afterLines[0].contains("trimmed"),
                      "the first line should record that entries were dropped")
        XCTAssertEqual(afterLines.last, "APPENDED",
                       "the handle must be left positioned at the end")
        XCTAssertTrue(afterLines.contains(beforeLines.last!),
                      "the newest entry must be kept")
        XCTAssertFalse(afterLines.contains(beforeLines.first!),
                       "the oldest entry must be gone")
    }

    /// The cut lands mid-line, and a fragment would read like a real entry.
    func testTrimDoesNotLeaveAPartialEntry() throws {
        let url = try makeLog(ofAtLeast: Int(Log.maxBytes) + 88 * 1024)
        defer { try? FileManager.default.removeItem(at: url) }

        let handle = try FileHandle(forUpdating: url)
        let size = try handle.seekToEnd()
        try Log.trim(handle, from: size)
        try handle.close()

        let afterLines = lines(of: try String(contentsOf: url, encoding: .utf8))
        // Guard the loop below: on an empty file it would iterate nothing and
        // pass without checking anything at all.
        XCTAssertGreaterThan(afterLines.count, 1, "trim left nothing to inspect")
        // Entry 0 is the marker; every entry after it must be whole.
        for line in afterLines.dropFirst() {
            XCTAssertTrue(line.hasPrefix("entry "),
                          "found a fragment rather than a whole entry: \(line)")
        }
    }

    /// `write` opens the file for updating because trimming reads the tail
    /// back. A write-only descriptor fails that read with EBADF, and since
    /// `write` swallows its own errors the log would have stopped recording
    /// at the cap instead of rotating.
    func testTrimNeedsAReadableHandle() throws {
        let url = try makeLog(ofAtLeast: Int(Log.maxBytes) + 8 * 1024)
        defer { try? FileManager.default.removeItem(at: url) }

        let writeOnly = try FileHandle(forWritingTo: url)
        let size = try writeOnly.seekToEnd()
        XCTAssertThrowsError(try Log.trim(writeOnly, from: size))
        try? writeOnly.close()
    }

    // MARK: - Helpers

    private func makeLog(ofAtLeast bytes: Int) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("logtest-\(UUID().uuidString).log")
        var text = ""
        var n = 0
        let filler = String(repeating: "x", count: 60)
        while text.utf8.count < bytes {
            n += 1
            text += "entry \(n) \(filler)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func lines(of text: String) -> [String] {
        text.split(separator: "\n").map(String.init)
    }
}
