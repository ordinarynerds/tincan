import Foundation

/// One piece of feedback left on a running app: what the person said, and exactly where they said it.
///
/// A note is written by the app and read by an agent. Every field is plain data so that a note
/// survives being opened by a different tool, a different version of Tincan, or a person with `cat`.
public struct Note: Codable, Equatable, Sendable, Identifiable {
    public static let schemaVersion = 1

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

    public init(
        id: String, created: Date, text: String, app: AppInfo, context: [String: String] = [:],
        window: WindowInfo, target: Target, images: Images = Images(), status: Status = .open,
        resolution: Resolution? = nil
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
        }
    }

    public struct Images: Codable, Equatable, Sendable {
        /// The element or region on its own, with a margin around it.
        public var element: String?
        /// The whole window with the target outlined.
        public var window: String?

        public init(element: String? = nil, window: String? = nil) {
            self.element = element
            self.window = window
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

extension Note.Element {
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
