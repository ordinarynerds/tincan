import AppKit
import TincanCore

/// The one menu behind the menu bar switch and the floating bar's notes button, so both always offer
/// the same things in the same order.
@MainActor
enum NotesMenu {
    static let visibleNotes = 8

    static func listening(_ listeners: [Listener]) -> String {
        let names = listeners.map(\.name)
        switch names.count {
        case 0: return "No agent is listening"
        case 1: return "\(names[0]) is listening"
        default: return "\(names.dropLast().joined(separator: ", ")) and \(names[names.count - 1]) are listening"
        }
    }

    static func populate(_ menu: NSMenu, store: NoteStore, shortcut: Tincan.Shortcut?) {
        menu.removeAllItems()
        let toggle = ActionItem(Tincan.isActive ? "Stop Review Mode" : "Start Review Mode") { Tincan.toggle() }
        if let shortcut {
            toggle.keyEquivalent = shortcut.key
            toggle.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(toggle)
        menu.addItem(.separator())
        let listening = NSMenuItem(title: Self.listening(store.listeners(at: Date())), action: nil, keyEquivalent: "")
        listening.isEnabled = false
        listening.toolTip = "An agent listens by running `tincan watch --as <its name>`. Notes can be sent to it from the note sheet."
        menu.addItem(listening)
        menu.addItem(.separator())
        let open = store.notes(status: .open)
        let header = NSMenuItem(
            title: open.isEmpty ? "No open notes" : "\(open.count) open note\(open.count == 1 ? "" : "s")",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (index, note) in open.suffix(visibleNotes).enumerated() {
            let number = open.count - min(open.count, visibleNotes) + index + 1
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
        guard let bar = Tincan.floatingBar else { return }
        menu.addItem(.separator())
        let shown = bar.isShown
        let item = ActionItem(shown ? "Hide Floating Bar" : "Show Floating Bar") { Tincan.setFloatingBarShown(!shown) }
        if shown && !Tincan.hasStatusItem {
            item.isEnabled = false
            item.toolTip = "The menu bar switch is off, so the floating bar is the way back to review mode."
        }
        menu.addItem(item)
    }
}
