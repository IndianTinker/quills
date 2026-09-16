import Foundation

/// Owns the local MCP child process. The menu-bar app is its parent, so an
/// explicit Quill shutdown always stops the MCP server first.
@MainActor
final class MCPServerProcess {
    let port: Int
    private var process: Process?
    private var stopping = false
    private var stopCompletion: (() -> Void)?

    private(set) var state: MCPServerState = .stopped {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((MCPServerState) -> Void)?

    init(port: Int) {
        self.port = port
    }

    func start() {
        guard process == nil else { return }
        guard let binary = Self.binaryPath() else {
            state = .failed("binary not found")
            return
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: binary)
        child.arguments = ["mcp", "--port", String(port)]
        child.standardOutput = FileHandle.standardOutput
        child.standardError = FileHandle.standardError
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.childDidExit()
            }
        }

        state = .starting
        stopping = false
        do {
            try child.run()
            process = child
            state = .running
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        guard let process else {
            state = .stopped
            completion?()
            return
        }

        stopCompletion = completion
        stopping = true
        process.terminate()
    }

    func restart() {
        stop { [weak self] in
            self?.start()
        }
    }

    private func childDidExit() {
        process = nil
        let completion = stopCompletion
        stopCompletion = nil

        if stopping {
            stopping = false
            state = .stopped
        } else {
            state = .failed("process exited")
        }
        completion?()
    }

    private static func binaryPath() -> String? {
        let installed = "/usr/local/bin/quill"
        if FileManager.default.isExecutableFile(atPath: installed) {
            return installed
        }

        if let argv0 = CommandLine.arguments.first,
           argv0.hasPrefix("/"),
           FileManager.default.isExecutableFile(atPath: argv0) {
            return argv0
        }
        return nil
    }
}
