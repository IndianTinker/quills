import AppKit

/// Model setup is independent of the recording lifecycle and runs asynchronously.
@MainActor
final class ModelsMenuController: NSObject, NSMenuDelegate {
    let item = NSMenuItem(title: "Models", action: nil, keyEquivalent: "")
    private let menu = NSMenu(title: "Models")
    private var modelItems: [NSMenuItem] = []
    private let customItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let browseItem = NSMenuItem(title: "Browse for existing model…", action: nil, keyEquivalent: "")
    private let revealItem = NSMenuItem(title: "Show selected model in Finder", action: nil, keyEquivalent: "")
    private let progressItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var busy = false

    override init() {
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        item.submenu = menu
        for (index, model) in SpeechModel.allCases.enumerated() {
            let entry = NSMenuItem(title: model.title, action: #selector(selectModel(_:)), keyEquivalent: "")
            entry.tag = index
            entry.target = self
            entry.toolTip = model.guidance
            modelItems.append(entry)
            menu.addItem(entry)
        }
        customItem.isEnabled = false
        menu.addItem(customItem)
        menu.addItem(.separator())
        browseItem.target = self
        browseItem.action = #selector(browse)
        menu.addItem(browseItem)
        revealItem.target = self
        revealItem.action = #selector(reveal)
        menu.addItem(revealItem)
        progressItem.isEnabled = false
        menu.addItem(progressItem)
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    private func refresh() {
        let selected = Config.modelSelection()
        item.title = busy ? "Models: preparing…" : "Models: \(selected.model.rawValue.replacingOccurrences(of: "parakeet-", with: ""))"
        for (index, entry) in modelItems.enumerated() {
            let model = SpeechModel.allCases[index]
            let installed = ModelSelection(model: model, directory: model.cacheDirectory, isCustom: false).isInstalled
            entry.title = model.title + (installed ? " · installed" : " · download")
            entry.state = selected.model == model && !selected.isCustom ? .on : .off
            entry.isEnabled = !busy
        }
        customItem.title = "Custom: \(selected.directory.lastPathComponent)" + (selected.isInstalled ? "" : " · missing files")
        customItem.toolTip = selected.directory.path
        customItem.isHidden = !selected.isCustom
        customItem.state = selected.isCustom ? .on : .off
        browseItem.isEnabled = !busy
        revealItem.isEnabled = FileManager.default.fileExists(atPath: selected.directory.path)
        progressItem.isHidden = !busy
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard !busy else { return }
        let model = SpeechModel.allCases[sender.tag]
        let selection = ModelSelection(model: model, directory: model.cacheDirectory, isCustom: false)
        prepare(selection)
    }

    private func prepare(_ selection: ModelSelection) {
        busy = true
        progressItem.title = selection.isInstalled ? "Checking model…" : "Downloading \(selection.model.rawValue)…"
        refresh()
        Task {
            defer { busy = false; refresh() }
            do {
                // Validate Core ML loading before replacing the saved preference.
                _ = try await selection.load()
                try Config.setModel(selection.model, directory: selection.isCustom ? selection.directory : nil)
                notifyUser(title: "Quills — model ready", body: "\(selection.model.title). Used from the next transcription session.")
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't select model"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc private func browse() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a compatible Parakeet Core ML model folder"
        panel.prompt = "Use model"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the model type, then its folder containing the Core ML bundles and vocabulary. Files are reused in place."
        let typePicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        typePicker.addItems(withTitles: SpeechModel.allCases.map(\.title))
        typePicker.selectItem(at: SpeechModel.allCases.firstIndex(of: Config.modelSelection().model) ?? 0)
        panel.accessoryView = typePicker
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let selection = ModelSelection(model: SpeechModel.allCases[typePicker.indexOfSelectedItem], directory: url, isCustom: true)
        prepare(selection)
    }

    @objc private func reveal() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Config.modelSelection().directory.path)
    }
}
