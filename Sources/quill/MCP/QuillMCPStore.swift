import Foundation
import MCP

/// The only data exposed by Quill's MCP server is read from the recordings
/// directory and the runtime status file. This type intentionally contains no
/// write operations.
struct QuillMCPStore: Sendable {
    let root: URL

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

    func listMeetings(limit: Int = 50) -> [Meeting] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
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

    func resourceText(uri: String) -> (text: String, mimeType: String)? {
        if uri == "quill://status" {
            guard let data = try? JSONEncoder.pretty.encode(readStatus()),
                  let text = String(data: data, encoding: .utf8)
            else { return nil }
            return (text, "application/json")
        }

        guard let id = uri.split(separator: "/").last.map(String.init),
              uri.hasPrefix("quill://meetings/"),
              let transcript = readTranscript(id: id),
              let data = try? JSONEncoder.pretty.encode(transcript),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return (text, "application/json")
    }

    private func meeting(at dir: URL) -> Meeting {
        let metaURL = dir.appendingPathComponent("meta.json")
        let transcriptURL = dir.appendingPathComponent("transcript.json")
        let meta = (try? Data(contentsOf: metaURL)).flatMap {
            try? JSONDecoder().decode(SessionMeta.self, from: $0)
        }

        let hasTranscript = FileManager.default.fileExists(atPath: transcriptURL.path)
        let status: String
        if hasTranscript {
            status = "completed"
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
