import Testing
import Foundation
@testable import PRPilotModels

private func at(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

@Test func noCompletedClaudeTurnIsNotWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .reviewRequest,
        prState: .open,
        claudeLastCompletedAt: nil,
        myLastReviewAt: nil
    )

    #expect(waiting == false)
}

@Test func aCompletedTurnWithNoReviewFromMeIsWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .reviewRequest,
        prState: .open,
        claudeLastCompletedAt: at(100),
        myLastReviewAt: nil
    )

    #expect(waiting == true)
}

@Test func claudeNewerThanMyReviewIsWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .reviewRequest,
        prState: .open,
        claudeLastCompletedAt: at(200),
        myLastReviewAt: at(100)
    )

    #expect(waiting == true)
}

@Test func myReviewNewerThanClaudeIsNotWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .reviewRequest,
        prState: .open,
        claudeLastCompletedAt: at(100),
        myLastReviewAt: at(200)
    )

    #expect(waiting == false)
}

@Test func equalTimestampsAreNotWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .reviewRequest,
        prState: .open,
        claudeLastCompletedAt: at(100),
        myLastReviewAt: at(100)
    )

    #expect(waiting == false)
}

@Test func aMergedPRIsNeverWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .reviewRequest,
        prState: .merged,
        claudeLastCompletedAt: at(200),
        myLastReviewAt: nil
    )

    #expect(waiting == false)
}

@Test func aClosedPRIsNeverWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .reviewRequest,
        prState: .closed,
        claudeLastCompletedAt: at(200),
        myLastReviewAt: nil
    )

    #expect(waiting == false)
}

@Test func myOwnPRIsNeverWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .myPR,
        prState: .open,
        claudeLastCompletedAt: at(200),
        myLastReviewAt: nil
    )

    #expect(waiting == false)
}

@Test func anIssueIsNeverWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .issue,
        prState: .open,
        claudeLastCompletedAt: at(200),
        myLastReviewAt: nil
    )

    #expect(waiting == false)
}

@Test func aTaskIsNeverWaiting() {
    let waiting = isAwaitingMyResponse(
        category: .task,
        prState: nil,
        claudeLastCompletedAt: at(200),
        myLastReviewAt: nil
    )

    #expect(waiting == false)
}

/// The two signals are independent: an approved PR still shows Waiting when Claude has
/// produced newer output. This is the case the single-chain design could not express.
@Test func anApprovedPRCanStillBeWaiting() {
    var item = WorkItem(
        title: "t",
        repoKey: "github.com/o/r",
        baseBranch: "main",
        prRef: PRRef(
            owner: "o", repo: "r", number: 1,
            url: URL(string: "https://github.com/o/r/pull/1")!,
            authorLogin: "someone-else"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 0)
    )
    item.myReviewState = .approved
    item.myLastReviewAt = at(100)
    item.claudeLastCompletedAt = at(200)

    #expect(item.sidebarStatus(myLogin: "ordishs") == .approved)
    #expect(item.awaitsMyResponse(myLogin: "ordishs") == true)
}
