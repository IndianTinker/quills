import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let mcpStateLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let mcpStartItem: NSMenuItem
    private let mcpStopItem: NSMenuItem
    private let mcpRestartItem: NSMenuItem

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onMCPStart: (() -> Void)?
    var onMCPStop: (() -> Void)?
    var onMCPRestart: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        menu.addItem(.separator())

        mcpStateLabel = NSMenuItem(title: "MCP server: stopped", action: nil, keyEquivalent: "")
        mcpStateLabel.isEnabled = false
        menu.addItem(mcpStateLabel)

        mcpStartItem = NSMenuItem(
            title: "Start MCP server",
            action: #selector(mcpStartClicked),
            keyEquivalent: ""
        )
        mcpStopItem = NSMenuItem(
            title: "Stop MCP server",
            action: #selector(mcpStopClicked),
            keyEquivalent: ""
        )
        mcpRestartItem = NSMenuItem(
            title: "Restart MCP server",
            action: #selector(mcpRestartClicked),
            keyEquivalent: ""
        )
        menu.addItem(mcpStartItem)
        menu.addItem(mcpStopItem)
        menu.addItem(mcpRestartItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit quill",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, openFolder, mcpStartItem, mcpStopItem, mcpRestartItem, quit] {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            let image = Self.featherImage()
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
        }
    }

    /// Reflect recording state in the icon tint and menu item titles. The
    /// menu bar shows only the feather (red while recording); the elapsed
    /// counter lives in the menu's state label. Call once a second while
    /// recording.
    func update(recording: Bool, elapsed: String?) {
        stateLabel.title = recording ? "● recording · \(elapsed ?? "0:00")" : "idle"
        toggleItem.title = recording ? "Stop recording" : "Start recording"
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    /// Show transcription progress/failure both in the menu and directly in
    /// the status bar. Independent of recording state — a new recording can
    /// run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
        statusItem.button?.title = text == nil ? "" : "  \(statusBarTitle(for: text!))"
        statusItem.button?.toolTip = text
    }

    func updateMCP(state: MCPServerState, port: Int) {
        switch state {
        case .stopped:
            mcpStateLabel.title = "MCP server: stopped"
            mcpStartItem.isEnabled = true
            mcpStopItem.isEnabled = false
            mcpRestartItem.isEnabled = false
        case .starting:
            mcpStateLabel.title = "MCP server: starting…"
            mcpStartItem.isEnabled = false
            mcpStopItem.isEnabled = true
            mcpRestartItem.isEnabled = false
        case .running:
            mcpStateLabel.title = "MCP server: running · 127.0.0.1:\(port)"
            mcpStartItem.isEnabled = false
            mcpStopItem.isEnabled = true
            mcpRestartItem.isEnabled = true
        case .failed(let message):
            mcpStateLabel.title = "MCP server: failed · \(message)"
            mcpStartItem.isEnabled = true
            mcpStopItem.isEnabled = false
            mcpRestartItem.isEnabled = false
        }
    }

    private func statusBarTitle(for text: String) -> String {
        if text.hasPrefix("transcription failed") { return "Transcription failed" }
        if text.hasPrefix("loading") { return "Loading model…" }
        return "Transcribing…"
    }

    // Inlined Lucide feather SVG. Keeping it in source means the executable
    // has no separate resource bundle to install alongside it — true
    // single-binary.
    private static let featherSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
    <path d="M16 8 2 22"/>\
    <path d="M17.5 15H9"/>\
    </svg>
    """

    private static func featherImage() -> NSImage? {
        guard let data = featherSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func mcpStartClicked() { onMCPStart?() }
    @objc private func mcpStopClicked() { onMCPStop?() }
    @objc private func mcpRestartClicked() { onMCPRestart?() }
    @objc private func quitClicked() { onQuit?() }
}

enum MCPServerState: Equatable {
    case stopped
    case starting
    case running
    case failed(String)
}
