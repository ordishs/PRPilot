import Foundation

public struct ThreadComment: Sendable, Equatable, Codable {
    public var authorLogin: String
    public var createdAt: Date

    public init(authorLogin: String, createdAt: Date) {
        self.authorLogin = authorLogin
        self.createdAt = createdAt
    }
}

public struct ReviewThreadSnapshot: Sendable, Equatable, Codable {
    public var isResolved: Bool
    /// GitHub exposes who resolved a thread but never when — see `latestUpdate`.
    public var resolvedByLogin: String?
    public var comments: [ThreadComment]

    public init(isResolved: Bool, resolvedByLogin: String?, comments: [ThreadComment]) {
        self.isResolved = isResolved
        self.resolvedByLogin = resolvedByLogin
        self.comments = comments
    }
}

public enum AuthorUpdate {
    /// Newest thing the PR author did after your most recent review, or nil if they have
    /// done nothing since — the "Updated" chip shows exactly when this is non-nil.
    ///
    /// Your own review is the anchor: without one there is nothing to measure "since"
    /// against, and once you review again your review is the newest word and this returns
    /// to nil. That is what makes the chip clear itself.
    ///
    /// Thread resolution has no timestamp anywhere in the API (`isResolved` and
    /// `resolvedBy`, but no `resolvedAt`, and resolving raises no timeline event), so a
    /// thread the author resolved is dated by its newest comment. A thread resolved
    /// silently long after the discussion ended therefore reads as older than it is; in
    /// practice the resolve comes with a reply, which the reply rule already catches.
    public static func latestUpdate(
        myLogin: String,
        authorLogin: String,
        myReviewDates: [Date],
        threads: [ReviewThreadSnapshot],
        headCommittedAt: Date?,
        reviewRequestedFromMeAt: [Date]
    ) -> Date? {
        // Your own PR: you are the author, so there is no "author responded to you".
        guard authorLogin != myLogin else { return nil }
        guard let myLastReview = myReviewDates.max() else { return nil }

        var candidates: [Date] = []

        let myThreads = threads.filter { thread in
            thread.comments.contains { $0.authorLogin == myLogin }
        }
        for thread in myThreads {
            candidates.append(contentsOf: thread.comments
                .filter { $0.authorLogin == authorLogin }
                .map(\.createdAt))
            if thread.isResolved, thread.resolvedByLogin == authorLogin,
               let newestComment = thread.comments.map(\.createdAt).max() {
                candidates.append(newestComment)
            }
        }
        if let headCommittedAt {
            candidates.append(headCommittedAt)
        }
        candidates.append(contentsOf: reviewRequestedFromMeAt)

        return candidates.filter { $0 > myLastReview }.max()
    }

    /// Whether the "Updated" chip should show, given the update the poll found and the
    /// watermark left by dismissing the badge by hand.
    ///
    /// Dismissing records the update's own timestamp rather than the wall clock, so an
    /// update equal to the watermark reads as seen and anything later re-badges.
    public static func isUnseen(updatedAt: Date?, seenAt: Date?) -> Bool {
        guard let updatedAt else { return false }
        guard let seenAt else { return true }
        return updatedAt > seenAt
    }
}
