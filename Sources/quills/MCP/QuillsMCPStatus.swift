import Foundation

/// Runtime state is written by Quills and read by the MCP server. The MCP
/// server never writes meeting data or this status file.
enum QuillsMCPStatus {
    static func write(
        recording: Bool,
        recordingPaused: Bool = false,
        recordingSession: String? = nil,
        transcriptionState: String,
        transcriptionSession: String? = nil,
        transcriptionTrack: String? = nil,
        queued: Int = 0,
        error: String? = nil
    ) {
        let value = QuillsMCPStore.RuntimeStatus(
            updated_at: ISO8601DateFormatter().string(from: Date()),
            recording: recording,
            recording_paused: recordingPaused,
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

    static func updateRecording(recording: Bool, paused: Bool = false, session: String? = nil) {
        do {
            let data = try Data(contentsOf: Config.mcpStatusURL)
            var value = try JSONDecoder().decode(QuillsMCPStore.RuntimeStatus.self, from: data)
            value.recording = recording
            value.recording_paused = paused
            value.recording_session = session
            value.updated_at = ISO8601DateFormatter().string(from: Date())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: Config.mcpStatusURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("warning: couldn't update recording status: \(error)\n".utf8))
        }
    }

}
