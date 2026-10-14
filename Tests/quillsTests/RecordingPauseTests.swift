import AVFoundation
import XCTest
@testable import quills

final class RecordingPauseTests: XCTestCase {
    func testBothTracksExcludePausedSpeechAndKeepTimelineThroughResume() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pause = RecordingPause()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let tone = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        tone.frameLength = tone.frameCapacity
        try XCTUnwrap(tone.floatChannelData?[0]).update(repeating: 0.5, count: 4_800)
        let urls = ["mic", "system"].map { root.appendingPathComponent("\($0).caf") }
        var files = try urls.map { try AVAudioFile(forWriting: $0, settings: format.settings) }
        let converter = try XCTUnwrap(AVAudioConverter(from: format, to: format))

        var spans: [[(Range<Int>, Float)]] = [[], []]
        func appendTracks(generation: UInt64? = nil) throws {
            let starts = files.map { Int($0.length) }
            let expected: Float = pause.isPaused || (generation.map { $0 != pause.captureGeneration } ?? false) ? 0 : 0.5
            try MicRecorder.append(tone, to: files[0], using: converter, pause: pause, capturedGeneration: generation)
            try pause.write(tone, to: files[1], capturedGeneration: generation)
            for index in files.indices {
                spans[index].append((starts[index]..<Int(files[index].length), expected))
            }
        }
        try appendTracks()
        pause.setPaused(true)
        pause.setPaused(true) // Repeated pause must remain paused.
        XCTAssertTrue(pause.isPaused)
        try appendTracks()
        let pausedGeneration = pause.captureGeneration
        pause.setPaused(false)
        try appendTracks(generation: pausedGeneration) // Late callbacks must not disclose paused speech.
        try appendTracks()
        pause.setPaused(true)
        try appendTracks() // Stopping while paused also preserves the silence.
        let lengths = files.map { $0.length }
        files.removeAll()

        for (track, url) in urls.enumerated() {
            let reader = try AVAudioFile(forReading: url)
            XCTAssertEqual(reader.length, lengths[track])
            XCTAssertEqual(Double(reader.length) / 48_000, 0.5, accuracy: 0.02)
            let audio = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat,
                                                     frameCapacity: AVAudioFrameCount(reader.length)))
            try reader.read(into: audio)
            let samples = try XCTUnwrap(audio.floatChannelData?[0])
            for (range, expected) in spans[track] {
                XCTAssertFalse(range.isEmpty)
                if expected == 0 {
                    let maximum = range.map { abs(samples[$0]) }.max() ?? 0
                    XCTAssertEqual(maximum, 0, "every paused sample must be silence")
                } else {
                    XCTAssertEqual(samples[range.lowerBound + range.count / 2], expected, accuracy: 0.001)
                }
            }
        }
        XCTAssertEqual(tone.floatChannelData?[0][0], 0.5, "pause must not mutate capture buffers")
    }

    func testConverterDoesNotRetainPrivateSpeechAfterResume() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.update(repeating: 0.75, count: 4_800)
        let pause = RecordingPause()
        let converter = try XCTUnwrap(AVAudioConverter(from: format, to: format))
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        pause.setPaused(true)
        try MicRecorder.append(buffer, to: XCTUnwrap(file), using: converter,
                               pause: pause, capturedGeneration: pause.captureGeneration)
        pause.setPaused(false)
        samples.update(repeating: 0, count: 4_800)
        try MicRecorder.append(buffer, to: XCTUnwrap(file), using: converter,
                               pause: pause, capturedGeneration: pause.captureGeneration)
        file = nil
        let reader = try AVAudioFile(forReading: url)
        let audio = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(reader.length)))
        try reader.read(into: audio)
        let result = try XCTUnwrap(audio.floatChannelData?[0])
        let peak = (0..<Int(audio.frameLength)).map { abs(result[$0]) }.max() ?? 0
        XCTAssertGreaterThan(audio.frameLength, 0)
        XCTAssertEqual(peak, 0, "paused speech must never reappear from converter history")
    }

}
