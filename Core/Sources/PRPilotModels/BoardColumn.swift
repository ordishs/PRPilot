import Foundation

public enum BoardColumn: String, Sendable, Equatable, CaseIterable {
    case notStarted
    case inProgress
    case reviewing
    case inReview
    case waiting
    case done

    public var title: String {
        switch self {
        case .notStarted: return "Not started"
        case .inProgress: return "In progress"
        case .reviewing: return "Reviewing"
        case .inReview: return "Awaiting review"
        case .waiting: return "Waiting"
        case .done: return "Done"
        }
    }

    public var help: String {
        switch self {
        case .notStarted: return "Nothing has begun: no agent, no worktree, no review posted"
        case .inProgress: return "Work you or an agent must do: a fix, a rebase, failing CI, or an unfinished draft"
        case .reviewing: return "Your turn to review: PRs others asked you to review, and issues an agent has analysed"
        case .inReview: return "Your own PRs, waiting for other people to review them"
        case .waiting: return "Blocked on somebody or something else: CI, other reviewers, the author, or a hold"
        case .done: return "Merged or closed"
        }
    }
}

/// Inputs the column rule reads. `PRStatus` and `SidebarItemFacts` already carry the live
/// signals, so the rule never reaches into the model.
public struct BoardInput: Sendable, Equatable {
    public var item: WorkItem
    public var myLogin: String?
    public var facts: SidebarItemFacts
    public var prStatus: PRStatus?
    public var issueStatus: IssueWorkStatus?

    public init(
        item: WorkItem,
        myLogin: String?,
        facts: SidebarItemFacts = SidebarItemFacts(),
        prStatus: PRStatus? = nil,
        issueStatus: IssueWorkStatus? = nil
    ) {
        self.item = item
        self.myLogin = myLogin
        self.facts = facts
        self.prStatus = prStatus
        self.issueStatus = issueStatus
    }
}

/// Places one item in a column. Pure: the same input always gives the same column.
///
/// Order matters. The terminal states win first, then a hold, then the rule for the kind of
/// item. Every rule reads a signal the sidebar already shows, so a card never sits in a
/// column its badges do not explain.
public func boardColumn(for input: BoardInput) -> BoardColumn {
    let item = input.item
    let facts = input.facts

    if item.prState == .merged || item.prState == .closed { return .done }
    if let issueStatus = input.issueStatus, issueStatus == .done || issueStatus == .closed { return .done }
    if item.disabled || input.issueStatus == .onHold { return .waiting }

    switch item.category(myLogin: input.myLogin) {
    case .myPR:
        return myPRColumn(item: item, facts: facts, status: input.prStatus)
    case .reviewRequest:
        return reviewRequestColumn(item: item, facts: facts)
    case .issue:
        return issueColumn(input: input)
    case .task:
        return hasStarted(facts) ? .inProgress : .notStarted
    }
}

private func hasStarted(_ facts: SidebarItemFacts) -> Bool {
    facts.isWorking || facts.hasSession || facts.hasWorktree
}

private func myPRColumn(item: WorkItem, facts: SidebarItemFacts, status: PRStatus?) -> BoardColumn {
    if item.prState == .draft { return .inProgress }
    if facts.ciFailing || facts.hasConflict || facts.isBehind || facts.isWorking { return .inProgress }
    if facts.needsInput || facts.hasAuthorUpdate || facts.hasReviewerUpdate { return .inProgress }
    guard let status else { return .inReview }
    if status.readiness == .changesRequested {
        return status.changeRequests.isOutdatedOnly ? .waiting : .inProgress
    }
    if status.unresolvedThreads > 0 { return .inProgress }
    if status.ci == .pending { return .waiting }
    if status.readiness == .approved, !status.isReadyToMerge(prState: item.prState) { return .waiting }
    return .inReview
}

private func reviewRequestColumn(item: WorkItem, facts: SidebarItemFacts) -> BoardColumn {
    if item.prState == .draft { return .waiting }
    if facts.awaitsMyResponse || facts.needsInput || facts.isWorking || facts.hasAuthorUpdate {
        return .reviewing
    }
    switch item.myReviewState {
    case .approved, .commented, .changesRequested:
        return .waiting
    case nil, .some(.none):
        return hasStarted(facts) ? .reviewing : .notStarted
    }
}

private func issueColumn(input: BoardInput) -> BoardColumn {
    switch input.issueStatus ?? .new {
    case .inReview: return .inProgress
    case .reviewed: return .reviewing
    case .onHold: return .waiting
    case .done, .closed: return .done
    case .new: return hasStarted(input.facts) ? .inProgress : .notStarted
    }
}

private struct IssueKey: Hashable {
    let repoKey: String
    let number: Int
}

/// The issues some PR in the list closes. Built once per pass, so the board does not rescan
/// every item for each item.
private func closedIssueKeys(_ items: [WorkItem]) -> Set<IssueKey> {
    Set(items.compactMap { item in
        guard item.prRef != nil, let number = item.closingIssueNumber else { return nil }
        return IssueKey(repoKey: item.repoKey, number: number)
    })
}

private func isCovered(_ item: WorkItem, by closed: Set<IssueKey>) -> Bool {
    guard item.prRef == nil, let number = item.issueNumber else { return false }
    return closed.contains(IssueKey(repoKey: item.repoKey, number: number))
}

/// Whether the board should show this issue as its own card. An issue that a PR in the same
/// repository closes shares the PR's card instead, which carries a "closes #N" line.
public func isIssueCoveredByPR(_ item: WorkItem, among items: [WorkItem]) -> Bool {
    isCovered(item, by: closedIssueKeys(items))
}

/// Groups items by column. Covered issues drop out, and each column keeps the order the
/// caller supplied.
public func boardColumns(
    items: [WorkItem],
    input: (WorkItem) -> BoardInput
) -> [BoardColumn: [WorkItem]] {
    let closed = closedIssueKeys(items)
    var columns: [BoardColumn: [WorkItem]] = [:]
    for item in items where !isCovered(item, by: closed) {
        columns[boardColumn(for: input(item)), default: []].append(item)
    }
    return columns
}
