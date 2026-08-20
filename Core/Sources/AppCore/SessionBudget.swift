import Foundation
import AgentKit
import PRPilotModels

/// Chooses which live agent sessions to shut down once the cap is exceeded.
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

    /// How long an `.idle` session may stay quiet and still count as mid-turn.
    ///
    /// Mid-turn protection must expire. A session that ever wrote one transcript line would
    /// otherwise be protected for the life of the app, the cap would never reclaim a slot,
    /// and the only session the drain could take would be the one that had just answered the
    /// user. That is exactly backwards.
    public static let defaultIdleProtectionMinutes = SessionDefaults.idleProtectionMinutes

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
        now: Date,
        idleProtectionSeconds: TimeInterval = Double(defaultIdleProtectionMinutes) * 60
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
            if isProtected(candidate, now: now, idleProtectionSeconds: idleProtectionSeconds) { continue }
            victims.append(candidate.id)
        }
        return victims
    }

    /// Sessions whose process has already gone. Reaping one takes nothing from the user, so
    /// unlike an eviction this is not gated on the cap or on which item is selected: a dead
    /// session sitting at exactly the cap would otherwise block the backlog for as long as
    /// the app runs.
    public static func deadSessions(candidates: [Candidate]) -> [String] {
        candidates.filter { candidate in
            switch candidate.status {
            case .ready, .failed: return true
            case .working, .starting, .idle, .awaitingInput: return false
            }
        }.map(\.id)
    }

    /// The protection rule.
    ///
    /// `.idle` needs care. It does not mean the agent finished: a completed turn reads
    /// `.awaitingInput`, so `.idle` means the last transcript line left the turn open and
    /// nothing followed it for 30 seconds. That is what a long tool call looks like from
    /// outside — a build, a test run, a large read. Killing it throws away the work the cap
    /// promises never to lose.
    ///
    /// Two conditions bound that protection, and both must hold.
    ///
    /// The `since` date decides whether the line belongs to this process. A line written
    /// after this process started is its own; a line older than the process is replay, since
    /// `TranscriptWatcher` re-reads the transcript from the start on attach, so a session
    /// resumed after an interrupted turn reports the old line and never adds another.
    ///
    /// The quiet time then decides whether the turn is plausibly still running. A tool call
    /// that has said nothing for hours is not a tool call any more; the session is parked.
    /// Without this the rule protects every session that ever spoke, forever.
    public static func isProtected(
        _ candidate: Candidate,
        now: Date,
        idleProtectionSeconds: TimeInterval = Double(defaultIdleProtectionMinutes) * 60
    ) -> Bool {
        switch candidate.status {
        case .working:
            return true
        case .starting:
            return now.timeIntervalSince(candidate.startedAt) <= startupGraceSeconds
        case .idle(let since, _):
            guard since >= candidate.startedAt else { return false }
            return now.timeIntervalSince(since) <= idleProtectionSeconds
        case .awaitingInput, .ready, .failed:
            return false
        }
    }
}
