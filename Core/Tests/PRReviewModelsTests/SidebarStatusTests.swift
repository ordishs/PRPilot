import Testing
import Foundation
@testable import PRReviewModels

private func review(
    prState: PRState = .open,
    lastOpenedAt: Date? = nil,
    claudeReviewedAt: Date? = nil,
    approvedByMe: Bool = false
) -> Review {
    Review(
        owner: "o", repo: "r", number: 1,
        url: URL(string: "https://github.com/o/r/pull/1")!,
        title: "t", author: "a", headBranch: "h", baseBranch: "main",
        origin: .added, prState: prState,
        addedAt: Date(timeIntervalSince1970: 0),
        lastOpenedAt: lastOpenedAt,
        claudeReviewedAt: claudeReviewedAt,
        approvedByMe: approvedByMe
    )
}

private let opened = Date(timeIntervalSince1970: 100)
private let claudeDone = Date(timeIntervalSince1970: 200)

@Test func mergedBeatsEverything() {
    #expect(review(prState: .merged, approvedByMe: true).sidebarStatus == .merged)
}

@Test func closedBeatsApproved() {
    #expect(review(prState: .closed, approvedByMe: true).sidebarStatus == .closed)
}

@Test func approvedBeatsNew() {
    #expect(review(lastOpenedAt: nil, approvedByMe: true).sidebarStatus == .approved)
}

@Test func unopenedIsNewEvenWhenClaudeReviewed() {
    #expect(review(lastOpenedAt: nil, claudeReviewedAt: claudeDone).sidebarStatus == .new)
}

@Test func openedAndClaudeReviewedIsReviewed() {
    #expect(review(lastOpenedAt: opened, claudeReviewedAt: claudeDone).sidebarStatus == .reviewed)
}

@Test func openedDraftWithoutReviewIsDraft() {
    #expect(review(prState: .draft, lastOpenedAt: opened).sidebarStatus == .draft)
}

@Test func unopenedDraftIsNew() {
    #expect(review(prState: .draft, lastOpenedAt: nil).sidebarStatus == .new)
}

@Test func openedNothingElseIsOpen() {
    #expect(review(lastOpenedAt: opened).sidebarStatus == .open)
}

@Test func approvedDraftIsApproved() {
    #expect(review(prState: .draft, lastOpenedAt: opened, approvedByMe: true).sidebarStatus == .approved)
}
