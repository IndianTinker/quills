import AppKit
import ArgumentParser
import FluidAudio
import Foundation

@main
struct Quills: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quills",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self, Models.self, MCPServerCommand.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    // NSApplication.run() MUST be entered directly from the main thread, not
    // from a main dispatch-queue block (which is the only way an async main
    // can reach it). The AppKit run loop started this way keeps draining the
    // main queue, so every `Task { @MainActor … }` (ticker ticks, transcript
    // status, MCP state callbacks) keeps executing. Entered from inside a
    // main-queue block instead, NSApp.run() runs the loop without servicing
    // the main queue and all MainActor work freezes for the process lifetime.
    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root)
        let controllerForSignals = controller

        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            Task { @MainActor in controllerForSignals.shutdown() }
        }
        sigint.resume()

        signal(SIGTERM, SIG_IGN)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        sigterm.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            Task { @MainActor in controllerForSignals.shutdown() }
        }
        sigterm.resume()

        FileHandle.standardError.write(Data(
            "quills up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Download the shared model before a meeting, rather than waiting for the
/// first finished recording. By default FluidAudio uses one user-level cache,
/// but `transcription.model_dir` can select another compatible directory.
struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "Manage the shared Parakeet transcription model."
    )

    @Flag(name: .long, help: "Download the shared multilingual Parakeet v3 model now.")
    var download = false

    func run() throws {
        guard download else {
            throw ValidationError("use `quills models --download`")
        }

        let cache = Config.transcriptionModelDir()
        if AsrModels.modelsExist(at: cache, version: .v3) {
            print("✓ shared Parakeet v3 model already installed")
            print("  \(cache.path)")
            return
        }

        print("downloading shared multilingual Parakeet v3 model…")
        switch SyncBridge.perform({ _ = try await AsrModels.download(to: cache, version: .v3) }) {
        case .success:
            print("✓ shared Parakeet v3 model installed")
            print("  \(cache.path)")
        case .failure(let error):
            throw error
        }
    }
}

/// Bridges async work into a synchronous subcommand. The main thread parks on
/// a semaphore while the work runs on the global concurrency pool, which has
/// no dependency on the main thread.
private enum SyncBridge {
    struct BridgeTimeout: Error {}

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Void, Error>?

        func store(_ result: Result<Void, Error>) {
            lock.lock()
            self.result = result
            lock.unlock()
        }

        func take() -> Result<Void, Error> {
            lock.lock()
            defer { lock.unlock() }
            return result ?? .failure(BridgeTimeout())
        }
    }

    static func perform(
        _ work: @escaping @Sendable () async throws -> Void
    ) -> Result<Void, Error> {
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await work()
                box.store(.success(()))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return box.take()
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private let mcpServer: MCPServerProcess
    private var session: RecordingSession?
    private var ticker: Timer?
    private var shuttingDown = false

    init(root: URL) {
        self.root = root
        mcpServer = MCPServerProcess(root: root, port: Config.mcpPort())
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onMCPStart = { [weak self] in self?.mcpServer.start() }
        menuBar.onMCPStop = { [weak self] in self?.mcpServer.stop() }
        menuBar.onMCPRestart = { [weak self] in self?.mcpServer.restart() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.onStorageChange = { [weak self] retention in
            do {
                try Config.setAudioRetention(retention)
                self?.menuBar.updateStorage(retention)
                if let self {
                    Task { [transcription = self.transcription, root = self.root] in
                        await transcription.applyAudioRetention(root: root)
                    }
                }
            } catch {
                notifyUser(title: "Quills — couldn't save storage setting", body: "\(error)")
            }
        }
        menuBar.update(recording: false, elapsed: nil)
        menuBar.updateMCP(state: mcpServer.state, port: mcpServer.port)
        mcpServer.onStateChange = { [weak self] state in
            self?.menuBar.updateMCP(state: state, port: self?.mcpServer.port ?? Config.defaultMCPPort)
        }
        QuillsMCPStatus.write(recording: false, transcriptionState: "idle")
        mcpServer.start()

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                await MainActor.run { [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        stopSession()
        // Do not wait for the child termination callback here. A child that
        // already exited can no longer deliver it, which would leave the menu
        // bar app unable to quit. The MCP process is asked to stop first and
        // also detects its parent's disappearance as a fallback.
        mcpServer.stop()
        menuBar.stop()
        NSApp.terminate(nil)
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession() {
        var newSession: RecordingSession?
        do {
            newSession = try RecordingSession(root: root)
            guard let newSession else { return }
            try newSession.start()
            session = newSession
            QuillsMCPStatus.write(
                recording: true,
                recordingSession: newSession.dir.lastPathComponent,
                transcriptionState: "idle"
            )
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            newSession?.discard()
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "Quills — recording failed", body: "\(error)")
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopSession() {
        guard let session else { return }
        let finalizationError: Error?
        do {
            try session.stop()
            finalizationError = nil
        } catch {
            finalizationError = error
            FileHandle.standardError.write(Data("recording finalization failed: \(error)\n".utf8))
            notifyUser(title: "Quills — recording finalization failed", body: "See the Quills log")
        }
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        if let finalizationError {
            QuillsMCPStatus.write(
                recording: false,
                transcriptionState: "failed",
                transcriptionSession: dir.lastPathComponent,
                error: "couldn't write meta.json: \(finalizationError)"
            )
            return
        }
        if Config.transcriptionEnabled() {
            QuillsMCPStatus.write(
                recording: false,
                transcriptionState: "queued",
                transcriptionSession: dir.lastPathComponent
            )
        } else {
            QuillsMCPStatus.write(
                recording: false,
                transcriptionState: "disabled",
                transcriptionSession: dir.lastPathComponent
            )
        }
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
            QuillsMCPStatus.write(recording: session != nil, transcriptionState: "idle")
        case .loadingModel(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "loading shared Parakeet v3 · \(name) · \(queued) queued" : "loading shared Parakeet v3 · \(name)"
            )
            QuillsMCPStatus.write(
                recording: session != nil,
                transcriptionState: "loading_model",
                transcriptionSession: name,
                queued: queued
            )
        case .transcribing(let name, let track, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(track) · \(name) · \(queued) queued" : "transcribing \(track) · \(name)"
            )
            QuillsMCPStatus.write(
                recording: session != nil,
                transcriptionState: "transcribing",
                transcriptionSession: name,
                transcriptionTrack: track,
                queued: queued
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
            QuillsMCPStatus.write(
                recording: session != nil,
                transcriptionState: "failed",
                transcriptionSession: name,
                error: "transcription failed"
            )
        }
    }

    private func tick() {
        guard let session else { return }
        menuBar.update(
            recording: true,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt))
        )
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
