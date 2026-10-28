import AppKit
import TincanCore

/// Tincan's switch in the menu bar: whether review mode is on, how many notes are open, and the way
/// in and out without remembering a shortcut.
@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let store: NoteStore
    private let shortcut: Tincan.Shortcut?
    private var timer: Timer?

    init(store: NoteStore, shortcut: Tincan.Shortcut?) {
        self.store = store
        self.shortcut = shortcut
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.toolTip = "Tincan review mode"
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func remove() {
        timer?.invalidate()
        NSStatusBar.system.removeStatusItem(item)
    }

    func refresh() {
        guard let button = item.button else { return }
        let active = Tincan.isActive
        let open = store.notes(status: .open).count
        let image = NSImage(
            systemSymbolName: active ? "mappin.circle.fill" : "mappin.circle",
            accessibilityDescription: active ? "Review mode on" : "Review mode off")
        image?.isTemplate = !active
        button.image = active ? image?.withSymbolConfiguration(.init(paletteColors: [.white, Style.accent])) : image
        button.imagePosition = open > 0 ? .imageLeading : .imageOnly
        button.title = open > 0 ? "\(open)" : ""
        button.setAccessibilityLabel(
            "Tincan, review mode \(active ? "on" : "off"), \(open) open note\(open == 1 ? "" : "s")")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let toggle = ActionItem(Tincan.isActive ? "Stop Review Mode" : "Start Review Mode") { Tincan.toggle() }
        if let shortcut {
            toggle.keyEquivalent = shortcut.key
            toggle.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(toggle)
        menu.addItem(.separator())
        let open = store.notes(status: .open)
        let header = NSMenuItem(
            title: open.isEmpty ? "No open notes" : "\(open.count) open note\(open.count == 1 ? "" : "s")",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (index, note) in open.suffix(8).enumerated() {
            let number = open.count - min(open.count, 8) + index + 1
            let entry = ActionItem("\(number). \(note.text.prefix(60))") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.id, forType: .string)
            }
            entry.toolTip = "\(note.target.summary) in “\(note.window.title)”. Choose to copy the note id."
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Copy “tincan list” for Your Agent") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("tincan list", forType: .string)
        })
        menu.addItem(ActionItem("Show Notes in Finder") { [store] in
            try? store.prepare()
            NSWorkspace.shared.activateFileViewerSelecting([store.notesDirectory])
        })
    }
}
