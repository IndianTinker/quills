import Foundation

/// Runtime state is written by Quill and read by the MCP server. The MCP
/// server never writes meeting data or this status file.
enum QuillMCPStatus {
    static func write(
        recording: Bool,
        recordingSession: String? = nil,
        transcriptionState: String,
        transcriptionSession: String? = nil,
        transcriptionTrack: String? = nil,
        queued: Int = 0,
        error: String? = nil
    ) {
        let value = QuillMCPStore.RuntimeStatus(
            updated_at: ISO8601DateFormatter().string(from: Date()),
            recording: recording,
            recording_session: recordingSession,
            transcription_state: transcriptionState,
            transcription_session: transcriptionSession,
            transcription_track: transcriptionTrack,
            queued: queued,
            error: error
        )

        do {
            let parent = Config.mcpStatusURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: Config.mcpStatusURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data(
                "warning: couldn't update MCP status: \(error)\n".utf8
            ))
        }
    }
}
