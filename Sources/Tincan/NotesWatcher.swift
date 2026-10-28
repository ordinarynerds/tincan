import Foundation
import TincanCore

/// Tells Tincan the moment a note or a listener changes on disk, so a note an agent resolves leaves
/// the app at once instead of on the next poll. Every write in the store replaces a file by renaming
/// into its folder, which is an event on the folder itself.
@MainActor
final class NotesWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending = false
    private let changed: @MainActor () -> Void

    init(store: NoteStore, changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        try? store.prepare()
        try? FileManager.default.createDirectory(at: store.listenersDirectory, withIntermediateDirectories: true)
        for url in [store.notesDirectory, store.listenersDirectory] {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.schedule() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources = []
    }

    /// One refresh for a burst of writes, such as a note and its three pictures.
    private func schedule() {
        guard !pending else { return }
        pending = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self else { return }
            pending = false
            changed()
        }
    }
}
