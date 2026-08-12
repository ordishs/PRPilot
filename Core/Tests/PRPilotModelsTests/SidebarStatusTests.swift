import Testing
import Foundation
@testable import PRPilotModels

private func review(
    prState: PRState = .open,
    authorLogin: String = "someone-else",
    lastOpenedAt: Date? = nil,
    claudeReviewedAt: Date? = nil,
    myReviewState: MyReviewState? = nil
) -> WorkItem {
    var item = WorkItem(
        title: "t",
        repoKey: "github.com/o/r",
        baseBranch: "main",
        headBranch: "h",
        prRef: PRRef(
            owner: "o", repo: "r", number: 1,
            url: URL(string: "https://github.com/o/r/pull/1")!,
            authorLogin: authorLogin
        ),
        prState: prState,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 0),
        lastOpenedAt: lastOpenedAt,
        claudeReviewedAt: claudeReviewedAt
    )
    item.myReviewState = myReviewState
    return item
}

private let me = "ordishs"

@Test func mergedBeatsEverything() {
    let item = review(prState: .merged, myReviewState: .approved)

    #expect(item.sidebarStatus(myLogin: me) == .merged)
}

@Test func closedBeatsApproved() {
    let item = review(prState: .closed, myReviewState: .approved)

    #expect(item.sidebarStatus(myLogin: me) == .closed)
}

@Test func approvedBeatsReviewed() {
    #expect(review(myReviewState: .approved).sidebarStatus(myLogin: me) == .approved)
}

@Test func aCommentedReviewIsReviewed() {
    #expect(review(myReviewState: .commented).sidebarStatus(myLogin: me) == .reviewed)
}

@Test func aChangeRequestIsReviewed() {
    #expect(review(myReviewState: .changesRequested).sidebarStatus(myLogin: me) == .reviewed)
}

/// The reported bug: clicking a row stamps lastOpenedAt, which used to clear NEW.
@Test func openingTheRowDoesNotClearNew() {
    let item = review(lastOpenedAt: Date(timeIntervalSince1970: 500))

    #expect(item.sidebarStatus(myLogin: me) == .new)
}

/// The other half of the bug: a completed Claude turn used to read as REVIEWED.
@Test func aCompletedClaudeReviewDoesNotMakeItReviewed() {
    let item = review(
        lastOpenedAt: Date(timeIntervalSince1970: 500),
        claudeReviewedAt: Date(timeIntervalSince1970: 600)
    )

    #expect(item.sidebarStatus(myLogin: me) == .new)
}

@Test func approvalStaysApprovedAfterANewerClaudeReview() {
    let item = review(
        claudeReviewedAt: Date(timeIntervalSince1970: 9_000),
        myReviewState: .approved
    )

    #expect(item.sidebarStatus(myLogin: me) == .approved)
}

@Test func anUnreviewedDraftIsDraft() {
    #expect(review(prState: .draft).sidebarStatus(myLogin: me) == .draft)
}

@Test func approvedDraftIsApproved() {
    #expect(review(prState: .draft, myReviewState: .approved).sidebarStatus(myLogin: me) == .approved)
}

@Test func aNeverReviewedRequestIsNewIndefinitely() {
    #expect(review().sidebarStatus(myLogin: me) == .new)
}

@Test func myOwnOpenPRIsOpenNotNew() {
    let item = review(authorLogin: me)

    #expect(item.sidebarStatus(myLogin: me) == .open)
}

@Test func myOwnDraftPRIsDraft() {
    let item = review(prState: .draft, authorLogin: me)

    #expect(item.sidebarStatus(myLogin: me) == .draft)
}

@Test func myOwnPRIgnoresMyReviewState() {
    let item = review(authorLogin: me, myReviewState: .approved)

    #expect(item.sidebarStatus(myLogin: me) == .open)
}
