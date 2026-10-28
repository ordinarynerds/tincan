import AppKit
import TincanCore

/// Tincan's switch in the menu bar: whether review mode is on, how many notes are open, and how many
/// fixes wait to be checked. A click opens the notes list; a right click opens the same reach as a menu.
@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let store: NoteStore
    private let shortcut: Tincan.Shortcut?

    init(store: NoteStore, shortcut: Tincan.Shortcut?) {
        self.store = store
        self.shortcut = shortcut
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "Tincan notes. Right-click for the menu."
        refresh()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func clicked() {
        guard let button = item.button else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            menu.delegate = self
            NotesMenu.populate(menu, store: store, shortcut: shortcut)
            item.menu = menu
            button.performClick(nil)
            item.menu = nil
            return
        }
        NotesPanel.toggle(relativeTo: button.bounds, of: button, edge: .minY)
    }

    func refresh() {
        guard let button = item.button else { return }
        let active = Tincan.isActive
        let open = Tincan.state.openCount
        let fixes = Tincan.state.fixesToCheck.count
        let image = NSImage(
            systemSymbolName: active ? "mappin.circle.fill" : "mappin.circle",
            accessibilityDescription: active ? "Review mode on" : "Review mode off")
        image?.isTemplate = !active
        button.image = active ? image?.withSymbolConfiguration(.init(paletteColors: [.white, Style.accent])) : image
        let title = [open > 0 ? "\(open)" : nil, fixes > 0 ? "✓\(fixes)" : nil].compactMap { $0 }.joined(separator: " ")
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.title = title
        button.setAccessibilityLabel(
            "Tincan, review mode \(active ? "on" : "off"), \(open) open note\(open == 1 ? "" : "s"), \(fixes) fix\(fixes == 1 ? "" : "es") to check")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        NotesMenu.populate(menu, store: store, shortcut: shortcut)
    }
}
