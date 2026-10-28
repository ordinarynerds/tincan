import SwiftUI

/// The sheet a note is written in: what was picked, the words, and which pictures go with it.
struct Composer: View {
    struct Draft {
        var text = ""
        var attachElement: Bool
        var attachWindow: Bool
    }

    var title: String
    var isRegion: Bool
    var canAttach: Bool
    var save: (Draft) -> Void
    var cancel: () -> Void

    @State private var draft: Draft
    @FocusState private var focused: Bool

    init(
        title: String, isRegion: Bool, canAttach: Bool, attachElement: Bool, attachWindow: Bool,
        save: @escaping (Draft) -> Void, cancel: @escaping () -> Void
    ) {
        self.title = title
        self.isRegion = isRegion
        self.canAttach = canAttach
        self.save = save
        self.cancel = cancel
        _draft = State(initialValue: Draft(attachElement: attachElement, attachWindow: attachWindow))
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
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save Note") { save(Draft(text: trimmed, attachElement: draft.attachElement, attachWindow: draft.attachWindow)) }
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
