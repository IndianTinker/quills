import Foundation
import MCP

/// The only data exposed by Quill's MCP server is read from the recordings
/// directory and the runtime status file. This type intentionally contains no
/// write operations.
struct QuillMCPStore: Sendable {
    let root: URL
    private static let failureMarkerName = ".quill-transcription-failed"

    struct Meeting: Codable, Sendable {
        let id: String
        let started: String?
        let ended: String?
        let durationSeconds: Int?
        let status: String
        let transcriptAvailable: Bool
    }

    struct Transcript: Codable, Sendable {
        struct Segment: Codable, Sendable {
            let speaker: String
            let start_ms: Int
            let end_ms: Int
            let text: String
        }

        let engine: String
        let model: String
        let created_at: String
        let segments: [Segment]
    }

    struct SearchMatch: Codable, Sendable {
        let meeting_id: String
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    struct RuntimeStatus: Codable, Sendable {
        let updated_at: String?
        let recording: Bool
        let recording_session: String?
        let transcription_state: String
        let transcription_session: String?
        let transcription_track: String?
        let queued: Int
        let error: String?
    }

    struct MCPStatus: Codable, Sendable {
        let state: String
        let host: String
        let port: Int
        let endpoint: String
        let transport: String
        let read_only: Bool
    }

    struct StatusSnapshot: Codable, Sendable {
        let mcp: MCPStatus
        let quill: RuntimeStatus
    }

    func statusSnapshot(mcpPort: Int) -> StatusSnapshot {
        StatusSnapshot(
            mcp: MCPStatus(
                state: "running",
                host: "127.0.0.1",
                port: mcpPort,
                endpoint: "http://127.0.0.1:\(mcpPort)/mcp",
                transport: "streamable-http",
                read_only: true
            ),
            quill: readStatus()
        )
    }

    func listMeetings(limit: Int = 50) -> [Meeting] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(max(0, limit))
            .map { meeting(at: $0) }
    }

    func search(query: String, limit: Int = 50) -> [SearchMatch] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return [] }

        var matches: [SearchMatch] = []
        for meeting in listMeetings(limit: Int.max) {
            guard let transcript = readTranscript(id: meeting.id) else { continue }
            for segment in transcript.segments {
                guard segment.text.lowercased().contains(normalizedQuery) else { continue }
                matches.append(SearchMatch(
                    meeting_id: meeting.id,
                    speaker: segment.speaker,
                    start_ms: segment.start_ms,
                    end_ms: segment.end_ms,
                    text: segment.text
                ))
                if matches.count >= max(0, limit) { return matches }
            }
        }
        return matches
    }

    func readTranscript(id: String) -> Transcript? {
        guard let dir = safeMeetingDirectory(id: id) else { return nil }
        let url = dir.appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    func readStatus() -> RuntimeStatus {
        guard let data = try? Data(contentsOf: Config.mcpStatusURL),
              let status = try? JSONDecoder().decode(RuntimeStatus.self, from: data)
        else {
            return RuntimeStatus(
                updated_at: nil,
                recording: false,
                recording_session: nil,
                transcription_state: "unknown",
                transcription_session: nil,
                transcription_track: nil,
                queued: 0,
                error: nil
            )
        }
        return status
    }

    func resourceText(uri: String, mcpPort: Int) -> (text: String, mimeType: String)? {
        if uri == "quill://status" {
            guard let data = try? JSONEncoder.pretty.encode(statusSnapshot(mcpPort: mcpPort)),
                  let text = String(data: data, encoding: .utf8)
            else { return nil }
            return (text, "application/json")
        }

        guard let id = transcriptMeetingID(uri: uri),
              let transcript = readTranscript(id: id),
              let data = try? JSONEncoder.pretty.encode(transcript),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return (text, "application/json")
    }

    private func transcriptMeetingID(uri: String) -> String? {
        let prefix = "quill://meetings/"
        guard uri.hasPrefix(prefix) else { return nil }
        let parts = uri.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "transcript", !parts[0].isEmpty else {
            return nil
        }
        return String(parts[0])
    }

    private func meeting(at dir: URL) -> Meeting {
        let metaURL = dir.appendingPathComponent("meta.json")
        let transcriptURL = dir.appendingPathComponent("transcript.json")
        let failureURL = dir.appendingPathComponent(Self.failureMarkerName)
        let meta = (try? Data(contentsOf: metaURL)).flatMap {
            try? JSONDecoder().decode(SessionMeta.self, from: $0)
        }

        let hasTranscript = FileManager.default.fileExists(atPath: transcriptURL.path)
        let status: String
        if hasTranscript {
            status = "completed"
        } else if FileManager.default.fileExists(atPath: failureURL.path) {
            status = "failed"
        } else if let log = try? String(
            contentsOf: dir.appendingPathComponent("transcribe.log"),
            encoding: .utf8
        ),
                  log.localizedCaseInsensitiveContains("transcription failed") {
            status = "failed"
        } else {
            status = "queued"
        }

        return Meeting(
            id: dir.lastPathComponent,
            started: meta?.started,
            ended: meta?.ended,
            durationSeconds: meta?.duration_seconds,
            status: status,
            transcriptAvailable: hasTranscript
        )
    }

    private func safeMeetingDirectory(id: String) -> URL? {
        guard !id.isEmpty,
              id != ".",
              id != "..",
              !id.contains("/"),
              !id.contains("\\")
        else { return nil }

        let dir = root.appendingPathComponent(id, isDirectory: true)
        guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return nil
        }
        return dir
    }

    private struct SessionMeta: Codable {
        let started: String?
        let ended: String?
        let duration_seconds: Int?
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
