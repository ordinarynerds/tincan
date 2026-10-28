import SwiftUI
import TincanCore

/// The sheet a note is written in: what was picked, the words, which pictures go with it, and
/// whether a listening agent should start on it now.
struct Composer: View {
    struct Draft {
        var text = ""
        var attachElement: Bool
        var attachWindow: Bool
        var sendTo: String?
    }

    var title: String
    var isRegion: Bool
    var canAttach: Bool
    var listeners: [Listener]
    var save: (Draft) -> Void
    var cancel: () -> Void

    @State private var draft: Draft
    @FocusState private var focused: Bool

    init(
        title: String, isRegion: Bool, canAttach: Bool, attachElement: Bool, attachWindow: Bool,
        listeners: [Listener], sendTo: String?,
        save: @escaping (Draft) -> Void, cancel: @escaping () -> Void
    ) {
        self.title = title
        self.isRegion = isRegion
        self.canAttach = canAttach
        self.listeners = listeners
        self.save = save
        self.cancel = cancel
        _draft = State(initialValue: Draft(attachElement: attachElement, attachWindow: attachWindow, sendTo: sendTo))
    }

    static let nobodyListening =
        "No agent is listening. Ask your agent to run `tincan watch --as <its name>` while you review."

    static func sendLabel(_ listener: Listener) -> String {
        switch listener.state {
        case .waiting: "Send to \(listener.name) now"
        case .working: "Send to \(listener.name), next after the note it is on"
        }
    }

    @ViewBuilder
    private var send: some View {
        switch listeners.count {
        case 0:
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Send to your agent now", isOn: .constant(false))
                    .disabled(true)
                    .accessibilityLabel("Send to your agent now. \(Self.nobodyListening)")
                Text(Self.nobodyListening)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
                    .accessibilityHidden(true)
            }
            .help(Self.nobodyListening)
        case 1:
            let listener = listeners[0]
            Toggle(Self.sendLabel(listener), isOn: Binding(
                get: { draft.sendTo != nil },
                set: { draft.sendTo = $0 ? listener.name : nil }))
                .help("\(listener.name) starts on this note as soon as you save it. Unchecked, it waits until you ask for your notes.")
        default:
            Picker("Send now to", selection: $draft.sendTo) {
                Text("Nobody, it waits until you ask").tag(String?.none)
                ForEach(listeners, id: \.name) { listener in
                    Text(listener.state == .waiting ? listener.name : "\(listener.name), after the note it is on")
                        .tag(Optional(listener.name))
                }
            }
            .help("The agent you pick starts on this note as soon as you save it.")
        }
    }

    private var trimmed: String { draft.text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
            TextEditor(text: $draft.text)
                .font(.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 84, maxHeight: 180)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                .overlay(alignment: .topLeading) {
                    if draft.text.isEmpty {
                        Text("What should change?")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isRegion ? "Attach a screenshot of this region" : "Attach a screenshot of this element",
                       isOn: $draft.attachElement)
                Toggle("Attach the whole window", isOn: $draft.attachWindow)
            }
            .disabled(!canAttach)
            .help(canAttach ? "" : "This window could not be captured.")
            send
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(draft.sendTo == nil ? "Save Note" : "Send Note") {
                    save(Draft(text: trimmed, attachElement: draft.attachElement, attachWindow: draft.attachWindow, sendTo: draft.sendTo))
                }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
                    .help(trimmed.isEmpty ? "Write the note first." : "Save (⌘↩)")
            }
        }
        .padding(14)
        .frame(width: 340)
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            focused = true
        }
    }
}
