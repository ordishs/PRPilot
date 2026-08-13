import Foundation
import AgentKit

/// Decides one step of draining the review backlog: which finished session gives up its
/// slot, and which queued item takes it.
///
/// A finished review releases its process before the user has read it. Nothing is lost —
/// the transcript survives and `ensureAgentSession` resumes it — and holding the slot
/// would stall the backlog behind whatever the user has not got round to reading.
public enum SessionQueue {
    public struct Step: Sendable, Equatable {
        public let release: String?
        public let start: String?

        public init(release: String?, start: String?) {
            self.release = release
            self.start = start
        }
    }

    public static func nextStep(
        queued: [String],
        live: [SessionBudget.Candidate],
        cap: Int,
        selectedID: String?,
        now: Date
    ) -> Step {
        guard cap > 0, let next = queued.first else { return Step(release: nil, start: nil) }
        guard live.count >= cap else { return Step(release: nil, start: next) }

        let releasable = live
            .filter { $0.id != selectedID }
            .filter { !isProtected($0, now: now) }
            .min { left, right in
                if left.lastOpenedAt == right.lastOpenedAt { return left.id < right.id }
                return left.lastOpenedAt < right.lastOpenedAt
            }

        guard let releasable else { return Step(release: nil, start: nil) }
        return Step(release: releasable.id, start: next)
    }

    /// Same rule as `SessionBudget`: a session mid-turn keeps its slot, and a launching one
    /// gets a grace period before it counts as idle.
    private static func isProtected(_ candidate: SessionBudget.Candidate, now: Date) -> Bool {
        switch candidate.status {
        case .working:
            return true
        case .starting:
            return now.timeIntervalSince(candidate.startedAt) <= SessionBudget.startupGraceSeconds
        case .awaitingInput, .idle, .ready, .failed:
            return false
        }
    }
}
