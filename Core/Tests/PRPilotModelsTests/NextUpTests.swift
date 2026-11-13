import Testing
import Foundation
@testable import PRPilotModels

private let me = "me"
private let now = Date(timeIntervalSince1970: 1_700_100_000)

private func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }

private func link(_ path: String) -> URL { URL(string: "https://github.com/acme/app/\(path)")! }

private func pr(
    author: String,
    id: String = "pr1",
    number: Int = 1,
    state: PRState = .open,
    myReview: MyReviewState? = nil
) -> WorkItem {
    var item = WorkItem(
        id: id, title: "pr", repoKey: "github.com/acme/app", baseBranch: "main",
        prRef: PRRef(owner: "acme", repo: "app", number: number, url: link("pull/\(number)"), authorLogin: author),
        prState: state, origin: .added, addedAt: hoursAgo(100)
    )
    item.myReviewState = myReview
    return item
}

private func issue(id: String = "issue1") -> WorkItem {
    WorkItem(
        id: id, title: "issue", repoKey: "github.com/acme/app", baseBranch: "main",
        issueRef: IssueRef(owner: "acme", repo: "app", number: 7, url: link("issues/7"), authorLogin: "x"),
        prState: .open, origin: .added, addedAt: hoursAgo(100)
    )
}

private func status(
    ci: CIStatus = .passing,
    merge: MergeState = .clean,
    readiness: ReviewReadiness = .reviewRequired,
    threads: Int = 0,
    changes: ChangeRequestTally = ChangeRequestTally(),
    authorUpdatedAt: Date? = nil,
    failed: [String] = [],
    head: String? = "h1"
) -> PRStatus {
    PRStatus(
        ci: ci, mergeState: merge, readiness: readiness, unresolvedThreads: threads,
        authorUpdatedAt: authorUpdatedAt, changeRequests: changes, headOID: head, failedChecks: failed
    )
}

private func rows(
    _ item: WorkItem,
    facts: SidebarItemFacts = SidebarItemFacts(),
    status: PRStatus? = nil,
    issueStatus: IssueWorkStatus? = nil,
    stoppedAt: Date? = nil
) -> [NextUpRow] {
    nextUp(
        inputs: [BoardInput(item: item, myLogin: me, facts: facts, prStatus: status, issueStatus: issueStatus, agentStoppedAt: stoppedAt)],
        now: now
    )
}

@Test func reviewRequestWithNoReviewOfMineIsCaseOne() {
    var item = pr(author: "alice")
    item.addedAt = hoursAgo(2)
    let result = rows(item)

    #expect(result.count == 1)
    #expect(result[0].kase == .reviewRequested)
    #expect(result[0].step == .startReview)
    #expect(result[0].reason == "Review requested by alice · 2h")
}

@Test func reviewRequestUsesAuthorUpdateTimeWhenTheAuthorUpdated() {
    let result = rows(
        pr(author: "alice", myReview: .commented),
        facts: SidebarItemFacts(hasAuthorUpdate: true),
        status: status(authorUpdatedAt: hoursAgo(5))
    )

    #expect(result.count == 1)
    #expect(result[0].reason == "Review requested by alice · 5h")
    #expect(result[0].since == hoursAgo(5))
}

@Test func reviewRequestIAlreadyReviewedAndTheAuthorLeftAloneGivesNoRow() {
    #expect(rows(pr(author: "alice", myReview: .changesRequested)).isEmpty)
    #expect(rows(pr(author: "alice", myReview: .approved)).isEmpty)
}

@Test func draftReviewRequestGivesNoRow() {
    #expect(rows(pr(author: "alice", state: .draft)).isEmpty)
}

@Test func waitingAgentIsCaseTwoOnAnyTicket() {
    let facts = SidebarItemFacts(needsInput: true)

    for item in [pr(author: me), pr(author: "alice", myReview: .approved), issue()] {
        let result = rows(item, facts: facts, stoppedAt: hoursAgo(1))

        #expect(result.count == 1)
        #expect(result[0].kase == .sessionWaits)
        #expect(result[0].step == .open)
        #expect(result[0].reason == "Agent waits for your answer")
    }
}

@Test func failingCIOnMyPRIsCaseThreeWithCheckNames() {
    let result = rows(
        pr(author: me),
        facts: SidebarItemFacts(ciFailing: true),
        status: status(ci: .failing, failed: ["build", "lint"])
    )

    #expect(result.count == 1)
    #expect(result[0].kase == .ciRed)
    #expect(result[0].step == .startFix)
    #expect(result[0].reason == "CI red: build, lint")
    #expect(result[0].trigger == "h1")
}

@Test func failingCIWithNoCheckNamesStillReadsCIRed() {
    let result = rows(pr(author: me), facts: SidebarItemFacts(ciFailing: true), status: status(ci: .failing))

    #expect(result[0].reason == "CI red")
}

@Test func noCIChecksGivesNoCIRow() {
    #expect(rows(pr(author: me), status: status(ci: CIStatus.none)).isEmpty)
}

