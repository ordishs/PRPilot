import Foundation

/// One thing somebody else did on your PR: a review, or a comment.
public struct ReviewerEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case changesRequested
        case approved
        case other
    }

    public var login: String
    public var at: Date
    public var kind: Kind

    public init(login: String, at: Date, kind: Kind) {
        self.login = login
        self.at = at
        self.kind = kind
    }
}

/// What a reviewer did on your own PR since you last acted on it.
public struct ReviewerUpdate: Sendable, Equatable, Codable {
    /// Newest reviewer activity after your last action.
    public var at: Date
    /// The newest verdict among that activity is a request for changes.
    public var requestedChanges: Bool

    public init(at: Date, requestedChanges: Bool) {
        self.at = at
        self.requestedChanges = requestedChanges
    }

    /// Mirror of `AuthorUpdate.latestUpdate` for PRs you wrote.
    ///
    /// Your own last action anchors it: your newest push, comment or review. A reviewer who
    /// has spoken after that is waiting on you, and the result returns to nil the moment you
    /// push or reply. That is what makes the badge clear itself.
    ///
    /// The caller removes bots before passing events. Activity by you never counts.
    public static func latest(
        myLogin: String,
        events: [ReviewerEvent],
        myActivity: [Date],
        headCommittedAt: Date?
    ) -> ReviewerUpdate? {
        let anchor = (myActivity + [headCommittedAt].compactMap { $0 }).max() ?? .distantPast
        let fresh = events
            .filter { $0.login.caseInsensitiveCompare(myLogin) != .orderedSame && $0.at > anchor }
            .sorted { $0.at < $1.at }
        guard let newest = fresh.last else { return nil }
        let newestVerdict = fresh.last { $0.kind != .other }
        return ReviewerUpdate(at: newest.at, requestedChanges: newestVerdict?.kind == .changesRequested)
    }

    /// Same watermark rule as the author badge: an update equal to the mark reads as seen.
    public func isUnseen(seenAt: Date?) -> Bool {
        AuthorUpdate.isUnseen(updatedAt: at, seenAt: seenAt)
    }
}
