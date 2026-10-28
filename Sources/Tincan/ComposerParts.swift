import SwiftUI
import TincanCore

/// What the note points at, where, and for a note already left, how old it is and where it went.
struct ComposerHeader: View {
    var mode: Composer.Mode
    var title: String
    var place: String
    var elsewhere: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if !place.isEmpty {
                Text(place)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let facts {
                Text(facts)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let elsewhere {
                Label(elsewhere, systemImage: "arrow.uturn.right")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var facts: String? {
        switch mode {
        case .new: nil
        case .open(let note), .resolved(let note): Self.facts(note, now: Date())
        }
    }

    /// When the note was left, whether it was rewritten or came back, and which agent has it.
    static func facts(_ note: Note, now: Date) -> String {
        var parts = ["Left \(age(note.created, now: now))"]
        if let edited = note.history.last(where: { $0.kind == .edited }) {
            parts.append("edited \(age(edited.at, now: now))")
        }
        if note.status == .open, let reopening = note.lastReopening {
            parts.append("reopened \(age(reopening.reopened.at, now: now))")
        }
        if note.status == .open, let handoff = note.handoff {
            parts.append(handoff.delivered == nil ? "waiting for \(handoff.agent)" : "handed to \(handoff.agent)")
        }
        return parts.joined(separator: ", ")
    }

    static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86_400) d ago"
        }
    }
}

/// A resolved note's own words and what the agent said it changed, so the person can judge the fix
/// before deciding whether it holds.
struct ResolvedSummary: View {
    var note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            labelled("You wrote", note.text)
            labelled(
                "Fixed \(ComposerHeader.age(note.resolution?.at ?? note.created, now: Date()))",
                note.resolution?.summary ?? "No summary was given.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func labelled(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The picture of what the note points at, as large as the sheet allows: it is how the person knows
/// the sheet is about the right thing. With `attach`, a checkbox on the picture keeps it with the
/// note or leaves it out, and clicking the picture does the same.
struct HeroPicture: View {
    var image: NSImage?
    var caption: String?
    var attach: Binding<Bool>?
    var attachLabel: String
    var missing = "No picture"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomLeading) {
                Color(nsColor: .quaternaryLabelColor).opacity(0.35)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(attach?.wrappedValue == false ? 0.35 : 1)
                        .accessibilityLabel(caption ?? "What the note points at")
                } else {
                    Text(missing)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let attach, image != nil {
                    Toggle(attachLabel, isOn: attach)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                        .help(attach.wrappedValue ? "Saved with the note. Uncheck to leave it out." : "Left out of the note.")
                }
            }
            .frame(height: caption == nil ? 132 : 104)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .contentShape(Rectangle())
            .onTapGesture { attach?.wrappedValue.toggle() }
            if let caption {
                Text(caption)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The whole window as a small chip beside its checkbox: worth keeping for where the target sits,
/// too small at this size to be worth looking at.
struct WindowChoice: View {
    var image: NSImage?
    @Binding var isOn: Bool

    static let missing = "This window could not be captured."

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                } else {
                    Color(nsColor: .quaternaryLabelColor).opacity(0.35)
                }
            }
            .frame(width: 44, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(nsColor: .separatorColor)))
            .opacity(isOn && image != nil ? 1 : 0.4)
            .accessibilityHidden(true)
            Toggle("Attach the whole window, target outlined", isOn: image == nil ? .constant(false) : $isOn)
                .toggleStyle(.checkbox)
                .disabled(image == nil)
                .accessibilityLabel(image == nil ? "Attach the whole window. \(Self.missing)" : "Attach the whole window")
        }
        .help(image == nil ? Self.missing : "A picture of the whole window with the target outlined, so the agent sees where it sits.")
    }
}

/// Whether a listening agent starts on the note when it is saved. One line, always on screen: with
/// nobody listening it is off and says so, and its help says how to start a listener.
struct ComposerSend: View {
    enum Verb {
        case new
        case again
        case reopened
    }

    var listeners: [Listener]
    @Binding var sendTo: String?
    var verb: Verb

    static let nobodyListening =
        "No agent is listening. Ask your agent to run `tincan watch --as <its name>` while you review."

    static func sendLabel(_ listener: Listener) -> String {
        switch listener.state {
        case .waiting: "Send to \(listener.name) now"
        case .working: "Send to \(listener.name), next after the note it is on"
        }
    }

    private func explanation(_ name: String) -> String {
        switch verb {
        case .new: "\(name) starts on this note as soon as you save it. Unchecked, it waits until you ask for your notes."
        case .again: "\(name) gets the note again, as it now reads, as soon as you save it."
        case .reopened: "\(name) gets the note again, with the fix that did not hold and what you wrote now."
        }
    }

    var body: some View {
        switch listeners.count {
        case 0:
            HStack(spacing: 6) {
                Toggle("Send to an agent now", isOn: .constant(false))
                    .disabled(true)
                Text("nobody is listening")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .help(Self.nobodyListening)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Send to an agent now, unavailable. \(Self.nobodyListening)")
        case 1:
            let listener = listeners[0]
            Toggle(Self.sendLabel(listener), isOn: Binding(
                get: { sendTo != nil },
                set: { sendTo = $0 ? listener.name : nil }))
                .help(explanation(listener.name))
        default:
            Picker("Send now to", selection: $sendTo) {
                Text("Nobody, it waits until you ask").tag(String?.none)
                ForEach(listeners, id: \.name) { listener in
                    Text(listener.state == .waiting ? listener.name : "\(listener.name), after the note it is on")
                        .tag(Optional(listener.name))
                }
            }
            .help(explanation("The agent you pick"))
        }
    }
}
