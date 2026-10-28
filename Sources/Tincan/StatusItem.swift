import AppKit
import TincanCore

/// Tincan's switch in the menu bar: whether review mode is on, how many notes are open, and the way
/// in and out without remembering a shortcut.
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
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.toolTip = "Tincan review mode"
        refresh()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    func refresh() {
        guard let button = item.button else { return }
        let active = Tincan.isActive
        let open = Tincan.state.openCount
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
        NotesMenu.populate(menu, store: store, shortcut: shortcut)
    }
}
