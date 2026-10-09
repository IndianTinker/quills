@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Only bundles supported by our timestamped Parakeet engine belong here.
enum SpeechModel: String, CaseIterable, Sendable {
    case v3 = "parakeet-tdt-0.6b-v3"
    case v2 = "parakeet-tdt-0.6b-v2"
    case compact = "parakeet-tdt-ctc-110m"

    var version: AsrModelVersion {
        switch self {
        case .v3: return .v3
        case .v2: return .v2
        case .compact: return .tdtCtc110m
        }
    }

    var title: String {
        switch self {
        case .v3: return "Parakeet v3 — multilingual · recommended"
        case .v2: return "Parakeet v2 — English · 600M"
        case .compact: return "Parakeet 110M — English · lightweight"
        }
    }

    var guidance: String {
        switch self {
        case .v3: return "Fast multilingual transcription. Default choice; 600M parameters."
        case .v2: return "Fast English-only transcription; 600M parameters."
        case .compact: return "Smaller model with faster loading and less memory use. English only; accuracy varies with audio."
        }
    }

    var cacheDirectory: URL { AsrModels.defaultCacheDirectory(for: version) }
    var provenance: String { rawValue + "-coreml" }
}

/// Snapshot once per session so its two tracks always use the same model.
struct ModelSelection: Equatable, Sendable {
    let model: SpeechModel
    let directory: URL
    let isCustom: Bool

    var requiredFiles: Set<String> {
        let names: Set<String>
        switch model {
        case .v3: names = ModelNames.ASR.requiredModelsV3()
        case .v2: names = ModelNames.ASR.requiredModels
        case .compact: names = ModelNames.ASR.requiredModelsFused
        }
        return names.union([ModelNames.ASR.vocabularyFile])
    }

    var isInstalled: Bool {
        requiredFiles.allSatisfy {
            FileManager.default.isReadableFile(atPath: directory.appendingPathComponent($0).path)
        }
    }

    func vocabulary() throws -> [Int: String] {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile)))
        let vocabulary: [Int: String]
        if let words = json as? [String] {
            vocabulary = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($0.offset, $0.element) })
        } else if let words = json as? [String: String] {
            var parsed: [Int: String] = [:]
            for (key, word) in words {
                guard let index = Int(key), index >= 0, parsed[index] == nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                parsed[index] = word
            }
            vocabulary = parsed
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard !vocabulary.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return vocabulary
    }

    func load() async throws -> AsrModels {
        if isCustom && !isInstalled {
            throw ModelError.incompleteBundle(directory)
        }
        if !isInstalled { try await ModelDownloads.shared.download(self) }
        guard isInstalled else { throw ModelError.incompleteBundle(directory) }
        // FluidAudio's convenience loader reconstructs the repository folder
        // name and may download optional assets. Load the selected files directly
        // so arbitrary folder names and symlinks work without network access.
        let config = AsrModels.defaultConfiguration()
        func loadModel(_ file: String, cpuOnly: Bool = false) async throws -> MLModel {
            let modelConfig = AsrModels.defaultConfiguration()
            if cpuOnly { modelConfig.computeUnits = .cpuOnly }
            return try await MLModel.load(contentsOf: directory.appendingPathComponent(file), configuration: modelConfig)
        }
        let words = try vocabulary()
        let preprocessor = try await loadModel(ModelNames.ASR.preprocessorFile, cpuOnly: model != .compact)
        let encoder = model == .compact ? nil : try await loadModel(ModelNames.ASR.encoderFile)
        let decoder = try await loadModel(ModelNames.ASR.decoderFile)
        let joint = try await loadModel(model == .v3 ? ModelNames.ASR.jointV3File : ModelNames.ASR.jointFile)
        return AsrModels(encoder: encoder, preprocessor: preprocessor, decoder: decoder, joint: joint,
                         configuration: config, vocabulary: words, version: model.version)
    }
}

enum ModelError: Error, LocalizedError {
    case incompleteBundle(URL)

    var errorDescription: String? {
        switch self {
        case .incompleteBundle(let url):
            return "No complete compatible Core ML bundle at \(url.path). Choose the matching model type and a folder containing its model bundles and vocabulary."
        }
    }
}

/// Coalesce menu and transcription requests for the same destination.
actor ModelDownloads {
    static let shared = ModelDownloads()
    private var tasks: [String: Task<Void, Error>] = [:]

    func download(_ selection: ModelSelection) async throws {
        let key = selection.directory.standardizedFileURL.path + selection.model.rawValue
        if let task = tasks[key] { return try await task.value }
        let task = Task {
            _ = try await AsrModels.download(to: selection.directory, version: selection.model.version)
        }
        tasks[key] = task
        defer { tasks[key] = nil }
        try await task.value
    }
}
