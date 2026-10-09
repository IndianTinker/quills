import AppKit
import QuartzCore

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
    private var recordingShortcut: RecordingShortcut?
    private let modelsMenu = ModelsMenuController()
    private var statusMenu: NSMenu?
    private let recordingDot = RecordingDotView(frame: .zero)
    private let featherView = StatusFeatherView(frame: .zero)
    private var transcriptionText: String?
    private var storageItems: [NSMenuItem] = []

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onMCPStart: (() -> Void)?
    var onMCPStop: (() -> Void)?
    var onMCPRestart: (() -> Void)?
    var onQuit: (() -> Void)?
    var onStorageChange: ((AudioRetention) -> Void)?

    private var isRecording = false
    private var isProcessingTranscript = false

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(modelsMenu.item)

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

        let storage = NSMenuItem(title: "Storage", action: nil, keyEquivalent: "")
        let storageMenu = NSMenu(title: "Storage")
        storageMenu.autoenablesItems = false
        for (index, retention) in AudioRetention.allCases.enumerated() {
            let item = NSMenuItem(title: retention.title, action: #selector(storageClicked(_:)), keyEquivalent: "")
            item.tag = index
            storageItems.append(item)
            storageMenu.addItem(item)
        }
        storage.submenu = storageMenu
        menu.addItem(storage)

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
            title: "Quit Quills",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, openFolder, mcpStartItem, mcpStopItem, mcpRestartItem, quit] + storageItems {
            item.target = self
        }
        updateStorage(Config.audioRetention())

        statusMenu = menu
        recordingShortcut = RecordingShortcut { [weak self] in self?.onToggle?() }
        if recordingShortcut != nil {
            toggleItem.keyEquivalentModifierMask = [.command, .option, .control]
        } else {
            toggleItem.keyEquivalent = ""
            toggleItem.toolTip = "The global recording shortcut could not be registered."
            FileHandle.standardError.write(Data("warning: recording shortcut ⌃⌥⌘R unavailable (possibly already in use)\n".utf8))
        }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            let image = Self.featherImage()
            image?.isTemplate = false
            featherView.image = image
            featherView.wantsLayer = true
            featherView.translatesAutoresizingMaskIntoConstraints = false
            featherView.setAccessibilityElement(false)
            button.addSubview(featherView)
            recordingDot.translatesAutoresizingMaskIntoConstraints = false
            recordingDot.isHidden = true
            recordingDot.setAccessibilityElement(false)
            button.addSubview(recordingDot)
            NSLayoutConstraint.activate([
                featherView.widthAnchor.constraint(equalToConstant: 16),
                featherView.heightAnchor.constraint(equalToConstant: 16),
                featherView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                featherView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                recordingDot.widthAnchor.constraint(equalToConstant: 5),
                recordingDot.heightAnchor.constraint(equalToConstant: 5),
                recordingDot.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: 8),
                recordingDot.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: button.isFlipped ? 7 : -7)
            ])
        }
    }

    /// Reflect recording state in the icon tint and menu item titles. The
    /// menu bar shows a white feather with a red dot while recording, pulsing while a
    /// model loads or a transcript is produced); the elapsed counter lives in the menu's
    /// state label. Call once a second while recording.
    func update(recording: Bool, elapsed: String?) {
        isRecording = recording
        recordingDot.isHidden = !recording
        stateLabel.title = recording ? "● recording · \(elapsed ?? "0:00")" : "idle"
        toggleItem.title = recording ? "Stop recording" : "Start recording"
        refreshToolTip()
        refreshIconTint()
    }

    /// Show transcription progress/failure both in the menu and directly in
    /// the status bar. Independent of recording state — a new recording can
    /// run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionText = text
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
        // Keep the status item one fixed icon wide, including on failure.
        // Details remain in the menu and tooltip.
        let failed = text?.hasPrefix("transcription failed") ?? false
        refreshToolTip()
        isProcessingTranscript = text != nil && !failed
        refreshIconTint()
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
            mcpStateLabel.title = "MCP server: running · http://127.0.0.1:\(port)/mcp"
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

    func stop() {
        recordingShortcut?.stop()
        setPulsing(false)
    }

    func updateStorage(_ retention: AudioRetention) {
        for item in storageItems {
            item.state = AudioRetention.allCases[item.tag] == retention ? .on : .off
        }
    }

    @objc private func storageClicked(_ sender: NSMenuItem) {
        onStorageChange?(AudioRetention.allCases[sender.tag])
    }

    private func refreshToolTip() {
        var lines = [isRecording ? stateLabel.title : "Quills · idle"]
        if let transcriptionText { lines.append(transcriptionText) }
        lines.append("Option-click · start/stop recording")
        if recordingShortcut != nil { lines.append("⌃⌥⌘R · start/stop recording") }
        statusItem.button?.toolTip = lines.joined(separator: "\n")
        statusItem.button?.setAccessibilityLabel(lines.joined(separator: ". "))
    }

    private func refreshIconTint() {
        setPulsing(isProcessingTranscript && !isRecording)
    }

    /// Use the same continuous pulse for model loading and transcription.
    private func setPulsing(_ on: Bool) {
        guard let layer = featherView.layer else { return }
        if on {
            guard layer.animation(forKey: "transcriptionPulse") == nil else { return }
            // Core Animation renders the pulse independently of main-run-loop
            // timers, so heavy model loading cannot stall the animation.
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.25
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            layer.add(pulse, forKey: "transcriptionPulse")
            CATransaction.flush()
        } else {
            layer.removeAnimation(forKey: "transcriptionPulse")
            layer.opacity = 1
        }
    }

    // Inlined Lucide feather SVG. Keeping it in source means the executable
    // has no separate resource bundle to install alongside it — true
    // single-binary.
    private static let featherSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="#ffffff" stroke-width="1.5" \
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

    @objc private func statusClicked() {
        if let event = NSApp.currentEvent,
           event.type == .leftMouseUp,
           event.modifierFlags.contains(.option) {
            onToggle?()
        } else {
            showMenu()
        }
    }

    private func showMenu() {
        guard let button = statusItem.button, let statusMenu else { return }
        statusItem.menu = statusMenu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func mcpStartClicked() { onMCPStart?() }
    @objc private func mcpStopClicked() { onMCPStop?() }
    @objc private func mcpRestartClicked() { onMCPRestart?() }
    @objc private func quitClicked() { onQuit?() }
}

/// Mouse events pass through both decorative views to the status button.
@MainActor
private final class StatusFeatherView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class RecordingDotView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

enum MCPServerState: Equatable {
    case stopped
    case starting
    case running
    case failed(String)
}
