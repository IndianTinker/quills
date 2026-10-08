import AVFoundation
import Foundation

/// Records the default input device to a file via AVAudioEngine, encoding AAC
/// mono. Buffers stream straight to disk — nothing is held in memory, so
/// session length is unbounded.
///
/// With voice processing on, Apple's echo canceller subtracts
/// speaker playback from the mic so the system track doesn't bleed into the
/// mic track. VoiceProcessingIO is a duplex unit, not an input effect: it
/// needs a rendered output path and one explicit mono client format on both
/// sides, or it silently delivers zeroed buffers (rca-001). A first-second
/// liveness check catches routes where even the correct graph stays silent
/// and restarts capture raw.
final class MicRecorder: @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported(AVAudioFormat)

        var description: String {
            switch self {
            case .engineStartFailed(let e): return "mic engine start failed: \(e)"
            case .fileCreationFailed(let e): return "mic file creation failed: \(e)"
            case .formatUnsupported(let f): return "can't downmix mic format \(f)"
            }
        }
    }

    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var url: URL?
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var watchdog: Timer?
    private var lastBufferAt: Date?
    private var captureStartedAt = Date()
    private var padRecoveryGap = false
    private var warnedAboutFailure = false
    private let stateLock = NSLock()
    private var recording = false
    private var firstBufferAtStorage: Date?
    private var isRecording: Bool { withState { recording } }
    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    var firstBufferAt: Date? { withState { firstBufferAtStorage } }

    // Liveness check state (voice-processing path only). Written from the tap
    // callback, read on main when deciding to fall back.
    private var livenessFrames = 0
    private var livenessPeak: Float = 0
    private var livenessSettled = false

    /// Start capturing the mic, encoding AAC into `url` (use a .caf extension
    /// — CAF needs no finalization pass, so a crash loses nothing written).
    func start(writingTo url: URL) throws {
        guard !isRecording else { return }
        self.url = url
        warnedAboutFailure = false
        padRecoveryGap = false
        withState {
            firstBufferAtStorage = nil
            file = nil
        }
        try attach(voiceProcessing: Config.micVoiceProcessing())
        withState { recording = true }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isRecording else { return }
            let last = self.withState { self.lastBufferAt ?? self.captureStartedAt }
            if Date().timeIntervalSince(last) > 3 {
                self.recover(reason: "no microphone buffers for 3 seconds")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        withState { recording = false }
        watchdog?.invalidate()
        watchdog = nil
        tearDownEngine()
        withState { file = nil }
    }

    // MARK: -

    /// Build the engine graph, create the AAC file, and start capture. Called
    /// at start and again after interruptions. Reuse the open file so a
    /// restart never truncates the microphone audio already captured.
    private func attach(voiceProcessing: Bool) throws {
        captureStartedAt = Date()
        withState { lastBufferAt = nil }
        engine = AVAudioEngine()
        let input = engine.inputNode

        var voice = voiceProcessing
        if voice {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The live voice unit makes macOS treat the session like a
                // call and duck all other audio — meetings played through the
                // speakers would get quieter the moment recording starts.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: mic voice processing unavailable (\(error)) — recording raw mic\n".utf8
                ))
                voice = false
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)

        // One explicit mono client format. With voice processing this is the
        // Voice I/O boundary format on both sides of the duplex unit — never
        // accept the inherited multichannel route format (a 9-channel device
        // yielded digital silence). Raw capture downmixes to the same shape;
        // speech models want one channel anyway.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: monoFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        if withState({ file == nil }) {
            do {
                let newFile = try AVAudioFile(
                    forWriting: url!,
                    settings: settings,
                    commonFormat: monoFormat.commonFormat,
                    interleaved: monoFormat.isInterleaved
                )
                withState { file = newFile }
            } catch {
                throw RecorderError.fileCreationFailed(error)
            }
        }

        if voice {
            // Complete the duplex graph: VoiceProcessingIO must render to an
            // output device or the input side never produces audio. The mixer
            // has no sources — nothing is monitored or played — its connection
            // exists solely to give the unit a formatted output path.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)
            livenessFrames = 0
            livenessPeak = 0
            livenessSettled = false
            try installVoiceTap(on: input, format: monoFormat)
        } else {
            try installRawTap(on: input, inputFormat: inputFormat)
        }

        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw RecorderError.engineStartFailed(error)
        }

        let engineID = ObjectIdentifier(engine)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // Apple's notification arrives on an internal audio queue. Tear
            // down only after returning from that handler, on the main queue.
            DispatchQueue.main.async { [weak self] in
                guard let self, ObjectIdentifier(self.engine) == engineID,
                      self.isRecording else { return }
                if !self.engine.isRunning {
                    self.recover(reason: "audio device configuration changed")
                }
            }
        }

        let report = "mic: voiceProcessing=\(input.isVoiceProcessingEnabled) "
            + "input=\(input.outputFormat(forBus: 0)) tap=\(monoFormat)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    /// Voice-processing path: the unit converts to the mono client format
    /// itself, so tapped buffers write straight to the file. Tracks signal
    /// peak over the first second — an unsupported route (device pair, macOS
    /// AUVPAggregate defects) delivers callbacks full of digital zeros, and
    /// the only recovery is restarting raw.
    private func installVoiceTap(on input: AVAudioInputNode, format: AVAudioFormat) throws {
        guard let target = withState({ file?.processingFormat }),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw RecorderError.formatUnsupported(format)
        }
        let checkFrames = Int(format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let file = self.activeFile() else { return }

            if !self.livenessSettled {
                let frames = Int(buffer.frameLength)
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<frames {
                        self.livenessPeak = max(self.livenessPeak, abs(data[i]))
                    }
                }
                self.livenessFrames += frames
                if self.livenessFrames >= checkFrames {
                    self.livenessSettled = true
                    if self.livenessPeak == 0 {
                        DispatchQueue.main.async { self.fallBackToRaw() }
                        return
                    }
                }
            }

            do {
                try self.write(buffer, to: file, using: converter)
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
            }
        }
    }

    /// Raw path: tap at the device's native format and convert to the original
    /// file's mono format, which may have a different sample rate after recovery.
    private func installRawTap(
        on input: AVAudioInputNode,
        inputFormat: AVAudioFormat
    ) throws {
        guard let target = withState({ file?.processingFormat }),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let file = self.activeFile() else { return }
            do {
                try self.write(buffer, to: file, using: converter)
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
            }
        }
    }

    /// Keep the original file format across route changes, including sample
    /// rate changes (for example, a Bluetooth headset entering call mode).
    private func write(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile,
                       using converter: AVAudioConverter) throws {
        let recoveryTime = padRecoveryGap ? firstBufferAt.map { Date().timeIntervalSince($0) } : nil
        try Self.append(buffer, to: file, using: converter, recoveryTime: recoveryTime)
        padRecoveryGap = false
    }

    /// The file-writing path is independent of hardware so route changes and
    /// interruption timing can be verified with generated audio.
    static func append(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile,
                       using converter: AVAudioConverter, recoveryTime: TimeInterval? = nil) throws {
        let target = file.processingFormat
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength)
            * target.sampleRate / buffer.format.sampleRate)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        let source = ConverterInput(buffer)
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if source.supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            source.supplied = true
            inputStatus.pointee = .haveData
            return source.buffer
        }
        if status == .error {
            throw error ?? NSError(domain: "quills.mic.converter", code: 1)
        }
        // Preserve transcript timing across an interruption. Appending without
        // silence would shift all subsequent microphone speech earlier.
        if let recoveryTime {
            let expected = AVAudioFramePosition(recoveryTime * target.sampleRate)
            var remaining = max(0, expected - file.length)
            if let silence = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) {
                while remaining > 0 {
                    silence.frameLength = AVAudioFrameCount(min(remaining, 4096))
                    if let samples = silence.floatChannelData?[0] {
                        samples.update(repeating: 0, count: Int(silence.frameLength))
                    }
                    try file.write(from: silence)
                    remaining -= AVAudioFramePosition(silence.frameLength)
                }
            }
        }
        if converted.frameLength > 0 { try file.write(from: converted) }
    }

    private func tearDownEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    // AVAudioConverter invokes its input block synchronously during convert;
    // this state is local to that invocation and never shared between taps.
    private final class ConverterInput: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var supplied = false
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    private func recover(reason: String) {
        guard isRecording else { return }
        FileHandle.standardError.write(Data("warning: mic interrupted (\(reason)) — restarting capture\n".utf8))
        tearDownEngine()
        padRecoveryGap = true
        do {
            try attach(voiceProcessing: false)
        } catch {
            // Keep the open file and retry on the watchdog's next interval.
            FileHandle.standardError.write(Data("mic restart failed: \(error)\n".utf8))
        }
        if !warnedAboutFailure {
            warnedAboutFailure = true
            notifyUser(title: "Quills — microphone interrupted",
                       body: "Microphone capture was interrupted. Quills is attempting to resume it; check your audio input.")
        }
    }

    /// The voice-processing route delivered a full second of digital silence:
    /// tear the engine down and restart raw, discarding the silent prefix so
    /// the track's timestamps start at real audio.
    private func fallBackToRaw() {
        guard isRecording else { return }
        FileHandle.standardError.write(Data(
            "warning: voice processing delivered silence — restarting mic raw\n".utf8
        ))
        tearDownEngine()
        withState {
            file = nil
            firstBufferAtStorage = nil
        }
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            try attach(voiceProcessing: false)
        } catch {
            FileHandle.standardError.write(Data(
                "mic raw fallback failed: \(error) — session continues without mic track\n".utf8
            ))
            withState { file = nil }
        }
    }

    /// The tap runs on Core Audio's thread while start/stop run on the main
    /// thread. Copy a strong file reference under a short lock, then perform
    /// the potentially slow file write after releasing it.
    private func activeFile() -> AVAudioFile? {
        withState {
            guard recording, let file else { return nil }
            lastBufferAt = Date()
            if firstBufferAtStorage == nil { firstBufferAtStorage = Date() }
            return file
        }
    }

    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
