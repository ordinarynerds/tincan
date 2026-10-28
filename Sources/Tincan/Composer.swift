import SwiftUI
import TincanCore

/// The sheet a note is written in, opened again in, and checked in once an agent has fixed it.
///
/// One sheet for every stage of a note, so writing, editing, checking and reopening look and work the
/// same. The picture of what the note points at leads, because that is what the person recognises;
/// the accessibility name under it is for the agent.
struct Composer: View {
    enum Mode {
        /// A note being written. `isRegion` when it notes an area rather than one element.
        case new(isRegion: Bool)
        /// An open note, being read or rewritten.
        case open(Note)
        /// A resolved note: checked when the fix is new, otherwise read or reopened.
        case resolved(Note)
    }

    struct Draft {
        var text = ""
        var attachElement: Bool
        var attachWindow: Bool
        var sendTo: String?
    }

    enum Action {
        case save(Draft)
        case resolve(Draft)
        case reopen(Draft)
        case confirm
        case skip
        case delete
        case cancel
    }

    struct Pictures {
        var element: NSImage?
        var window: NSImage?
        var after: NSImage?
    }

    /// Which fix of how many, while stepping through fixes to check.
    struct Progress: Equatable {
        var index: Int
        var total: Int
    }

    var mode: Mode
    var title: String
    var place: String
    var pictures: Pictures
    var listeners: [Listener]
    var progress: Progress?
    /// Said when the note was left on another screen than the one showing.
    var elsewhere: String?
    /// Words cancelled on another note, offered back in case they were meant for this one.
    var restorable: String?
    var textChanged: (String) -> Void
    var act: (Action) -> Void

    @State var draft: Draft
    @State var confirmingDelete = false
    @State var stillWrong: Bool
    @FocusState var focused: Bool

    init(
        mode: Mode, title: String, place: String, pictures: Pictures, text: String = "",
        attachElement: Bool = true, attachWindow: Bool = true, listeners: [Listener], sendTo: String? = nil,
        progress: Progress? = nil, elsewhere: String? = nil, restorable: String? = nil,
        textChanged: @escaping (String) -> Void = { _ in }, act: @escaping (Action) -> Void
    ) {
        self.mode = mode
        self.title = title
        self.place = place
        self.pictures = pictures
        self.listeners = listeners
        self.progress = progress
        self.elsewhere = elsewhere
        self.restorable = restorable
        self.textChanged = textChanged
        self.act = act
        _draft = State(initialValue: Draft(text: text, attachElement: attachElement, attachWindow: attachWindow, sendTo: sendTo))
        if case .resolved(let note) = mode {
            _stillWrong = State(initialValue: !note.awaitsCheck)
        } else {
            _stillWrong = State(initialValue: false)
        }
    }

    var trimmed: String { draft.text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var finished: Draft {
        Draft(text: trimmed, attachElement: draft.attachElement, attachWindow: draft.attachWindow, sendTo: draft.sendTo)
    }

    var note: Note? {
        switch mode {
        case .new: nil
        case .open(let note), .resolved(let note): note
        }
    }

    /// A fix an agent made that the person has not looked at yet.
    var isCheckingFix: Bool { note?.awaitsCheck == true }

    var showsEditor: Bool {
        if case .resolved = mode { return stillWrong }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let progress {
                Text("Fix \(progress.index) of \(progress.total)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            pictureArea
            ComposerHeader(mode: mode, title: title, place: place, elsewhere: elsewhere)
            if case .resolved(let note) = mode {
                ResolvedSummary(note: note)
            }
            if showsEditor {
                editor
                if let restorable, draft.text.isEmpty {
                    Button("Use the words you cancelled: “\(restorable.prefix(40))\(restorable.count > 40 ? "…" : "")”") {
                        draft.text = restorable
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                if case .new = mode { windowChoice }
                ComposerSend(listeners: listeners, sendTo: $draft.sendTo, verb: sendVerb)
            }
            Divider()
            if confirmingDelete { deleteConfirmation } else { buttons }
        }
        .padding(14)
        .frame(width: 380)
        .background(cancelKey)
        .onChange(of: draft.text) { _, text in textChanged(text) }
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            focused = showsEditor
        }
    }

    /// Escape cancels. The sheet has no Cancel button: Escape and a click outside an untouched sheet
    /// both close it.
    private var cancelKey: some View {
        Button("Cancel") {
            if confirmingDelete { confirmingDelete = false } else { act(.cancel) }
        }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    // MARK: - The words

    private var placeholder: String {
        if case .resolved = mode { return "What is still wrong? Optional, and kept with the note." }
        return "What should change?"
    }

    private var editor: some View {
        TextEditor(text: $draft.text)
            .font(.body)
            .focused($focused)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: isResolvedMode ? 56 : 76, maxHeight: 180)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: focused ? .keyboardFocusIndicatorColor : .separatorColor)))
            .overlay(alignment: .topLeading) {
                if draft.text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(isResolvedMode ? "What is still wrong" : "Note")
    }

    private var isResolvedMode: Bool {
        if case .resolved = mode { return true }
        return false
    }

    // MARK: - Pictures

    @ViewBuilder
    private var pictureArea: some View {
        switch mode {
        case .new(let isRegion):
            if pictures.element != nil {
                HeroPicture(image: pictures.element, caption: nil, attach: $draft.attachElement,
                            attachLabel: isRegion ? "Attach the region" : "Attach the element")
            }
        case .open:
            if pictures.element != nil {
                HeroPicture(image: pictures.element, caption: nil, attach: nil, attachLabel: "")
            }
        case .resolved:
            if pictures.element != nil || pictures.after != nil {
                HStack(alignment: .top, spacing: 8) {
                    HeroPicture(image: pictures.element, caption: "Before", attach: nil, attachLabel: "")
                    HeroPicture(
                        image: pictures.after, caption: "After", attach: nil, attachLabel: "",
                        missing: "Taken once this spot is on screen")
                }
            }
        }
    }

    private var windowChoice: some View {
        WindowChoice(image: pictures.window, isOn: $draft.attachWindow)
    }

    private var sendVerb: ComposerSend.Verb {
        switch mode {
        case .new: .new
        case .open: .again
        case .resolved: .reopened
        }
    }
}
