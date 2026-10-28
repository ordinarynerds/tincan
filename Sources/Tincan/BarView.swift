import AppKit
import SwiftUI

/// The floating bar's controls. Off: one button to start. On: what a click does, the notes, and Done.
struct BarView: View {
    let state: ReviewState
    let shortcut: Tincan.Shortcut?

    static let composingReason = "Finish or cancel the note first."

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .help("Drag to move the bar")
                .accessibilityHidden(true)
            if state.isActive { reviewing } else { start }
            if !state.fixesToCheck.isEmpty { fixes }
            notes
        }
        .controlSize(.small)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background { DragArea() }
        .background { BarMaterial() }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
        .fixedSize()
    }

    private var start: some View {
        Button {
            Tincan.start()
        } label: {
            Label("Review", systemImage: "mappin.circle")
        }
        .help("Start review mode\(shortcut.map { " (\($0.displayString))" } ?? "")")
    }

    @ViewBuilder
    private var reviewing: some View {
        Image(systemName: "mappin.circle.fill")
            .foregroundStyle(Color(nsColor: Style.accent))
            .accessibilityLabel("Review mode on")
        Picker("Clicks", selection: Binding(get: { state.isUsingApp }, set: { Tincan.isUsingApp = $0 })) {
            Text("Leave Notes").tag(false)
            Text("Use App").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(state.isComposing)
        .help(state.isComposing
            ? Self.composingReason
            : "Leave Notes: click or drag to leave a note. Use App: clicks reach the app. Holding ⌥ does the same for a moment.")
        .accessibilityLabel(state.isComposing ? "What a click does. \(Self.composingReason)" : "What a click does")
        Button("Done") { Tincan.stop() }
            .disabled(state.isComposing)
            .help(state.isComposing ? Self.composingReason : "Leave review mode (Esc)")
            .accessibilityLabel(state.isComposing ? "Done. \(Self.composingReason)" : "Done, leave review mode")
    }

    private var fixes: some View {
        let count = state.fixesToCheck.count
        return Button {
            Tincan.checkFixes()
        } label: {
            Label("Check \(count)", systemImage: "checkmark.seal.fill")
                .monospacedDigit()
        }
        .tint(.green)
        .disabled(state.isComposing)
        .help(state.isComposing
            ? Self.composingReason
            : "\(count) fix\(count == 1 ? "" : "es") an agent made, waiting for you to look at. Steps through each at its pin.")
        .accessibilityLabel(state.isComposing ? "Check fixes. \(Self.composingReason)" : "Check \(count) fixes")
    }

    private var notes: some View {
        Button {
            Tincan.floatingBar?.showNotes()
        } label: {
            Label("\(state.openCount)", systemImage: "list.bullet")
                .monospacedDigit()
        }
        .help("\(state.openCount) open note\(state.openCount == 1 ? "" : "s"). Choose for the list.")
        .accessibilityLabel("Notes, \(state.openCount) open")
    }
}

/// The bar's background, the same material as a menu, which also follows Reduce Transparency.
struct BarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Dragging anywhere that is not a control moves the bar.
struct DragArea: NSViewRepresentable {
    final class View: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) {}
}
