import AppKit
import SwiftUI
import TincanCore

/// The note sheet: writing a new note, opening one already left to edit, resolve, reopen or delete
/// it, and stepping through fixes to check.
extension ReviewSession {
    static let attachElementKey = "TincanAttachElement"
    static let attachWindowKey = "TincanAttachWindow"
    static let sendToKey = "TincanSendTo"
    static let resolvedInApp = "Marked resolved in the app"
    /// How long the app gets to draw the screen it navigated to before the sheet looks for the pin.
    static let settleAfterNavigating: Duration = .milliseconds(350)

    /// “In “Settings”, screen: General”: the window and the app's own context, as the header shows it.
    static func place(window: String, context: [String: String]) -> String {
        var parts: [String] = []
        if !window.isEmpty { parts.append("In “\(window)”") }
        parts += context.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        return parts.joined(separator: ", ")
    }

    /// The sheet showing now: whose words it holds, so they can be kept if the sheet is cancelled.
    struct Sheet {
        var overlay: Overlay
        var draftKey: String
        var original: String
        var text: String
    }

    static func draftKey(window: String, rect: CGRect) -> String {
        "new|\(window)|\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
    }

    // MARK: - A new note

    func compose(on overlay: Overlay, rect: CGRect, target: Note.Target) {
        guard let window = overlay.window, popover == nil else { return }
        overlay.view.pinned = rect
        overlay.view.highlight = nil
        let context = context()
        Task {
            let shot = await WindowCapture.capture(window)
            guard running, overlays[ObjectIdentifier(window)] != nil else {
                overlay.view.pinned = nil
                return
            }
            presentNew(on: overlay, window: window, rect: rect, target: target, context: context, shot: shot)
        }
    }

    private func presentNew(
        on overlay: Overlay, window: NSWindow, rect: CGRect, target: Note.Target, context: [String: String],
        shot: WindowCapture.Shot?
    ) {
        let defaults = UserDefaults.standard
        let element = shot.flatMap { WindowCapture.crop($0, to: rect) }
        let whole = shot.flatMap { WindowCapture.outlined($0, rect: rect) }
        let listeners = store.listeners(at: Date())
        let lastSent = defaults.string(forKey: Self.sendToKey) ?? ""
        let key = Self.draftKey(window: window.title, rect: rect)
        let text = drafts[key] ?? ""
        let composer = Composer(
            mode: .new(isRegion: target.kind == .region), title: target.summary,
            place: Self.place(window: window.title, context: context),
            pictures: .init(element: element.map(Self.image), window: whole.map(Self.image)),
            text: text,
            attachElement: defaults.object(forKey: Self.attachElementKey) as? Bool ?? true,
            attachWindow: defaults.object(forKey: Self.attachWindowKey) as? Bool ?? true,
            listeners: listeners,
            sendTo: listeners.first { $0.name.caseInsensitiveCompare(lastSent) == .orderedSame }?.name,
            restorable: text.isEmpty ? lastCancelled?.text : nil,
            textChanged: { [weak self] in self?.sheet?.text = $0 }
        ) { [weak self] action in
            guard let self else { return }
            if case .save(let draft) = action {
                defaults.set(draft.attachElement, forKey: Self.attachElementKey)
                defaults.set(draft.attachWindow, forKey: Self.attachWindowKey)
                if !listeners.isEmpty { defaults.set(draft.sendTo, forKey: Self.sendToKey) }
                let pictures = (
                    element: draft.attachElement ? element.flatMap(WindowCapture.png) : nil,
                    window: draft.attachWindow ? whole.flatMap(WindowCapture.png) : nil)
                save(draft, window: window, overlay: overlay, target: target, context: context, shot: shot, pictures: pictures)
                forgetDraft(key)
            }
            closeSheet(keepingWords: action.isCancel)
        }
        showSheet(composer, on: overlay, rect: rect, draftKey: key, original: "", text: text)
    }

    private func save(
        _ draft: Composer.Draft, window: NSWindow, overlay: Overlay, target: Note.Target, context: [String: String],
        shot: WindowCapture.Shot?, pictures: (element: Data?, window: Data?)
    ) {
        let info = Bundle.main.infoDictionary ?? [:]
        let now = Date()
        let note = Note(
            id: NoteStore.makeID(at: now),
            created: now,
            text: draft.text,
            app: Note.AppInfo(
                bundleID: Bundle.main.bundleIdentifier,
                name: (info["CFBundleName"] as? String) ?? ProcessInfo.processInfo.processName,
                version: info["CFBundleShortVersionString"] as? String,
                build: info["CFBundleVersion"] as? String),
            context: context,
            window: Note.WindowInfo(
                title: window.title, identifier: window.identifier?.rawValue,
                size: Note.Size(width: window.frame.width, height: window.frame.height),
                scale: Double(shot?.scale ?? window.backingScaleFactor)),
            target: target,
            handoff: draft.sendTo.map { Note.Handoff(agent: $0, sent: now) })
        do {
            let saved = try store.save(note, elementImage: pictures.element, windowImage: pictures.window)
            say(saved.handoff.map { "Sent to \($0.agent): note \(saved.id)." }
                ?? "Saved note \(saved.id). Click its pin to open it.", on: overlay)
        } catch {
            say("Could not save the note: \(error.localizedDescription)", on: overlay)
        }
        Tincan.refreshNotes()
    }

