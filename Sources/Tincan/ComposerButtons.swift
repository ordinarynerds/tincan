import SwiftUI
import TincanCore

/// The sheet's last row: one primary action per stage, the second choice beside it, and delete as an
/// icon on the far side, asking again in place before it removes anything.
extension Composer {
    static let needsWords = "A note needs words. Delete it instead if nothing should change."

    @ViewBuilder
    var buttons: some View {
        HStack(spacing: 8) {
            switch mode {
            case .new:
                Text("Esc cancels")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(draft.sendTo == nil ? "Save Note" : "Send Note") { act(.save(finished)) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
                    .help(trimmed.isEmpty ? "Write the note first." : "Save the note (⌘↩)")
            case .open:
                deleteButton
                Spacer()
                Button("Resolve") { act(.resolve(finished)) }
                    .disabled(trimmed.isEmpty)
                    .help(trimmed.isEmpty ? Self.needsWords : "Save any changes and mark the note as handled")
                Button(draft.sendTo == nil ? "Save" : "Save and Send") { act(.save(finished)) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
                    .help(trimmed.isEmpty ? Self.needsWords : "Save the changes (⌘↩)")
            case .resolved:
                deleteButton
                Spacer()
                if progress != nil {
                    Button("Skip") { act(.skip) }
                        .help("Leave this fix unchecked and go to the next one")
                }
                if stillWrong {
                    if isCheckingFix {
                        Button("Back") { stillWrong = false }
                            .help("Go back to confirming the fix")
                    }
                    Button(draft.sendTo == nil ? "Reopen" : "Reopen and Send") { act(.reopen(finished)) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .help("Mark the note open again (⌘↩). The fix that did not hold stays in its history.")
                } else {
                    Button("Still Wrong…") {
                        stillWrong = true
                        focused = true
                    }
                    .help("Say what is still wrong and reopen the note")
                    Button("Looks Right") { act(.confirm) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .help("The fix is right (⌘↩). The note stays resolved and stops asking to be checked.")
                }
            }
        }
    }

    var deleteButton: some View {
        Button {
            confirmingDelete = true
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("Delete the note and its pictures")
        .accessibilityLabel("Delete note")
    }

    var deleteConfirmation: some View {
        HStack {
            Text("Delete this note and its pictures?")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Keep") { confirmingDelete = false }
                .help("Keep the note (Esc)")
            Button("Delete", role: .destructive) { act(.delete) }
                .keyboardShortcut(.defaultAction)
        }
    }
}
