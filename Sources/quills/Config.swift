import FluidAudio
import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": {
///         "enabled": true,
///         "engine": "parakeet",
///         "model_dir": "~/Models/parakeet-tdt-0.6b-v3"
///       },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let mcpStatusURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Quill/status.json")

    static let defaultMCPPort = 47777

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Local-only MCP server port. The server always binds to 127.0.0.1.
    static func mcpPort() -> Int {
        guard let port = load()?["mcp_port"] as? Int, (1024...65535).contains(port) else {
            return defaultMCPPort
        }
        return port
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    static func audioRetention() -> AudioRetention {
        (load()?["audio_retention"] as? String).flatMap(AudioRetention.init(rawValue:)) ?? .keepAll
    }

    static func setAudioRetention(_ retention: AudioRetention) throws {
        // Preserve other settings and refuse to overwrite malformed config.
        var json: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: path.path) {
            let data = try Data(contentsOf: path)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            json = existing
        }
        json["audio_retention"] = retention.rawValue
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path, options: .atomic)
    }

    /// Configured engine name. Only "parakeet" ships today; the coordinator
    /// warns and falls back for anything else.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "parakeet"
    }

    static func modelSelection() -> ModelSelection {
        modelSelection(from: load() ?? [:])
    }

    static func modelSelection(from json: [String: Any]) -> ModelSelection {
        let settings = json["transcription"] as? [String: Any] ?? [:]
        let model = (settings["model"] as? String).flatMap(SpeechModel.init(rawValue:)) ?? .v3
        let custom = (settings["model_dir"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let directory = custom.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        } ?? model.cacheDirectory
        return ModelSelection(model: model, directory: directory, isCustom: custom != nil)
    }

    static func transcriptionModelDir() -> URL { modelSelection().directory }

    static func setModel(_ model: SpeechModel, directory: URL? = nil, at configURL: URL = path) throws {
        var json: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: configURL.path) {
            guard let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            json = existing
        }
        if let value = json["transcription"], !(value is [String: Any]) {
            throw CocoaError(.fileReadCorruptFile)
        }
        var settings = json["transcription"] as? [String: Any] ?? [:]
        settings["engine"] = "parakeet"
        settings["model"] = model.rawValue
        settings["model_dir"] = directory?.path
        json["transcription"] = settings
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: configURL, options: .atomic)
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
