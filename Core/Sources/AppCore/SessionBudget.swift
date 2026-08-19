import Foundation
import AgentKit

/// Chooses which live Claude sessions to shut down once the cap is exceeded.
///
/// The cap is a strong target, not a hard ceiling: a session that is mid-turn is never
/// killed, because SIGTERM would throw away work the user is waiting for. When every
/// candidate is protected the budget returns nothing and the session count stays high.
public enum SessionBudget {
    /// How long a session that has not reported yet is left alone. `AgentStatusReader`
    /// reports `.starting` both for a launching process and for a running one that has
    /// written no transcript, and it never times the second case out. Without this bound a
    /// silent session would be protected forever, which is the leak the cap exists to stop.
    public static let startupGraceSeconds: TimeInterval = 60

    public struct Candidate: Sendable, Equatable {
        public let id: String
        public let lastOpenedAt: Date
        public let status: AgentStatus
        public let startedAt: Date

        public init(id: String, lastOpenedAt: Date, status: AgentStatus, startedAt: Date) {
            self.id = id
            self.lastOpenedAt = lastOpenedAt
            self.status = status
            self.startedAt = startedAt
        }
    }

    /// Returns the ids to evict, oldest first.
    public static func evictions(
        candidates: [Candidate],
        cap: Int,
        selectedID: String?,
        now: Date
    ) -> [String] {
        guard cap > 0, candidates.count > cap else { return [] }

        let newestFirst = candidates.sorted { left, right in
            if left.lastOpenedAt == right.lastOpenedAt { return left.id < right.id }
            return left.lastOpenedAt > right.lastOpenedAt
        }
        let overflow = candidates.count - cap

        var victims: [String] = []
        for candidate in newestFirst.reversed() {
            if victims.count == overflow { break }
            if candidate.id == selectedID { continue }
            if isProtected(candidate, now: now) { continue }
            victims.append(candidate.id)
        }
        return victims
    }

    /// The single protection rule, shared with `SessionQueue` so the two cannot drift apart.
    ///
    /// `.idle` needs care. It does not mean the agent finished: a completed turn reads
    /// `.awaitingInput`, so `.idle` means the last transcript line left the turn open and
    /// nothing followed it for 30 seconds. That is what a long tool call looks like from
    /// outside — a build, a test run, a large read. Killing it throws away the work the cap
    /// promises never to lose.
    ///
    /// The `since` date decides which kind of `.idle` this is. A line written after this
    /// process started belongs to this process, so the turn is in flight. A line older than
    /// the process is replay: `TranscriptWatcher` re-reads the transcript from the start on
    /// attach, so a session resumed after an interrupted turn reports the old line and never
    /// adds another. That one is genuinely idle, and the cap must still reclaim its slot.
    public static func isProtected(_ candidate: Candidate, now: Date) -> Bool {
        switch candidate.status {
        case .working:
            return true
        case .starting:
            return now.timeIntervalSince(candidate.startedAt) <= startupGraceSeconds
        case .idle(let since, _):
            return since >= candidate.startedAt
        case .awaitingInput, .ready, .failed:
            return false
        }
    }
}