    // MARK: - A note already left

    /// Opens a note's sheet at its pin, starting from wherever the person asked: a pin, the notes
    /// list, a menu, or the next fix to check. When the note was left on another screen and the app
    /// can go there, it goes there first.
    func show(noteID: String, progress: Composer.Progress? = nil) {
        guard running, popover == nil, !presenting, let note = try? store.note(matching: noteID) else { return }
        guard !overlays.isEmpty else {
            pendingShow = { [weak self] in self?.show(noteID: noteID, progress: progress) }
            return
        }
        let wasHere = Tincan.isHere(note)
        if !wasHere, Tincan.go(to: note) {
            Tincan.locator.forget()
            Task {
                try? await Task.sleep(for: Self.settleAfterNavigating)
                guard running, popover == nil else { return }
                present(note, progress: progress)
            }
            return
        }
        present(note, progress: progress)
    }

    /// A fix to check is photographed first, so its sheet compares the note's picture with the spot
    /// as it is now. Everything else opens straight away.
    private func present(_ note: Note, progress: Composer.Progress?) {
        guard note.awaitsCheck, Tincan.isHere(note),
              let window = overlays.values.first(where: { $0.window?.title == note.window.title })?.window
        else { return presentSheet(note, progress: progress, after: nil) }
        let location = Tincan.locator.locate(note, in: window)
        guard location.placement != .missing else { return presentSheet(note, progress: progress, after: nil) }
        presenting = true
        Task {
            let after = await AfterPictures.take(of: note, in: window, at: location.rect, store: store)
            presenting = false
            guard running, popover == nil else { return }
            presentSheet(note, progress: progress, after: after)
        }
    }

    private func presentSheet(_ note: Note, progress: Composer.Progress?, after: NSImage?) {
        guard let overlay = overlays.values.first(where: { $0.window?.title == note.window.title }),
              let window = overlay.window
        else {
            if let any = overlays.values.first { say(Tincan.windowClosedReason(note), on: any) }
            continueChecking()
            return
        }
        window.makeKeyAndOrderFront(nil)
        let here = Tincan.isHere(note)
        let bounds = overlay.view.bounds
        let located = here ? Tincan.locator.locate(note, in: window).rect : .null
        let rect = located.intersection(bounds.insetBy(dx: 2, dy: 2))
        let anchor = rect.isNull || rect.isEmpty ? CGRect(x: bounds.midX - 1, y: bounds.midY - 1, width: 2, height: 2) : rect
        overlay.view.pinned = rect.isNull || rect.isEmpty ? nil : rect
        overlay.view.highlight = nil
        let id = note.id
        let key = "note|\(id)"
        let original = note.status == .open ? note.text : ""
        let composer = Composer(
            mode: note.status == .open ? .open(note) : .resolved(note), title: note.target.summary,
            place: Self.place(window: note.window.title, context: note.context),
            pictures: .init(
                element: store.imageURL(note.images.element).flatMap(NSImage.init(contentsOf:)),
                window: store.imageURL(note.images.window).flatMap(NSImage.init(contentsOf:)),
                after: after),
            text: drafts[key] ?? original, listeners: store.listeners(at: Date()),
            progress: progress, elsewhere: here ? nil : Tincan.elsewhere(note),
            textChanged: { [weak self] in self?.sheet?.text = $0 }
        ) { [weak self] action in
            guard let self else { return }
            let changed = act(action, on: id, overlay: overlay)
            if changed { forgetDraft(key) }
            closeSheet(keepingWords: action.isCancel)
            if checking != nil {
                if action.isCancel { checking = nil } else { continueChecking() }
            }
        }
        showSheet(composer, on: overlay, rect: anchor, draftKey: key, original: original, text: drafts[key] ?? original)
    }

