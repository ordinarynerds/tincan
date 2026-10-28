import AppKit
import TincanCore

/// Review mode for a running macOS app: point at anything, write what is wrong with it, and the note
/// lands on disk where a coding agent can read it with the `tincan` command.
///
/// Install it once at launch, in debug builds only:
///
/// ```swift
/// #if DEBUG
/// import Tincan
/// #endif
///
/// func applicationDidFinishLaunching(_ notification: Notification) {
///     #if DEBUG
///     Tincan.install()
///     #endif
/// }
/// ```
///
/// Then press ⌃⌥⌘T in the app, or choose Review in the floating bar, to start leaving notes.
@MainActor
public enum Tincan {
    public struct Configuration {
        /// Where notes go. Nil means `TINCAN_DIR`, else `.tincan` at the root of the git repository
        /// holding the file that called `install`, else Application Support.
        public var directory: URL?
        /// The key that turns review mode on and off. Nil when the app offers its own menu command.
        public var shortcut: Shortcut?
        /// A switch in the menu bar showing whether review mode is on and how many notes are open.
        public var showsStatusItem: Bool
        /// A bar floating above the app with every control the keys offer, for working with the
        /// pointer alone. The person can hide it from its own menu.
        public var showsFloatingBar: Bool
        /// Facts about the app's state worth attaching to every note, such as the current screen.
        public var context: @MainActor () -> [String: String]

        public init(
            directory: URL? = nil,
            shortcut: Shortcut? = .default,
            showsStatusItem: Bool = true,
            showsFloatingBar: Bool = true,
            context: @escaping @MainActor () -> [String: String] = { [:] }
        ) {
            self.directory = directory
            self.shortcut = shortcut
            self.showsStatusItem = showsStatusItem
            self.showsFloatingBar = showsFloatingBar
            self.context = context
        }
    }

    public struct Shortcut: Sendable, Equatable {
        public var key: String
        public var modifiers: NSEvent.ModifierFlags

        public init(key: String, modifiers: NSEvent.ModifierFlags) {
            self.key = key.lowercased()
            self.modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        }

        public static let `default` = Shortcut(key: "t", modifiers: [.control, .option, .command])

        /// The shortcut as a Mac menu writes it, such as ⌃⌥⌘T.
        public var displayString: String {
            let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + key.uppercased()
        }

        func matches(_ event: NSEvent) -> Bool {
            event.modifierFlags.intersection([.control, .option, .command, .shift]) == modifiers
                && event.charactersIgnoringModifiers?.lowercased() == key
        }
    }

    static var configuration = Configuration()
    static var store: NoteStore?
    static var session: ReviewSession?
    static var shortcutMonitor: Any?
    static var statusItem: StatusItem?
    static var floatingBar: FloatingBar?
    static var countTimer: Timer?
    static let state = ReviewState()

    /// Where this app's notes are written, once `install` has run.
    public static var directory: URL? { store?.directory }

    public static var isActive: Bool { session != nil }

    /// While true, review mode stays on but clicks reach the app, as they do while ⌥ is held.
    public static var isUsingApp: Bool {
        get { state.isUsingApp }
        set {
            guard let session else { return }
            session.usingApp = newValue
            state.isUsingApp = newValue
            stateChanged()
        }
    }

    static var hasStatusItem: Bool { statusItem != nil }

    public static func install(_ configuration: Configuration = Configuration(), file: String = #filePath) {
        self.configuration = configuration
        let directory = TincanLocation.resolve(
            explicit: configuration.directory, start: URL(fileURLWithPath: file),
            fallbackName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
        let store = NoteStore(directory: directory)
        self.store = store
        statusItem?.remove()
        statusItem = configuration.showsStatusItem ? StatusItem(store: store, shortcut: configuration.shortcut) : nil
        floatingBar?.remove()
        floatingBar = configuration.showsFloatingBar ? FloatingBar(store: store, shortcut: configuration.shortcut) : nil
        countTimer?.invalidate()
        countTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { refreshCount() }
        }
        refreshCount()
        if let monitor = shortcutMonitor { NSEvent.removeMonitor(monitor) }
        shortcutMonitor = nil
        if let shortcut = configuration.shortcut {
            shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard shortcut.matches(event) else { return event }
                MainActor.assumeIsolated { toggle() }
                return nil
            }
        }
    }

    public static func start() {
        guard session == nil else { return }
        if store == nil { install() }
        guard let store else { return }
        let session = ReviewSession(store: store, context: configuration.context)
        self.session = session
        state.isActive = true
        session.start()
        stateChanged()
    }

    public static func stop() {
        session?.stop()
        session = nil
        state.isActive = false
        state.isUsingApp = false
        state.isComposing = false
        stateChanged()
    }

    public static func setFloatingBarShown(_ shown: Bool) {
        floatingBar?.setShown(shown)
    }

    static func notesChanged(openCount: Int) {
        guard openCount != state.openCount else { return }
        state.openCount = openCount
        stateChanged()
    }

    static func composingChanged(_ composing: Bool) {
        state.isComposing = composing
        stateChanged()
    }

    /// The open count, read again so a note an agent resolved shows up with review mode off.
    static func refreshCount() {
        guard let store else { return }
        notesChanged(openCount: store.notes(status: .open).count)
    }

    static func stateChanged() {
        statusItem?.refresh()
        floatingBar?.fit()
    }

    public static func toggle() {
        isActive ? stop() : start()
    }
}
