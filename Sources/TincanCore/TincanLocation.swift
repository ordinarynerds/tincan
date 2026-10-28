import Foundation

/// Where notes live, decided the same way by the app that writes them and the agent that reads them.
///
/// In order: the `TINCAN_DIR` environment variable, a directory passed explicitly, `.tincan` at the
/// root of the git repository that contains `start`, and finally the user's Application Support.
public enum TincanLocation {
    public static let environmentKey = "TINCAN_DIR"
    public static let folderName = ".tincan"

    public static func resolve(
        explicit: URL? = nil,
        start: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackName: String = "Default",
        fileManager: FileManager = .default
    ) -> URL {
        if let value = environment[environmentKey], !value.isEmpty {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let explicit { return explicit }
        if let start, let root = repositoryRoot(containing: start, fileManager: fileManager) {
            return root.appendingPathComponent(folderName, isDirectory: true)
        }
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Tincan", isDirectory: true)
            .appendingPathComponent(fallbackName, isDirectory: true)
    }

    /// The nearest ancestor holding `.git` (a folder, or a file in a worktree), or an existing `.tincan`.
    public static func repositoryRoot(containing start: URL, fileManager: FileManager = .default) -> URL? {
        var isDirectory: ObjCBool = false
        var current = start.standardizedFileURL
        if fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            current = current.deletingLastPathComponent()
        }
        while true {
            for marker in [".git", folderName]
            where fileManager.fileExists(atPath: current.appendingPathComponent(marker).path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }
}
