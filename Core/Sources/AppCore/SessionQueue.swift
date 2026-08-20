import Foundation
import AgentKit

/// Decides one step of draining the review backlog: which queued item takes a free slot.
///
/// autoLoad fills spare capacity. It never makes capacity: a queued review that has not
/// started is worth less than a turn already running, and a live agent that the drain kills
/// to make room loses whatever it was doing. So this returns a start only when the cap
/// already has room. Reclaiming a stale slot is `SessionBudget`'s job, on its own rule.
public enum SessionQueue {
    public struct Step: Sendable, Equatable {
        public let start: String?

        public init(start: String?) {
            self.start = start
        }
    }

    public static func nextStep(
        queued: [String],
        live: [SessionBudget.Candidate],
        cap: Int,
        now: Date
    ) -> Step {
        guard cap > 0, let next = queued.first else { return Step(start: nil) }
        guard live.count < cap else { return Step(start: nil) }
        return Step(start: next)
    }
}
