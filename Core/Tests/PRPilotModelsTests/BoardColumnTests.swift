import Testing
import Foundation
@testable import PRPilotModels

private let me = "me"
private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

private func url(_ path: String) -> URL { URL(string: "https://github.com/acme/app/\(path)")! }

private func pr(
    author: String,
    number: Int = 1,
    state: PRState = .open,
    closes: Int? = nil,
    myReview: MyReviewState? = nil
) -> WorkItem {
    var item = WorkItem(
        id: "pr\(number)", title: "pr", repoKey: "github.com/acme/app", baseBranch: "main",
        prRef: PRRef(owner: "acme", repo: "app", number: number, url: url("pull/\(number)"), authorLogin: author),
        prState: state, origin: .added, closingIssueNumber: closes, addedAt: stamp
    )
    item.myReviewState = myReview
    return item
}

private func issue(number: Int = 7, manual: IssueWorkStatus? = nil) -> WorkItem {
    WorkItem(
        id: "issue\(number)", title: "issue", repoKey: "github.com/acme/app", baseBranch: "main",
        issueRef: IssueRef(owner: "acme", repo: "app", number: number, url: url("issues/\(number)"), authorLogin: "x"),
        prState: .open, origin: .added, addedAt: stamp, manualIssueStatus: manual
    )
}

private func task() -> WorkItem {
    WorkItem(id: "task", title: "task", repoKey: "github.com/acme/app", baseBranch: "main",
             origin: .added, addedAt: stamp)
}

private func column(
    _ item: WorkItem,
    facts: SidebarItemFacts = SidebarItemFacts(),
    status: PRStatus? = nil,
    issueStatus: IssueWorkStatus? = nil
) -> BoardColumn {
    boardColumn(for: BoardInput(item: item, myLogin: me, facts: facts, prStatus: status, issueStatus: issueStatus))
}

private func status(
    ci: CIStatus = .passing,
    merge: MergeState = .clean,
    readiness: ReviewReadiness = .reviewRequired,
    threads: Int = 0
) -> PRStatus {
    PRStatus(ci: ci, mergeState: merge, readiness: readiness, unresolvedThreads: threads)
}

@Test func mergedAndClosedAreDoneWhateverElseIsTrue() {
    #expect(column(pr(author: me, state: .merged), facts: SidebarItemFacts(isWorking: true)) == .done)
    #expect(column(pr(author: "o", state: .closed)) == .done)
}

@Test func issueMarkedDoneOrClosedIsDone() {
    #expect(column(issue(), issueStatus: .done) == .done)
    #expect(column(issue(), issueStatus: .closed) == .done)
}

@Test func disabledItemIsWaiting() {
    var item = pr(author: "o")
    item.disabled = true
    #expect(column(item) == .waiting)
}

@Test func issueOnHoldIsWaiting() {
    #expect(column(issue(), issueStatus: .onHold) == .waiting)
}

@Test func untouchedIssueIsNotStarted() {
    #expect(column(issue(), issueStatus: .new) == .notStarted)
    #expect(column(issue()) == .notStarted)
}

@Test func issueWithWorktreeOrSessionIsInProgress() {
    #expect(column(issue(), facts: SidebarItemFacts(hasWorktree: true), issueStatus: .new) == .inProgress)
    #expect(column(issue(), facts: SidebarItemFacts(hasSession: true), issueStatus: .new) == .inProgress)
}

@Test func issueWhileAgentWorksIsInProgress() {
    #expect(column(issue(), facts: SidebarItemFacts(isWorking: true), issueStatus: .inReview) == .inProgress)
}

@Test func issueAnAgentHasAnalysedStaysInProgressNotReviewing() {
    #expect(column(issue(), issueStatus: .reviewed) == .inProgress)
}

@Test func issuesNeverLandInReviewing() {
    for status in IssueWorkStatus.allCases {
        #expect(column(issue(), issueStatus: status) != .reviewing)
    }
}