@Test func changesRequestedIsCaseFourWithThreadCount() {
    let result = rows(
        pr(author: me),
        status: status(readiness: .changesRequested, threads: 3, changes: ChangeRequestTally(current: 1))
    )

    #expect(result.count == 1)
    #expect(result[0].kase == .changesRequested)
    #expect(result[0].step == .startFix)
    #expect(result[0].reason == "3 comments to address")
}

@Test func openThreadsAloneAreCaseFourAndOneReadsInSingular() {
    let result = rows(pr(author: me), status: status(threads: 1))

    #expect(result[0].kase == .changesRequested)
    #expect(result[0].reason == "1 comment to address")
}

@Test func changesRequestedOnlyOnAnOutdatedCommitWaitsOnTheReviewer() {
    let result = rows(
        pr(author: me),
        status: status(readiness: .changesRequested, changes: ChangeRequestTally(current: 0, outdated: 1))
    )

    #expect(result.isEmpty)
}

@Test func conflictIsCaseFiveAndNamesTheBase() {
    let result = rows(pr(author: me), facts: SidebarItemFacts(hasConflict: true), status: status(merge: .conflict))

    #expect(result[0].kase == .conflict)
    #expect(result[0].step == .startFix)
    #expect(result[0].reason == "Conflict with main")
}

@Test func behindIsCaseSixWithRebaseStep() {
    let result = rows(pr(author: me), facts: SidebarItemFacts(isBehind: true), status: status(merge: .behind))

    #expect(result[0].kase == .behind)
    #expect(result[0].step == .rebase)
    #expect(result[0].reason == "Behind main")
}

@Test func readyToMergeIsCaseSevenWithOpenStep() {
    let result = rows(pr(author: me), facts: SidebarItemFacts(isReady: true), status: status(readiness: .approved))

    #expect(result[0].kase == .readyToMerge)
    #expect(result[0].step == .open)
    #expect(result[0].reason == "Approved and green · ready to merge")
}

@Test func idleInProgressIssueIsCaseEight() {
    let result = rows(issue(), issueStatus: .inReview, stoppedAt: hoursAgo(3))

    #expect(result.count == 1)
    #expect(result[0].kase == .issueInProgress)
    #expect(result[0].step == .continueWork)
    #expect(result[0].reason == "Agent idle 3h")
}

@Test func aTicketGivesOneRowAtItsLowestRank() {
    let result = rows(
        pr(author: me),
        facts: SidebarItemFacts(ciFailing: true, isBehind: true, hasConflict: true),
        status: status(ci: .failing, merge: .conflict, threads: 2)
    )

    #expect(result.count == 1)
    #expect(result[0].kase == .ciRed)
}

@Test func rowsSortByRankThenOldestWait() {
    let review = pr(author: "alice", id: "review", number: 2)
    let oldCI = pr(author: me, id: "oldCI", number: 3)
    let newCI = pr(author: me, id: "newCI", number: 4)
    var stale = status(ci: .failing)
    stale.updatedAt = hoursAgo(10)
    var fresh = status(ci: .failing)
    fresh.updatedAt = hoursAgo(1)
    let ci = SidebarItemFacts(ciFailing: true)

    let result = nextUp(
        inputs: [
            BoardInput(item: newCI, myLogin: me, facts: ci, prStatus: fresh),
            BoardInput(item: oldCI, myLogin: me, facts: ci, prStatus: stale),
            BoardInput(item: review, myLogin: me),
        ],
        now: now
    )

    #expect(result.map(\.itemID) == ["review", "oldCI", "newCI"])
}

@Test func disabledOnHoldMergedClosedAndWorkingTicketsGiveNoRow() {
    var disabled = pr(author: me)
    disabled.disabled = true
    let ci = SidebarItemFacts(ciFailing: true)
    let failing = status(ci: .failing)

    #expect(rows(disabled, facts: ci, status: failing).isEmpty)
    #expect(rows(pr(author: me, state: .merged), facts: ci, status: failing).isEmpty)
    #expect(rows(pr(author: me, state: .closed), facts: ci, status: failing).isEmpty)
    #expect(rows(pr(author: me), facts: SidebarItemFacts(isWorking: true, ciFailing: true), status: failing).isEmpty)
    #expect(rows(issue(), issueStatus: .onHold).isEmpty)
    #expect(rows(issue(), issueStatus: .done).isEmpty)
    #expect(rows(issue(), issueStatus: .inReview, stoppedAt: hoursAgo(1)).count == 1)
}

@Test func sameCaseOnANewHeadCommitIsANewCause() {
    let facts = SidebarItemFacts(ciFailing: true)
    let first = rows(pr(author: me), facts: facts, status: status(ci: .failing, head: "h1"))
    let second = rows(pr(author: me), facts: facts, status: status(ci: .failing, head: "h2"))

    #expect(first[0].trigger != second[0].trigger)
}

@Test func nextUpStepHasNoMergeOrPostCase() {
    #expect(NextUpStep.allCases.map(\.rawValue).sorted() == ["continueWork", "open", "rebase", "startFix", "startReview"])
}
