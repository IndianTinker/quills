import AVFoundation
import XCTest
@testable import quills

final class MicRecorderTests: XCTestCase {
    func testRecoveryKeepsExistingAudioAndPadsGapWhenSampleRateChanges() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let target = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: target.settings)
        let writer = try XCTUnwrap(file)

        func appendTone(sampleRate: Double, value: Float, recoveryTime: TimeInterval? = nil) throws {
            let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
            let converter = try XCTUnwrap(AVAudioConverter(from: source, to: target))
            let tone = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(sampleRate)))
            tone.frameLength = tone.frameCapacity
            let data = try XCTUnwrap(tone.floatChannelData?[0])
            data.update(repeating: value, count: Int(tone.frameLength))
            try MicRecorder.append(tone, to: writer, using: converter, recoveryTime: recoveryTime)
        }

        try appendTone(sampleRate: 48_000, value: 0.25)
        XCTAssertEqual(writer.length, 48_000)
        // Recover at t=3 seconds using a Bluetooth-like 24 kHz route.
        try appendTone(sampleRate: 24_000, value: 0.5, recoveryTime: 3)
        XCTAssertEqual(Double(writer.length) / 48_000, 4, accuracy: 0.01)
        file = nil
        let reader = try AVAudioFile(forReading: url)
        let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reader.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(reader.length)))
        try reader.read(into: samples)
        let data = try XCTUnwrap(samples.floatChannelData?[0])
        XCTAssertEqual(data[24_000], 0.25, accuracy: 0.001, "existing speech must survive restart")
        XCTAssertEqual(data[96_000], 0, accuracy: 0.001, "the outage must retain its position on the timeline")
        XCTAssertEqual(data[168_000], 0.5, accuracy: 0.001, "recovered speech must resume at t=3 seconds")
    }
}
