import FluidAudio
import Foundation
import XCTest
@testable import quills

final class ModelSelectionTests: XCTestCase {
    func testInstalledModelWithSyntheticSilence() async throws {
        guard ProcessInfo.processInfo.environment["QUILLS_MODEL_SMOKE_TEST"] == "1" else {
            throw XCTSkip("opt in to testing the installed shared model with QUILLS_MODEL_SMOKE_TEST=1")
        }
        let selection = ModelSelection(model: .v3, directory: SpeechModel.v3.cacheDirectory, isCustom: true)
        guard selection.isInstalled else { throw XCTSkip("shared v3 model is not installed") }
        let models = try await selection.load()
        let manager = AsrManager()
        try await manager.loadModels(models)
        do {
            var state = try TdtDecoderState(decoderLayers: selection.model.version.decoderLayers)
            let result = try await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
            XCTAssertGreaterThan(result.duration, 0)
        } catch {
            await manager.cleanup()
            throw error
        }
        await manager.cleanup()
    }

    func testLegacyConfigKeepsV3AndCustomDirectory() {
        let selection = Config.modelSelection(from: ["transcription": ["model_dir": "~/Models/existing"]])
        XCTAssertEqual(selection.model, .v3)
        XCTAssertTrue(selection.isCustom)
        XCTAssertEqual(selection.directory.path, ("~/Models/existing" as NSString).expandingTildeInPath)
        XCTAssertEqual(Config.modelSelection(from: [:]).directory, SpeechModel.v3.cacheDirectory)
    }

    func testSelectingSharedModelPreservesUnrelatedSettingsAndClearsOldPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config.json")
        let original: [String: Any] = ["on_stop": "custom-hook", "audio_retention": "keep_last", "transcription": ["enabled": false, "model_dir": "/old/model", "future_setting": 42]]
        try JSONSerialization.data(withJSONObject: original).write(to: config)
        try Config.setModel(.compact, at: config)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        let settings = try XCTUnwrap(saved["transcription"] as? [String: Any])
        XCTAssertEqual(saved["on_stop"] as? String, "custom-hook")
        XCTAssertEqual(saved["audio_retention"] as? String, "keep_last")
        XCTAssertEqual(settings["enabled"] as? Bool, false)
        XCTAssertEqual(settings["future_setting"] as? Int, 42)
        XCTAssertNil(settings["model_dir"])
        let selection = Config.modelSelection(from: saved)
        XCTAssertEqual(selection.model, .compact)
        XCTAssertEqual(selection.directory, SpeechModel.compact.cacheDirectory)
        XCTAssertFalse(selection.isCustom)
        let engine = ParakeetEngine(selection: selection)
        XCTAssertEqual(engine.model, "parakeet-tdt-ctc-110m-coreml")
        try Config.setModel(.v2, directory: root, at: config)
        let custom = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        XCTAssertEqual(Config.modelSelection(from: custom), ModelSelection(model: .v2, directory: URL(fileURLWithPath: root.path, isDirectory: true), isCustom: true))
        // Existing engine keeps its selection while the config changes.
        XCTAssertEqual(engine.model, "parakeet-tdt-ctc-110m-coreml")
    }

    func testMalformedConfigIsNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config.json")
        for text in ["{broken", "[]", "{\"transcription\": false}"] {
            let data = Data(text.utf8)
            try data.write(to: config)
            XCTAssertThrowsError(try Config.setModel(.v2, at: config))
            XCTAssertEqual(try Data(contentsOf: config), data)
        }
    }

    func testModelChecksUseChosenFolderAndFollowSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chosen = root.appendingPathComponent("my-renamed-model", isDirectory: true)
        let sibling = root.appendingPathComponent(SpeechModel.v3.cacheDirectory.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let selection = ModelSelection(model: .v3, directory: chosen, isCustom: true)
        // Even a complete-looking sibling must never satisfy the chosen folder.
        for file in selection.requiredFiles {
            try Data("fixture".utf8).write(to: sibling.appendingPathComponent(file))
        }
        XCTAssertFalse(selection.isInstalled)
        for file in selection.requiredFiles {
            try Data("fixture".utf8).write(to: chosen.appendingPathComponent(file))
        }
        try Data("{\"0\":\"hello\",\"1\":\"world\"}".utf8).write(to: chosen.appendingPathComponent("parakeet_vocab.json"))
        XCTAssertTrue(selection.isInstalled)
        XCTAssertEqual(try selection.vocabulary(), [0: "hello", 1: "world"])
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: chosen)
        XCTAssertTrue(ModelSelection(model: .v3, directory: link, isCustom: true).isInstalled)
        try Data("[\"hello\",\"world\"]".utf8).write(to: chosen.appendingPathComponent("parakeet_vocab.json"))
        XCTAssertEqual(try selection.vocabulary(), [0: "hello", 1: "world"])
        try Data("{\"bad-index\":\"word\"}".utf8).write(to: chosen.appendingPathComponent("parakeet_vocab.json"))
        XCTAssertThrowsError(try selection.vocabulary())
    }

    func testIncompleteCustomFolderFailsWithoutDownloadingIntoIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let selection = ModelSelection(model: .v3, directory: root, isCustom: true)
        do {
            _ = try await selection.load()
            XCTFail("incomplete custom bundles must fail")
        } catch ModelError.incompleteBundle(let url) {
            XCTAssertEqual(url, root)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