    /// Does what the sheet asked. Answers whether the note changed, so the words typed are done with.
    private func act(_ action: Composer.Action, on id: String, overlay: Overlay) -> Bool {
        do {
            switch action {
            case .save(let draft):
                try store.edit(id, text: draft.text)
                if let agent = draft.sendTo {
                    try store.send(id, to: agent)
                    say("Saved and sent to \(agent).", on: overlay)
                } else {
                    say("Saved.", on: overlay)
                }
            case .resolve(let draft):
                try store.edit(id, text: draft.text)
                try store.resolve(id, summary: Self.resolvedInApp)
                try store.confirm(id)
                say("Resolved. Show Resolved Pins in the notes list to find it again.", on: overlay)
            case .reopen(let draft):
                try store.reopen(id, reason: draft.text)
                if let agent = draft.sendTo {
                    try store.send(id, to: agent)
                    say("Reopened and sent to \(agent).", on: overlay)
                } else {
                    say("Reopened. The agent sees what you wrote and the fix that did not hold.", on: overlay)
                }
            case .confirm:
                try store.confirm(id)
                say("Confirmed.", on: overlay)
            case .delete:
                try store.delete(id)
                say("Deleted.", on: overlay)
            case .skip, .cancel:
                return false
            }
        } catch {
            say("Could not change the note: \(error)", on: overlay)
            return false
        }
        Tincan.refreshNotes()
        return true
    }

    // MARK: - Checking fixes

    struct Checking {
        var queue: [String]
        var total: Int
        var done = 0
    }

    func checkFixes(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        checking = Checking(queue: ids, total: ids.count)
        guard popover == nil else { return }
        continueChecking()
    }

    /// Opens the next fix to check, or says the checking is over.
    func continueChecking() {
        guard var current = checking else { return }
        while let id = current.queue.first {
            current.queue.removeFirst()
            current.done += 1
            checking = current
            guard let note = try? store.note(matching: id), note.awaitsCheck else { continue }
            show(noteID: id, progress: .init(index: current.done, total: current.total))
            return
        }
        checking = nil
        if let overlay = overlays.values.first(where: { $0.window?.isKeyWindow == true }) ?? overlays.values.first {
            say("Every fix is checked.", on: overlay)
        }
    }

    // MARK: - The popover

    private func showSheet(
        _ composer: Composer, on overlay: Overlay, rect: CGRect, draftKey: String, original: String, text: String
    ) {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let hosting = NSHostingController(rootView: composer)
        popover.contentViewController = hosting
        popover.contentSize = NotesPanel.settledSize(of: hosting.view)
        self.popover = popover
        sheet = Sheet(overlay: overlay, draftKey: draftKey, original: original, text: text)
        Tincan.composingChanged(true)
        applyPassThrough()
        popover.show(relativeTo: rect.insetBy(dx: -2, dy: -2), of: overlay.view, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Closes the sheet. A cancelled sheet whose words changed keeps them, offered again next time.
    func closeSheet(keepingWords: Bool) {
        if keepingWords, let sheet {
            let text = sheet.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, sheet.text != sheet.original {
                drafts[sheet.draftKey] = sheet.text
                lastCancelled = (sheet.draftKey, sheet.text)
            }
        }
        popover?.close()
        popover = nil
        sheet?.overlay.view.pinned = nil
        sheet = nil
        Tincan.composingChanged(false)
        applyPassThrough()
    }

    private func forgetDraft(_ key: String) {
        drafts[key] = nil
        if lastCancelled?.key == key { lastCancelled = nil }
    }

    private static func image(_ image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: .zero)
    }

    func say(_ message: String, on overlay: Overlay) {
        overlay.view.flash = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if overlay.view.flash == message { overlay.view.flash = nil }
        }
    }
}

extension Composer.Action {
    var isCancel: Bool {
        if case .cancel = self { return true }
        return false
    }
}

extension ReviewSession {
    var isSheetOpen: Bool { popover != nil }

    /// A click outside the sheet closes it when nothing was typed, like any popover. With words in
    /// it, the click is ignored and the sheet says so, so a stray click never costs a sentence.
    func overlayClickedOutsideSheet(_ view: OverlayView) {
        guard let sheet else { return }
        if sheet.text == sheet.original {
            closeSheet(keepingWords: false)
            if checking != nil { checking = nil }
        } else {
            say("Save the note, or press Esc to put it aside.", on: sheet.overlay)
        }
    }

    func overlay(_ view: OverlayView, open pin: OverlayView.Pin) {
        guard popover == nil, overlay(for: view) != nil else { return }
        show(noteID: pin.noteID)
    }

    func overlay(_ view: OverlayView, menuFor pin: OverlayView.Pin) -> NSMenu? {
        guard let note = try? store.note(matching: pin.noteID) else { return nil }
        let menu = NSMenu()
        NotesMenu.actions(for: note, store: store).forEach(menu.addItem)
        return menu
    }
}
