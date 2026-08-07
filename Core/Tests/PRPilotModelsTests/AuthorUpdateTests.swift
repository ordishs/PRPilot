import Testing
import Foundation
@testable import PRPilotModels

private let me = "ordishs"
private let author = "icellan"

private func at(_ offsetHours: Double) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(offsetHours * 3600)
}

private let myReview = at(10)

private func thread(
    resolved: Bool = false,
    resolvedBy: String? = nil,
    _ comments: [(String, Double)]
) -> ReviewThreadSnapshot {
    ReviewThreadSnapshot(
        isResolved: resolved,
        resolvedByLogin: resolvedBy,
        comments: comments.map { ThreadComment(authorLogin: $0.0, createdAt: at($0.1)) }
    )
}

@Test func firesWhenAuthorRepliesInAThreadYouStarted() {
    let update = AuthorUpdate.latestUpdate(
        myLogin: me,
        authorLogin: author,
        myReviewDates: [myReview],
        threads: [thread([(me, 10), (author, 14)])],
        headCommittedAt: nil,
        reviewRequestedFromMeAt: []
    )
    #expect(update == at(14))
}

@Test func ignoresAuthorRepliesInThreadsYouNeverTouched() {
    // teranode#1385: the author replied to Copilot's and github-actions' threads. You were
    // never in those threads, so that is not a response to you.
    let update = AuthorUpdate.latestUpdate(
        myLogin: me,
        authorLogin: author,
        myReviewDates: [myReview],
        threads: [
            thread(resolved: true, resolvedBy: author, [("copilot-pull-request-reviewer", 11), (author, 15)]),
            thread(resolved: true, resolvedBy: author, [("github-actions", 11), (author, 15)]),
        ],
        headCommittedAt: nil,
        reviewRequestedFromMeAt: []
    )
    #expect(update == nil)
}

@Test func firesOnHeadCommitNewerThanYourReview() {
    let update = AuthorUpdate.latestUpdate(
        myLogin: me,
        authorLogin: author,
        myReviewDates: [myReview],
        threads: [],
        headCommittedAt: at(12),
        reviewRequestedFromMeAt: []
    )
    #expect(update == at(12))
}

@Test func firesWhenAuthorResolvesAThreadYouParticipatedIn() {
    // No resolvedAt exists in the API — the thread's newest comment stands in for it.
    let update = AuthorUpdate.latestUpdate(
        myLogin: me,
        authorLogin: author,
        myReviewDates: [myReview],
        threads: [thread(resolved: true, resolvedBy: author, [(me, 9), ("freemans13", 13)])],
        headCommittedAt: nil,
        reviewRequestedFromMeAt: []
    )
    #expect(update == at(13))
}

@Test func doesNotFireWhenSomeoneElseResolvedYourThread() {
    let update = AuthorUpdate.latestUpdate(
        myLogin: me,
        authorLogin: author,
        myReviewDates: [myReview],
        threads: [thread(resolved: true, resolvedBy: "freemans13", [(me, 9), ("freemans13", 13)])],
        headCommittedAt: nil,
        reviewRequestedFromMeAt: []
    )
    #expect(update == nil)
}

@Test func firesWhenReviewIsReRequestedFromYou() {
    let update = AuthorUpdate.latestUpdate(
        myLogin: me,
        authorLogin: author,
        myReviewDates: [myReview],
        threads: [],
        headCommittedAt: nil,
        reviewRequestedFromMeAt: [at(11)]
    )
    #expect(update == at(11))
}

@Test func reportsTheNewestSignalWhenSeveralQualify() {
    let update = AuthorUpdate.latestUpdate(
        myLogin: me,
        authorLogin: author,
        myReviewDates: [at(3), myReview],
        threads: [thread([(me, 9), (author, 12)])],
        headCommittedAt: at(16),
        reviewRequestedFromMeAt: [at(11)]
    )
    #expect(update == at(16))
}

@Test func staysOffWhenYouHaveNeverReviewedThePR() {
    // Nothing to measure "since" against — the chip must not fire on every open PR.
    let update = AuthorUpdate.latestUpdate(
        myLogin: me,
        authorLogin: author,
        myReviewDates: [],
        threads: [thread([(me, 9), (author, 20)])],
        headCommittedAt: at(20),
        reviewRequestedFromMeAt: [at(20)]
    )
    #expect(update == nil)
}

@Test func clearsOnceYourReviewIsTheNewestWord() {
    // The clearing rule: you reviewed again after everything the author did.
    let update = AuthorUpdate.latestUpdate(
        myLogin: me,
        authorLogin: author,
        myReviewDates: [at(4), at(18)],
        threads: [thread(resolved: true, resolvedBy: author, [(me, 5), (author, 12)])],
        headCommittedAt: at(14),
        reviewRequestedFromMeAt: [at(6)]
    )
    #expect(update == nil)
}

@Test func ignoresAuthorActivityOlderThanYourReview() {
    let update = AuthorUpdate.latestUpdate(
        myLogin: me,
        authorLogin: author,
        myReviewDates: [myReview],
        threads: [thread([(me, 5), (author, 8)])],
        headCommittedAt: at(7),
        reviewRequestedFromMeAt: [at(2)]
    )
    #expect(update == nil)
}

@Test func yourOwnLaterCommentsAreNotAnAuthorUpdate() {
    let update = AuthorUpdate.latestUpdate(
        myLogin: me,
        authorLogin: author,
        myReviewDates: [myReview],
        threads: [thread([(me, 9), (me, 15)])],
        headCommittedAt: nil,
        reviewRequestedFromMeAt: []
    )
    #expect(update == nil)
}

@Test func authorIsAlsoTheReviewerOnTheirOwnPR() {
    // Self-review edge: your login IS the author. A reply by "the author" is your own, so
    // only genuine pushes should count.
    let update = AuthorUpdate.latestUpdate(
        myLogin: me,
        authorLogin: me,
        myReviewDates: [myReview],
        threads: [thread([(me, 9), (me, 14)])],
        headCommittedAt: nil,
        reviewRequestedFromMeAt: []
    )
    #expect(update == nil)
}

@Test func unseenIsFalseWhenThereIsNoUpdate() {
    #expect(AuthorUpdate.isUnseen(updatedAt: nil, seenAt: nil) == false)
    #expect(AuthorUpdate.isUnseen(updatedAt: nil, seenAt: at(5)) == false)
}

@Test func unseenIsTrueWhenNothingHasBeenDismissedYet() {
    #expect(AuthorUpdate.isUnseen(updatedAt: at(12), seenAt: nil))
}

@Test func unseenIsTrueWhenTheAuthorMovedAgainAfterDismissal() {
    #expect(AuthorUpdate.isUnseen(updatedAt: at(14), seenAt: at(12)))
}

@Test func unseenIsFalseWhileTheDismissalStillCoversTheUpdate() {
    // Dismissing stores the current update time, so the same value must read as seen.
    #expect(AuthorUpdate.isUnseen(updatedAt: at(12), seenAt: at(12)) == false)
    #expect(AuthorUpdate.isUnseen(updatedAt: at(10), seenAt: at(12)) == false)
}
