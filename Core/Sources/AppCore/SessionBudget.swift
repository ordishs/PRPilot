import Foundation
import ClaudeSessionKit

/// Chooses which live Claude sessions to shut down once the cap is exceeded.
///
/// The cap is a strong target, not a hard ceiling: a session that is mid-turn is never
/// killed, because SIGTERM would throw away work the user is waiting for. When every
/// candidate is protected the budget returns nothing and the session count stays high.
public enum SessionBudget {
    public struct Candidate: Sendable, Equatable {
        public let id: String
        public let lastOpenedAt: Date
        public let status: ClaudeStatus

        public init(id: String, lastOpenedAt: Date, status: ClaudeStatus) {
            self.id = id
            self.lastOpenedAt = lastOpenedAt
            self.status = status
        }
    }

    /// Returns the ids to evict, oldest first.
    public static func evictions(
        candidates: [Candidate],
        cap: Int,
        selectedID: String?
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
            if isProtected(candidate.status) { continue }
            victims.append(candidate.id)
        }
        return victims
    }

    private static func isProtected(_ status: ClaudeStatus) -> Bool {
        switch status {
        case .starting, .working:
            return true
        case .awaitingInput, .idle, .ready, .failed:
            return false
        }
    }
}
