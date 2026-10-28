import AppKit
import TincanCore

/// Everything that can be done to one note, defined once. The notes list, a pin's menu and the menu
/// bar switch's menu all draw from this list, so they always offer the same things in the same order.
@MainActor
struct NoteAction {
    var title: String
    /// Why the action can't be taken right now, shown as its help. Nil when it can.
    var unavailable: String?
    var help: String?
    var isDestructive = false
    /// Starts a new group, drawn with a separator before it.
    var startsGroup = false
    var perform: () -> Void

    static func all(for note: Note, store: NoteStore) -> [NoteAction] {
        let id = note.id
        var actions: [NoteAction] = []
        let opening: String
        switch note.status {
        case .open: opening = "Edit Note…"
        case .resolved: opening = note.awaitsCheck ? "Check Fix…" : "Reopen…"
        }
        actions.append(NoteAction(
            title: opening, unavailable: Tincan.whyNotOpenable(note),
            help: note.status == .open
                ? "Open the note at its pin to change its words, resolve it or delete it."
                : "Open the note at its pin to compare before and after, then confirm or reopen it."
        ) { Tincan.open(noteID: id) })
        switch note.status {
        case .open:
            actions.append(NoteAction(title: "Mark as Resolved", help: "Resolve it without opening it.") {
                _ = try? store.resolve(id, summary: ReviewSession.resolvedInApp)
                _ = try? store.confirm(id)
                Tincan.notesEdited()
            })
        case .resolved:
            if note.awaitsCheck {
                actions.append(NoteAction(title: "Looks Right", help: "Confirm the fix without opening it.") {
                    _ = try? store.confirm(id)
                    Tincan.notesEdited()
                })
            }
            actions.append(NoteAction(
                title: "Reopen Without a Reason", help: "Mark it open again straight away. The fix stays in the note’s history."
            ) {
                _ = try? store.reopen(id)
                Tincan.notesEdited()
            })
        }
        for listener in Tincan.state.listeners {
            actions.append(NoteAction(
                title: "Send to \(listener.name)",
                help: note.status == .resolved
                    ? "Reopen the note and hand it to \(listener.name) again."
                    : "\(listener.name) starts on this note \(listener.state == .waiting ? "now" : "after the note it is on")."
            ) {
                if note.status == .resolved { _ = try? store.reopen(id) }
                _ = try? store.send(id, to: listener.name)
                Tincan.notesEdited()
            })
        }
        let command = "tincan show \(NotesMenu.shortID(id, store: store))"
        actions.append(NoteAction(title: "Copy Note ID", startsGroup: true) { NotesMenu.copy(id) })
        actions.append(NoteAction(title: "Copy “\(command)”", help: "A line to paste to your agent.") { NotesMenu.copy(command) })
        actions.append(NoteAction(title: "Delete Note", isDestructive: true, startsGroup: true) {
            try? store.delete(id)
            Tincan.notesEdited()
        })
        return actions
    }

    var menuItem: NSMenuItem {
        let item = ActionItem(title, handler: perform)
        if let unavailable {
            item.isEnabled = false
            item.toolTip = unavailable
        } else {
            item.toolTip = help
        }
        return item
    }
}

/// The menu behind the menu bar switch's right click. The notes list is the main way in; this is the
/// same reach in menu form.
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
        let fixes = store.fixesToCheck().count
        let check = ActionItem(fixes == 0 ? "Check Fixes" : "Check \(fixes) Fix\(fixes == 1 ? "" : "es")…") { Tincan.checkFixes() }
        if fixes == 0 {
            check.isEnabled = false
            check.toolTip = "No fix is waiting. When an agent resolves a note, it waits here for you to look at it."
        }
        menu.addItem(check)
        menu.addItem(.separator())
        let listening = NSMenuItem(title: Self.listening(store.listeners(at: Date())), action: nil, keyEquivalent: "")
        listening.isEnabled = false
        listening.toolTip = "An agent listens by running `tincan watch --as <its name>`. Notes can be sent to it from the note sheet."
        menu.addItem(listening)
        menu.addItem(.separator())
        let open = store.notes(status: .open)
        menu.addItem(header(open.isEmpty ? "No open notes" : "\(open.count) open note\(open.count == 1 ? "" : "s")"))
        for (index, note) in open.suffix(visibleNotes).enumerated() {
            let number = open.count - min(open.count, visibleNotes) + index + 1
            menu.addItem(entry("\(number). \(note.text.prefix(60))", note: note, store: store))
        }
        menu.addItem(.separator())
        menu.addItem(resolvedItem(store: store))
        let pins = ActionItem("Show Resolved Pins") { Tincan.showsResolved.toggle() }
        pins.state = Tincan.showsResolved ? .on : .off
        pins.toolTip = "Pin resolved notes too, in grey with a check, so you can reopen one where it was left."
        menu.addItem(pins)
        menu.addItem(.separator())
        menu.addItem(ActionItem("Copy “tincan list” for Your Agent") { copy("tincan list") })
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

    /// The latest resolved notes, each with the way to check or reopen it.
    private static func resolvedItem(store: NoteStore) -> NSMenuItem {
        let resolved = store.notes(status: .resolved)
        let item = NSMenuItem(title: "Recently Resolved", action: nil, keyEquivalent: "")
        guard !resolved.isEmpty else {
            item.isEnabled = false
            item.toolTip = "No note has been resolved yet."
            return item
        }
        let submenu = NSMenu()
        let latest = resolved.sorted { ($0.resolution?.at ?? $0.created) > ($1.resolution?.at ?? $1.created) }
        for note in latest.prefix(visibleNotes) {
            submenu.addItem(entry(String(note.text.prefix(60)), note: note, store: store))
        }
        item.submenu = submenu
        return item
    }

    private static func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// One note, with everything that can be done to it in a submenu.
    private static func entry(_ title: String, note: Note, store: NoteStore) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.toolTip = "\(note.target.summary) in “\(note.window.title)”"
        if note.status == .resolved {
            item.image = NSImage(
                systemSymbolName: note.awaitsCheck ? "checkmark.seal" : "checkmark.circle",
                accessibilityDescription: note.awaitsCheck ? "Fix to check" : "Resolved")
        }
        let submenu = NSMenu()
        actions(for: note, store: store).forEach(submenu.addItem)
        item.submenu = submenu
        return item
    }

    /// A note's actions as menu items, with separators between groups.
    static func actions(for note: Note, store: NoteStore) -> [NSMenuItem] {
        NoteAction.all(for: note, store: store).flatMap { action in
            action.startsGroup ? [NSMenuItem.separator(), action.menuItem] : [action.menuItem]
        }
    }

    /// The four-letter end of an id, which `tincan` accepts on its own, or the whole id when another
    /// note ends the same way.
    static func shortID(_ id: String, store: NoteStore) -> String {
        let suffix = String(id.split(separator: "-").last ?? Substring(id))
        return (try? store.note(matching: suffix).id) == id ? suffix : id
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
