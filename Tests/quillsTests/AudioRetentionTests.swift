import XCTest
@testable import quills

final class AudioRetentionTests: XCTestCase {
    private func withSessions(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func session(_ root: URL, _ name: String, completed: Bool = true) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in ["mic.caf", "system.caf", "meta.json", "transcript.json", "transcript.md", "transcribe.log"] {
            try Data("test".utf8).write(to: dir.appendingPathComponent(file))
        }
        if completed { try AudioRetention.markCompleted(dir) }
        return dir
    }

    private func exists(_ dir: URL, _ file: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path)
    }

    func testDeleteRemovesOnlyCompletedAudioAndPreservesOtherFiles() throws {
        try withSessions { root in
            let completed = try session(root, "2026.10.01-1000")
            let partial = try session(root, "2026.10.01-1100", completed: false)
            let pending = try session(root, "2026.10.01-1200", completed: false)
            try FileManager.default.removeItem(at: pending.appendingPathComponent("transcript.json"))
            try AudioRetention.deleteAfterTranscription.apply(root: root)
            for file in ["mic.caf", "system.caf"] {
                XCTAssertFalse(exists(completed, file))
                XCTAssertTrue(exists(partial, file))
                XCTAssertTrue(exists(pending, file))
            }
            for file in ["meta.json", "transcript.json", "transcript.md", "transcribe.log"] {
                XCTAssertTrue(exists(completed, file))
            }
            try AudioRetention.deleteAfterTranscription.apply(root: root)
        }
    }

    func testKeepLastUsesNewestCompletedSessionIncludingNumericSuffix() throws {
        try withSessions { root in
            let older = try session(root, "2026.10.01-1000-2")
            let latest = try session(root, "2026.10.01-1000-10")
            let pending = try session(root, "2026.10.01-1100", completed: false)
            try AudioRetention.keepLast.apply(root: root)
            XCTAssertFalse(exists(older, "mic.caf"))
            XCTAssertFalse(exists(older, "system.caf"))
            XCTAssertTrue(exists(latest, "mic.caf"))
            XCTAssertTrue(exists(latest, "system.caf"))
            XCTAssertTrue(exists(pending, "mic.caf"))
        }
    }

    func testKeepAllPreservesAudio() throws {
        try withSessions { root in
            let dir = try session(root, "2026.10.01-1000")
            try AudioRetention.keepAll.apply(root: root)
            XCTAssertTrue(exists(dir, "mic.caf"))
            XCTAssertTrue(exists(dir, "system.caf"))
        }
    }

    func testIncompleteTranscriptAndLinkedSessionArePreserved() throws {
        try withSessions { root in
            let dir = try session(root, "2026.10.01-1000")
            try FileManager.default.removeItem(at: dir.appendingPathComponent("transcript.md"))
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let linked = try session(outside, "2026.10.01-1100")
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: linked)
            try AudioRetention.deleteAfterTranscription.apply(root: root)
            XCTAssertTrue(exists(dir, "mic.caf"))
            XCTAssertTrue(exists(linked, "mic.caf"))
        }
    }
}
