import CoreGraphics

extension OverlayView {
    /// A note drawn on its window: where it is, what state it is in, and what the bottom line says
    /// while the pointer rests on it.
    struct Pin: Equatable {
        enum Kind: Equatable {
            /// Open, numbered as in `tincan list`.
            case open(number: Int)
            /// Resolved by an agent and not yet looked at. Carries the agent's summary.
            case toCheck(summary: String)
            /// Resolved and done with. Carries the summary, empty when none was given.
            case resolved(summary: String)
        }

        enum Agent: Equatable {
            /// Sent to this agent, which has not picked it up yet.
            case waiting(String)
            /// Handed over, and the agent is working.
            case working(String)
        }

        var kind: Kind
        var noteID: String
        var text: String
        var center: CGPoint
        /// Where the note's element is now, which the sheet points at and the hover outlines.
        var target: CGRect
        /// What the note points at, in a person's words, for saying it can't be found.
        var targetSummary = ""
        var placement: PinLocator.Placement = .here
        var agent: Agent?

        var number: Int? {
            if case .open(let number) = kind { return number }
            return nil
        }

        var isResolved: Bool { number == nil }

        var banner: String {
            var parts: [String]
            switch kind {
            case .open(let number):
                parts = ["Note \(number): \(text)"]
                switch agent {
                case .waiting(let name): parts.append("Waiting for \(name).")
                case .working(let name): parts.append("\(name) is on it.")
                case nil: break
                }
            case .toCheck(let summary):
                parts = ["Fixed: \(text)", summary.isEmpty ? "" : "\(summary).", "Click to check it."]
            case .resolved(let summary):
                parts = ["Resolved: \(text)", summary.isEmpty ? "" : "\(summary).", "Click to reopen."]
            }
            if placement == .missing {
                parts.append("Can’t find \(targetSummary.isEmpty ? "what it points at" : targetSummary) here any more.")
            }
            if case .open = kind { parts.append("Click to open, right-click for more.") }
            return parts.filter { !$0.isEmpty }.joined(separator: "    ")
        }

        /// Where a pin sits for a target: its top-right corner, kept inside the window.
        static func center(for target: CGRect, in size: CGSize) -> CGPoint {
            CGPoint(
                x: min(max(target.maxX, 12), size.width - 12),
                y: min(max(target.minY, 12), size.height - 12))
        }
    }
}
