import Foundation
import XCTest

@testable import quill

final class SessionAndMCPStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDiscardRemovesUnstartedSessionFolder() throws {
        let session = try RecordingSession(root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.dir.path))

        session.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: session.dir.path))
    }

    func testMCPStoreRejectsTraversalMeetingIDs() throws {
        let store = QuillMCPStore(root: root)

        XCTAssertNil(store.readTranscript(id: "../outside"))
        XCTAssertNil(store.readTranscript(id: "meeting/nested"))
        XCTAssertNil(store.readTranscript(id: ".."))
    }

    func testMCPStoreReadsOnlyTranscriptInsideMeetingFolder() throws {
        let store = QuillMCPStore(root: root)
        let meeting = root.appendingPathComponent("2026.09.16-1200", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        let transcript = """
        {"engine":"parakeet","model":"v3","created_at":"2026-09-16T12:00:00Z","segments":[]}
        """
        try Data(transcript.utf8).write(to: meeting.appendingPathComponent("transcript.json"))

        XCTAssertNotNil(store.readTranscript(id: "2026.09.16-1200"))
        XCTAssertNotNil(store.resourceText(
            uri: "quill://meetings/2026.09.16-1200/transcript",
            mcpPort: 47777
        ))
    }
}
