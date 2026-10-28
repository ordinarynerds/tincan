import Observation

/// What the controls show: whether review mode is on, whether clicks are going to the app, whether a
/// note is being written, and how many notes are open. Tincan owns it; the floating bar and the menu
/// bar switch only read it.
@MainActor
@Observable
final class ReviewState {
    var isActive = false
    var isUsingApp = false
    var isComposing = false
    var openCount = 0
}
