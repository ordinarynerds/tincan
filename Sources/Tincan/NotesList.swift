import AppKit
import SwiftUI
import TincanCore

/// Every note in one place, opened from the floating bar or the menu bar switch: what is open, which
/// fixes wait to be checked, and what was resolved. Choosing a note takes the person to its pin.
struct NotesList: View {
    enum Filter: Hashable {
        case open
        case toCheck
        case resolved
    }

    let state: ReviewState
    let store: NoteStore
    var close: () -> Void
    @State private var filter: Filter
    /// The rows' own height, so the list is as tall as its notes until it scrolls.
    @State private var rowsHeight: CGFloat = 0

    static let maxListHeight: CGFloat = 420

    init(state: ReviewState, store: NoteStore, close: @escaping () -> Void) {
        self.state = state
        self.store = store
        self.close = close
        _filter = State(initialValue: state.fixesToCheck.isEmpty ? .open : .toCheck)
    }

    private var notes: [Note] {
        switch filter {
        case .open: state.open
        case .toCheck: state.fixesToCheck
        case .resolved: state.resolved.filter { !$0.awaitsCheck }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Notes", selection: $filter) {
                    Text("Open \(state.openCount)").tag(Filter.open)
                    Text("To Check \(state.fixesToCheck.count)").tag(Filter.toCheck)
                    Text("Resolved").tag(Filter.resolved)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                more
            }
            .padding(10)
            Divider()
            if filter == .toCheck, !notes.isEmpty {
                Button {
                    close()
                    Tincan.checkFixes()
                } label: {
                    Label("Check Each Fix in Place", systemImage: "checkmark.seal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .padding(10)
                .help("Step through each fix at its pin, with before and after pictures, and confirm or reopen it")
            }
            if notes.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .padding(.horizontal, 24)
            } else {
                ScrollView {
                    rows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                }
                .frame(height: min(max(rowsHeight, 52), Self.maxListHeight))
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: state.listeners.isEmpty ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(NotesMenu.listening(state.listeners))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(state.listeners.isEmpty ? ComposerSend.nobodyListening : "Notes can be sent to it from the note sheet.")
                Spacer()
                Button(state.isActive ? "Stop Review" : "Start Review") {
                    close()
                    Tincan.toggle()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: 400)
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(notes) { note in
                NoteRow(note: note, number: number(of: note), store: store, listener: state.listener(for: note)) {
                    close()
                    Tincan.open(noteID: note.id)
                }
            }
        }
        .padding(6)
    }

    private func number(of note: Note) -> Int? {
        guard note.status == .open else { return nil }
        return state.open.firstIndex { $0.id == note.id }.map { $0 + 1 }
    }

    private var emptyText: String {
        switch filter {
        case .open: "No open notes. Start review mode and click anything to leave one."
        case .toCheck: "No fix is waiting. When an agent resolves a note, it waits here for you to look at it."
        case .resolved: "No resolved notes yet."
        }
    }

    private var more: some View {
        Menu {
            Toggle("Show Resolved Pins", isOn: Binding(get: { Tincan.showsResolved }, set: { Tincan.showsResolved = $0 }))
            Divider()
            Button("Copy “tincan list” for Your Agent") { NotesMenu.copy("tincan list") }
            Button("Show Notes in Finder") {
                try? store.prepare()
                NSWorkspace.shared.activateFileViewerSelecting([store.notesDirectory])
            }
            if let bar = Tincan.floatingBar {
                Divider()
                Button(bar.isShown ? "Hide Floating Bar" : "Show Floating Bar") { Tincan.setFloatingBarShown(!bar.isShown) }
                    .disabled(bar.isShown && !Tincan.hasStatusItem)
                    .help(bar.isShown && !Tincan.hasStatusItem
                        ? "The menu bar switch is off, so the floating bar is the way back to review mode." : "")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }
}

/// One note in the list: its picture, its words, and one line on where it is and who has it.
struct NoteRow: View {
    let note: Note
    let number: Int?
    let store: NoteStore
    let listener: Listener?
    var open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                ThumbnailImage(url: store.imageURL(note.images.after ?? note.images.element))
                    .frame(width: 56, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let number {
                            Text("\(number)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(Color(nsColor: Style.accent))
                        }
                        Text(note.text)
                            .font(.callout)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text(Self.meta(note, listener: listener, now: Date()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color(nsColor: .quaternaryLabelColor).opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            ForEach(Array(NoteAction.all(for: note, store: store).enumerated()), id: \.offset) { _, action in
                if action.startsGroup { Divider() }
                Button(action.title, role: action.isDestructive ? .destructive : nil, action: action.perform)
                    .disabled(action.unavailable != nil)
                    .help(action.unavailable ?? action.help ?? "")
            }
        }
        .help(Tincan.whyNotOpenable(note) ?? "Open the note at its pin")
        .accessibilityHint("Opens the note at its pin")
    }

    /// Where the note is and what is happening to it, in one line.
    static func meta(_ note: Note, listener: Listener?, now: Date) -> String {
        var parts = [note.target.summary]
        let place = Tincan.placeName(note)
        if !place.isEmpty { parts.append(place) }
        switch note.status {
        case .open:
            parts.append(ComposerHeader.age(note.created, now: now))
            if let handoff = note.handoff {
                if handoff.delivered == nil {
                    parts.append("waiting for \(handoff.agent)")
                } else if listener?.state == .working {
                    parts.append("\(handoff.agent) is on it")
                } else {
                    parts.append("handed to \(handoff.agent)")
                }
            }
            if let reopening = note.lastReopening, reopening.reopened.at > note.created {
                parts.append("reopened")
            }
        case .resolved:
            let when = ComposerHeader.age(note.resolution?.at ?? note.created, now: now)
            parts.append("fixed \(when)\(note.resolution?.summary.map { ": \($0)" } ?? "")")
        }
        return parts.joined(separator: ", ")
    }
}

/// A note's picture, read once and kept, since the list redraws while the pointer moves.
struct ThumbnailImage: View {
    let url: URL?

    @MainActor static let cache = NSCache<NSURL, NSImage>()

    var body: some View {
        ZStack {
            Color(nsColor: .quaternaryLabelColor).opacity(0.35)
            if let image {
                Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fit).padding(2)
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityHidden(true)
    }

    /// Keyed by the file's date as well as its path, since the after picture is taken again in place.
    private var image: NSImage? {
        guard let url else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = URL(fileURLWithPath: url.path + "#\(modified?.timeIntervalSince1970 ?? 0)") as NSURL
        if let cached = Self.cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        Self.cache.setObject(image, forKey: key)
        return image
    }
}
