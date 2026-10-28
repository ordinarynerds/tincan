import Foundation

/// One piece of feedback left on a running app: what the person said, and exactly where they said it.
///
/// A note is written by the app and read by an agent. Every field is plain data so that a note
/// survives being opened by a different tool, a different version of Tincan, or a person with `cat`.
public struct Note: Codable, Equatable, Sendable, Identifiable {
    public static let schemaVersion = 2

    public var schema: Int
    public var id: String
    public var created: Date
    public var status: Status
    public var text: String
    public var app: AppInfo
    public var context: [String: String]
    public var window: WindowInfo
    public var target: Target
    public var images: Images
    public var resolution: Resolution?
    /// Set when the person sent the note to a listening agent to work on straight away.
    public var handoff: Handoff?
    /// Every edit, resolution and reopening, oldest first, so a reopened note still says what was
    /// tried and why it did not hold.
    public var history: [Event]

    public init(
        id: String, created: Date, text: String, app: AppInfo, context: [String: String] = [:],
        window: WindowInfo, target: Target, images: Images = Images(), status: Status = .open,
        resolution: Resolution? = nil, handoff: Handoff? = nil, history: [Event] = []
    ) {
        self.schema = Self.schemaVersion
        self.id = id
        self.created = created
        self.status = status
        self.text = text
        self.app = app
        self.context = context
        self.window = window
        self.target = target
        self.images = images
        self.resolution = resolution
        self.handoff = handoff
        self.history = history
    }

    public enum Status: String, Codable, Sendable, CaseIterable {
        case open
        case resolved
    }

    public struct AppInfo: Codable, Equatable, Sendable {
        public var bundleID: String?
        public var name: String
        public var version: String?
        public var build: String?

        public init(bundleID: String?, name: String, version: String?, build: String?) {
            self.bundleID = bundleID
            self.name = name
            self.version = version
            self.build = build
        }
    }

    public struct WindowInfo: Codable, Equatable, Sendable {
        public var title: String
        public var identifier: String?
        /// The window's size in points. Every rect in the note is measured from its top-left corner.
        public var size: Size
        /// Pixels per point in the saved images.
        public var scale: Double

        public init(title: String, identifier: String?, size: Size, scale: Double) {
            self.title = title
            self.identifier = identifier
            self.size = size
            self.scale = scale
        }
    }

    public struct Target: Codable, Equatable, Sendable {
        public var kind: Kind
        /// Where the person clicked, or the region they dragged, in window points from the top left.
        public var rect: Rect
        /// The accessibility element under the click. Absent for a dragged region.
        public var element: Element?
        /// The class of the deepest view under the click, such as `NSHostingView<SettingsView>`.
        public var view: String?

        public init(kind: Kind, rect: Rect, element: Element? = nil, view: String? = nil) {
            self.kind = kind
            self.rect = rect
            self.element = element
            self.view = view
        }

        public enum Kind: String, Codable, Sendable {
            case element
            case region
        }
    }

    public struct Element: Codable, Equatable, Sendable {
        public var role: String?
        public var subrole: String?
        public var roleDescription: String?
        public var label: String?
        public var title: String?
        public var value: String?
        public var help: String?
        public var identifier: String?
        /// Meaningful ancestors, nearest first.
        public var ancestors: [Ancestor]

        public init(
            role: String? = nil, subrole: String? = nil, roleDescription: String? = nil,
            label: String? = nil, title: String? = nil, value: String? = nil, help: String? = nil,
            identifier: String? = nil, ancestors: [Ancestor] = []
        ) {
            self.role = role
            self.subrole = subrole
            self.roleDescription = roleDescription
            self.label = label
            self.title = title
            self.value = value
            self.help = help
            self.identifier = identifier
            self.ancestors = ancestors
        }

        public struct Ancestor: Codable, Equatable, Sendable {
            public var role: String?
            public var label: String?
            public var identifier: String?

            public init(role: String?, label: String?, identifier: String?) {
                self.role = role
                self.label = label
                self.identifier = identifier
            }

            /// Whether an element read now is this one. An identifier decides on its own; without
            /// one, the role and the name have to agree.
            public func matches(role: String?, name: String?, identifier: String?) -> Bool {
                if let mine = self.identifier {
                    guard mine == identifier else { return false }
                    return self.role == nil || role == nil || self.role == role
                }
                guard let label, let mine = self.role else { return false }
                return mine == role && label == name
            }
        }
    }

    public struct Images: Codable, Equatable, Sendable {
        /// The element or region on its own, with a margin around it.
        public var element: String?
        /// The whole window with the target outlined.
        public var window: String?
        /// The same spot as it looked when the person last opened the fix to check it.
        public var after: String?
        /// When the after picture was taken.
        public var afterAt: Date?

