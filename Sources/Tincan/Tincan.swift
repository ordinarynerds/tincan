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
/// Then press ⌃⌥⌘T in the app to start leaving notes.
@MainActor
public enum Tincan {
    public struct Configuration {
        /// Where notes go. Nil means `TINCAN_DIR`, else `.tincan` at the root of the git repository
        /// holding the file that called `install`, else Application Support.
        public var directory: URL?
        /// The key that turns review mode on and off. Nil when the app offers its own menu command.
        public var shortcut: Shortcut?
        /// Facts about the app's state worth attaching to every note, such as the current screen.
        public var context: @MainActor () -> [String: String]

        public init(
            directory: URL? = nil,
            shortcut: Shortcut? = .default,
            context: @escaping @MainActor () -> [String: String] = { [:] }
        ) {
            self.directory = directory
            self.shortcut = shortcut
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

        func matches(_ event: NSEvent) -> Bool {
            event.modifierFlags.intersection([.control, .option, .command, .shift]) == modifiers
                && event.charactersIgnoringModifiers?.lowercased() == key
        }
    }

    static var configuration = Configuration()
    static var store: NoteStore?
    static var session: ReviewSession?
    static var shortcutMonitor: Any?

    /// Where this app's notes are written, once `install` has run.
    public static var directory: URL? { store?.directory }

    public static var isActive: Bool { session != nil }

    public static func install(_ configuration: Configuration = Configuration(), file: String = #filePath) {
        self.configuration = configuration
        let directory = TincanLocation.resolve(
            explicit: configuration.directory, start: URL(fileURLWithPath: file),
            fallbackName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
        store = NoteStore(directory: directory)
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
        session.start()
    }

    public static func stop() {
        session?.stop()
        session = nil
    }

    public static func toggle() {
        isActive ? stop() : start()
    }
}
