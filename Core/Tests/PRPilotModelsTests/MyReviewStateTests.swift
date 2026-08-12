import Testing
import Foundation
@testable import PRPilotModels

private func submission(_ state: String, _ secondsFromEpoch: TimeInterval?) -> MyReviewSubmission {
    MyReviewSubmission(
        state: state,
        submittedAt: secondsFromEpoch.map { Date(timeIntervalSince1970: $0) }
    )
}

@Test func noReviewsResolvesToNone() {
    let resolved = MyReviewState.resolve(from: [])

    #expect(resolved.state == .none)
    #expect(resolved.lastSubmittedAt == nil)
}

@Test func aCommentedReviewResolvesToCommented() {
    let resolved = MyReviewState.resolve(from: [submission("COMMENTED", 100)])

    #expect(resolved.state == .commented)
    #expect(resolved.lastSubmittedAt == Date(timeIntervalSince1970: 100))
}

@Test func anApprovalResolvesToApproved() {
    let resolved = MyReviewState.resolve(from: [
        submission("COMMENTED", 100),
        submission("APPROVED", 200),
    ])

    #expect(resolved.state == .approved)
    #expect(resolved.lastSubmittedAt == Date(timeIntervalSince1970: 200))
}

@Test func theNewestDecisiveReviewWinsOverAnOlderOne() {
    let resolved = MyReviewState.resolve(from: [
        submission("APPROVED", 100),
        submission("CHANGES_REQUESTED", 200),
    ])

    #expect(resolved.state == .changesRequested)
}

/// A later COMMENTED review must not override an earlier decisive one, matching the
/// existing `decisive` filter that drives approvedByMe today.
@Test func aLaterCommentDoesNotOverrideAnApproval() {
    let resolved = MyReviewState.resolve(from: [
        submission("APPROVED", 100),
        submission("COMMENTED", 200),
    ])

    #expect(resolved.state == .approved)
    #expect(resolved.lastSubmittedAt == Date(timeIntervalSince1970: 200))
}

@Test func aDismissedApprovalResolvesToCommentedNotApproved() {
    let resolved = MyReviewState.resolve(from: [
        submission("APPROVED", 100),
        submission("DISMISSED", 200),
    ])

    #expect(resolved.state == .commented)
}

@Test func aPendingDraftNeverCounts() {
    let resolved = MyReviewState.resolve(from: [submission("PENDING", 100)])

    #expect(resolved.state == .none)
    #expect(resolved.lastSubmittedAt == nil)
}

@Test func lastSubmittedAtIgnoresPendingButCountsComments() {
    let resolved = MyReviewState.resolve(from: [
        submission("APPROVED", 100),
        submission("COMMENTED", 300),
        submission("PENDING", 900),
    ])

    #expect(resolved.lastSubmittedAt == Date(timeIntervalSince1970: 300))
}

@Test func aReviewWithNoSubmittedDateStillSetsTheState() {
    let resolved = MyReviewState.resolve(from: [submission("CHANGES_REQUESTED", nil)])

    #expect(resolved.state == .changesRequested)
    #expect(resolved.lastSubmittedAt == nil)
}