        public init(element: String? = nil, window: String? = nil, after: String? = nil, afterAt: Date? = nil) {
            self.element = element
            self.window = window
            self.after = after
            self.afterAt = afterAt
        }
    }

    public struct Resolution: Codable, Equatable, Sendable {
        public var at: Date
        public var summary: String?

        public init(at: Date, summary: String?) {
            self.at = at
            self.summary = summary
        }
    }

    public struct Handoff: Codable, Equatable, Sendable {
        /// The name the agent listens under, such as Claude.
        public var agent: String
        public var sent: Date
        /// When `tincan watch` handed it to the agent. Nil while it waits for the agent to listen again.
        public var delivered: Date?

        public init(agent: String, sent: Date, delivered: Date? = nil) {
            self.agent = agent
            self.sent = sent
            self.delivered = delivered
        }
    }

    public struct Event: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// The person rewrote the note. `text` is the wording it replaced.
            case edited
            /// Marked as handled. `text` is the summary of what changed.
            case resolved
            /// Marked open again. `text` is what is still wrong, when the person said.
            case reopened
            /// The person looked at the fix in the app and it is right.
            case confirmed
        }

        public var kind: Kind
        public var at: Date
        public var text: String?

        public init(kind: Kind, at: Date, text: String? = nil) {
            self.kind = kind
            self.at = at
            self.text = text
        }
    }

    public struct Rect: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct Size: Codable, Equatable, Sendable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }
}

extension Note {
    /// Reads every schema so far. Schema 1 had no history.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        id = try container.decode(String.self, forKey: .id)
        created = try container.decode(Date.self, forKey: .created)
        status = try container.decode(Status.self, forKey: .status)
        text = try container.decode(String.self, forKey: .text)
        app = try container.decode(AppInfo.self, forKey: .app)
        context = try container.decode([String: String].self, forKey: .context)
        window = try container.decode(WindowInfo.self, forKey: .window)
        target = try container.decode(Target.self, forKey: .target)
        images = try container.decode(Images.self, forKey: .images)
        resolution = try container.decodeIfPresent(Resolution.self, forKey: .resolution)
        handoff = try container.decodeIfPresent(Handoff.self, forKey: .handoff)
        history = try container.decodeIfPresent([Event].self, forKey: .history) ?? []
    }

    /// Resolved by an agent and not yet looked at by the person who left it.
    public var awaitsCheck: Bool {
        status == .resolved && history.last?.kind == .resolved
    }

    /// Whether the note was left where the app is now. `keys` names the context entries that make up
    /// a place, such as a screen, and nil means all of them. A note with no context is everywhere.
    public func isLeft(in context: [String: String], keys: Set<String>? = nil) -> Bool {
        guard !self.context.isEmpty else { return true }
        guard let keys else { return self.context == context }
        return self.context.filter { keys.contains($0.key) } == context.filter { keys.contains($0.key) }
    }

    /// The latest reopening, and the resolution it undid, for a note that came back.
    public var lastReopening: (reopened: Event, undid: Event?)? {
        guard let index = history.lastIndex(where: { $0.kind == .reopened }) else { return nil }
        let undid = history[..<index].last { $0.kind == .resolved }
        return (history[index], undid)
    }
}

extension Note.Element {
    /// What to look for to find this element again after the window changed: the element itself,
    /// or for a line of text read off the screen, which has no element of its own, the one holding it.
    public var anchor: Ancestor? {
        if role == nil, let holder = ancestors.first { return holder }
        let name = [label, title, value].compactMap { $0 }.first { !$0.isEmpty }
        guard identifier != nil || (role != nil && name != nil) else { return nil }
        return Ancestor(role: role, label: name, identifier: identifier)
    }

    /// The words a person would use for this element: `Button “Save”`.
    public var summary: String {
        let kind = roleDescription ?? role.map(Self.plainRole) ?? "Element"
        let name = [label, title, value].compactMap { $0 }.first { !$0.isEmpty }
        guard let name else { return kind.capitalizedFirst }
        return "\(kind.capitalizedFirst) “\(name)”"
    }

    public static func plainRole(_ role: String) -> String {
        let trimmed = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        var words: [String] = []
        var current = ""
        for character in trimmed {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ").lowercased()
    }
}

extension Note.Target {
    public var summary: String {
        switch kind {
        case .element:
            return element?.summary ?? "Element"
        case .region:
            return "Region \(Int(rect.width.rounded()))×\(Int(rect.height.rounded())) at \(Int(rect.x.rounded())),\(Int(rect.y.rounded()))"
        }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
