import Foundation

enum AudioRetention: String, CaseIterable, Sendable {
    case deleteAfterTranscription = "delete_after_transcription"
    case keepLast = "keep_last"
    case keepAll = "keep_all"

    var title: String {
        switch self {
        case .deleteAfterTranscription: "Delete audio after transcription"
        case .keepLast: "Keep last audio"
        case .keepAll: "Do not delete anything"
        }
    }

    // Only sessions whose every track was transcribed by this version are
    // eligible. Older transcripts may have silently skipped a broken track.
    static let completionMarker = ".quill-audio-transcribed"

    static func markCompleted(_ dir: URL) throws {
        try Data().write(to: dir.appendingPathComponent(completionMarker), options: .atomic)
    }

    func apply(root: URL) throws {
        guard self != .keepAll else { return }
        let fm = FileManager.default
        let sessions = try fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]
        ).filter { dir in
            let values = try? dir.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
                && fm.fileExists(atPath: dir.appendingPathComponent(Self.completionMarker).path)
                && fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path)
                && fm.fileExists(atPath: dir.appendingPathComponent("transcript.md").path)
        }.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }

        let keep = self == .keepLast ? sessions.last : nil
        for dir in sessions where dir != keep {
            // Quills owns exactly these two audio tracks. Never remove session
            // folders, transcripts, metadata, logs, or arbitrary linked files.
            for name in ["mic.caf", "system.caf"] {
                let audio = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: audio.path) {
                    try fm.removeItem(at: audio)
                }
            }
        }
    }
}