@Test func taskWithoutResourcesIsNotStartedAndWithOneIsInProgress() {
    #expect(column(task()) == .notStarted)
    #expect(column(task(), facts: SidebarItemFacts(hasWorktree: true)) == .inProgress)
}

@Test func myDraftPRIsInProgress() {
    #expect(column(pr(author: me, state: .draft)) == .inProgress)
}

@Test func myPRNeedingAFixIsInProgress() {
    let item = pr(author: me)
    #expect(column(item, facts: SidebarItemFacts(ciFailing: true)) == .inProgress)
    #expect(column(item, facts: SidebarItemFacts(hasConflict: true)) == .inProgress)
    #expect(column(item, facts: SidebarItemFacts(isBehind: true)) == .inProgress)
    #expect(column(item, facts: SidebarItemFacts(isWorking: true)) == .inProgress)
    #expect(column(item, status: status(readiness: .changesRequested)) == .inProgress)
    #expect(column(item, status: status(threads: 2)) == .inProgress)
}

@Test func myPRWithPendingCIIsWaiting() {
    #expect(column(pr(author: me), status: status(ci: .pending)) == .waiting)
}

@Test func myPRAwaitingReviewersIsInReview() {
    #expect(column(pr(author: me), status: status(readiness: .reviewRequired)) == .inReview)
    #expect(column(pr(author: me)) == .inReview)
}

@Test func myApprovedPRThatCannotMergeYetIsWaitingAndReadyOneIsInReview() {
    #expect(column(pr(author: me), status: status(merge: .blocked, readiness: .approved)) == .waiting)
    #expect(column(pr(author: me), status: status(merge: .clean, readiness: .approved)) == .inReview)
}

@Test func unreviewedReviewRequestIsNotStarted() {
    #expect(column(pr(author: "o")) == .notStarted)
}

@Test func reviewRequestWithAgentActivityIsReviewing() {
    let item = pr(author: "o")
    #expect(column(item, facts: SidebarItemFacts(hasSession: true)) == .reviewing)
    #expect(column(item, facts: SidebarItemFacts(awaitsMyResponse: true)) == .reviewing)
    #expect(column(item, facts: SidebarItemFacts(needsInput: true)) == .reviewing)
}

@Test func reviewRequestsNeverLandInAwaitingReview() {
    let states: [SidebarItemFacts] = [
        SidebarItemFacts(), SidebarItemFacts(hasSession: true), SidebarItemFacts(awaitsMyResponse: true),
        SidebarItemFacts(hasAuthorUpdate: true), SidebarItemFacts(isWorking: true),
    ]
    for review in [nil, MyReviewState.approved, .commented, .changesRequested] {
        for facts in states {
            #expect(column(pr(author: "o", myReview: review), facts: facts) != .inReview)
        }
    }
}

@Test func myPRsWaitingOnReviewersStayInAwaitingReview() {
    #expect(BoardColumn.inReview.title == "Awaiting review")
    #expect(BoardColumn.reviewing.title == "Reviewing")
    #expect(column(pr(author: me)) == .inReview)
}

@Test func reviewRequestIAlreadyAnsweredWaitsOnTheAuthor() {
    #expect(column(pr(author: "o", myReview: .changesRequested)) == .waiting)
    #expect(column(pr(author: "o", myReview: .commented)) == .waiting)
    #expect(column(pr(author: "o", myReview: .approved)) == .waiting)
}

@Test func authorActivityReturnsAnAnsweredReviewToReviewing() {
    let item = pr(author: "o", myReview: .changesRequested)
    #expect(column(item, facts: SidebarItemFacts(hasAuthorUpdate: true)) == .reviewing)
}

@Test func draftReviewRequestIsWaiting() {
    #expect(column(pr(author: "o", state: .draft)) == .waiting)
}

