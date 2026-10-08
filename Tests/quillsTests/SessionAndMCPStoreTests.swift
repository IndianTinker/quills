import Foundation
import XCTest

@testable import quills

final class SessionAndMCPStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quills-tests-\(UUID().uuidString)", isDirectory: true)
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
        let store = QuillsMCPStore(root: root)

        XCTAssertNil(store.readTranscript(id: "../outside"))
        XCTAssertNil(store.readTranscript(id: "meeting/nested"))
        XCTAssertNil(store.readTranscript(id: ".."))
    }

    func testMCPStoreReadsOnlyTranscriptInsideMeetingFolder() throws {
        let store = QuillsMCPStore(root: root)
        let meeting = root.appendingPathComponent("2026.09.16-1200", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        let transcript = """
        {"engine":"parakeet","model":"v3","created_at":"2026-09-16T12:00:00Z","segments":[]}
        """
        try Data(transcript.utf8).write(to: meeting.appendingPathComponent("transcript.json"))

        XCTAssertNotNil(store.readTranscript(id: "2026.09.16-1200"))
        XCTAssertNotNil(store.resourceText(
            uri: "quills://meetings/2026.09.16-1200/transcript",
            mcpPort: 47777
        ))
        XCTAssertEqual(
            store.resourceText(uri: "quill://meetings/2026.09.16-1200/transcript", mcpPort: 47777)?.text,
            store.resourceText(uri: "quills://meetings/2026.09.16-1200/transcript", mcpPort: 47777)?.text
        )
        for scheme in ["quill", "quills"] {
            XCTAssertNil(store.resourceText(uri: "\(scheme)://meetings/../transcript", mcpPort: 47777))
            XCTAssertNil(store.resourceText(uri: "\(scheme)://meetings/2026.09.16-1200/transcript/extra", mcpPort: 47777))
        }
    }

    func testMCPStatusResourcesPreserveLegacySchema() throws {
        let store = QuillsMCPStore(root: root)
        for scheme in ["quill", "quills"] {
            let resource = try XCTUnwrap(store.resourceText(uri: "\(scheme)://status", mcpPort: 47777))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(resource.text.utf8)) as? [String: Any])
            XCTAssertNotNil(json["quill"])
            XCTAssertNotNil(json["mcp"])
        }
    }

    func testMCPStoreExcludesUnfinalizedAndUnrelatedDirectories() throws {
        let store = QuillsMCPStore(root: root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("active-recording", isDirectory: true),
            withIntermediateDirectories: true
        )
        let meeting = root.appendingPathComponent("2026.09.16-1300", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: meeting.appendingPathComponent("meta.json"))

        XCTAssertEqual(store.listMeetings().map(\.id), ["2026.09.16-1300"])
    }

    func testMCPStoreReportsPersistedTranscriptionFailure() throws {
        let store = QuillsMCPStore(root: root)
        let meeting = root.appendingPathComponent("2026.09.16-1400", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: meeting.appendingPathComponent("meta.json"))
        try Data("no usable tracks\n".utf8).write(
            to: meeting.appendingPathComponent(".quill-transcription-failed")
        )

        XCTAssertEqual(store.listMeetings().first?.status, "failed")
    }
}
