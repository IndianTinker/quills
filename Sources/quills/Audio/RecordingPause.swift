import AVFoundation
import Foundation

/// Shared by both tracks. Holding the lock through each write means pause
/// returns only after any preceding audio write has finished. While paused,
/// only zero-filled buffers reach the encoder, preserving the session clock.
final class RecordingPause: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var generation: UInt64 = 0

    var captureGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    func setPaused(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if paused != value { generation &+= 1 }
        paused = value
    }

    func write(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile, capturedGeneration: UInt64? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        // Drop buffers crossing either transition, including buffers captured
        // during pause but still converting when resume is requested.
        guard paused || (capturedGeneration.map { $0 != generation } ?? false) else {
            try file.write(from: buffer)
            return
        }
        try file.write(from: Self.silence(matching: buffer))
    }

    /// Prevent private samples from entering a converter's retained history.
    func inputBuffer(_ buffer: AVAudioPCMBuffer, capturedGeneration: UInt64?) throws -> AVAudioPCMBuffer {
        lock.lock()
        defer { lock.unlock() }
        if paused || (capturedGeneration.map { $0 != generation } ?? false) {
            return try Self.silence(matching: buffer)
        }
        return buffer
    }

    private static func silence(matching buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let silence = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                             frameCapacity: buffer.frameLength) else {
            throw NSError(domain: "quills.pause", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't allocate paused audio buffer"])
        }
        silence.frameLength = buffer.frameLength
        for audioBuffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = audioBuffer.mData {
                memset(data, 0, Int(audioBuffer.mDataByteSize))
            }
        }
        return silence
    }
}