@Test func issueClosedByAPRInTheSameRepoIsCovered() {
    let linked = pr(author: me, number: 12, closes: 7)
    #expect(isIssueCoveredByPR(issue(number: 7), among: [issue(number: 7), linked]))
    #expect(!isIssueCoveredByPR(issue(number: 8), among: [issue(number: 8), linked]))
    #expect(!isIssueCoveredByPR(linked, among: [linked]))
}

@Test func coveredIssueInAnotherRepoIsNotHidden() {
    var other = issue(number: 7)
    other.repoKey = "github.com/acme/other"
    #expect(!isIssueCoveredByPR(other, among: [other, pr(author: me, number: 12, closes: 7)]))
}

@Test func boardColumnsGroupsAndDropsCoveredIssues() {
    let items = [issue(number: 7), pr(author: me, number: 12, closes: 7), task(), pr(author: "o", number: 3, state: .merged)]
    let grouped = boardColumns(items: items) { BoardInput(item: $0, myLogin: me) }
    #expect(grouped[.notStarted]?.map(\.id) == ["task"])
    #expect(grouped[.inReview]?.map(\.id) == ["pr12"])
    #expect(grouped[.done]?.map(\.id) == ["pr3"])
    #expect(grouped.values.flatMap { $0 }.count == 3)
}

@Test func myPRWithAReviewerReplyIsInProgress() {
    #expect(column(pr(author: me), facts: SidebarItemFacts(hasReviewerUpdate: true), status: status()) == .inProgress)
}

@Test func reviewerReplyCountsAsNeedingAttention() {
    #expect(SidebarItemFacts(hasReviewerUpdate: true).wantsAttention)
    #expect(!SidebarItemFacts().wantsAttention)
}

@Test func myPRWithOnlyOutdatedChangeRequestsIsWaitingOnTheReviewer() {
    let outdated = PRStatus(ci: .passing, mergeState: .blocked, readiness: .changesRequested,
                            changeRequests: ChangeRequestTally(current: 0, outdated: 1))
    #expect(column(pr(author: me), status: outdated) == .waiting)
}

@Test func myPRWithACurrentChangeRequestStaysInProgress() {
    let current = PRStatus(ci: .passing, mergeState: .blocked, readiness: .changesRequested,
                           changeRequests: ChangeRequestTally(current: 1, outdated: 1))
    #expect(column(pr(author: me), status: current) == .inProgress)
    let unknown = PRStatus(ci: .passing, mergeState: .blocked, readiness: .changesRequested)
    #expect(column(pr(author: me), status: unknown) == .inProgress)
}

@Test func aFreshReviewerReplyBeatsAnOutdatedRequest() {
    let outdated = PRStatus(ci: .passing, mergeState: .blocked, readiness: .changesRequested,
                            changeRequests: ChangeRequestTally(current: 0, outdated: 1))
    #expect(column(pr(author: me), facts: SidebarItemFacts(hasReviewerUpdate: true), status: outdated) == .inProgress)
}

@Test func myPRWhoseOpenThreadsAllWaitOnTheReviewerIsAwaitingReview() {
    let replied = PRStatus(ci: .passing, mergeState: .clean, readiness: .reviewRequired,
                           unresolvedThreads: 2, threadsAwaitingMe: 0)
    #expect(column(pr(author: me), status: replied) == .inReview)
}

@Test func myPRWithAThreadIHaveNotAnsweredIsInProgress() {
    let open = PRStatus(ci: .passing, mergeState: .clean, readiness: .reviewRequired,
                        unresolvedThreads: 2, threadsAwaitingMe: 1)
    #expect(column(pr(author: me), status: open) == .inProgress)
}

@Test func anOlderPayloadWithoutTheAnswerCountTreatsEveryOpenThreadAsMine() {
    let legacy = PRStatus(ci: .passing, mergeState: .clean, readiness: .reviewRequired, unresolvedThreads: 1)
    #expect(column(pr(author: me), status: legacy) == .inProgress)
}
