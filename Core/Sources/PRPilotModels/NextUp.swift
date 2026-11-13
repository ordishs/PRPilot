import Foundation

public enum NextUpCase: Int, Codable, Sendable, Equatable, Comparable {
    case reviewRequested = 1
    case sessionWaits
    case ciRed
    case changesRequested
    case conflict
    case behind
    case readyToMerge
    case issueInProgress

    public static func < (left: NextUpCase, right: NextUpCase) -> Bool {
        left.rawValue < right.rawValue
    }
}

public enum NextUpStep: String, Codable, Sendable, Equatable, CaseIterable {
    case startReview
    case startFix
    case rebase
    case continueWork
    case open
}

public struct NextUpRow: Sendable, Equatable, Identifiable {
    public let itemID: String
    public let kase: NextUpCase
    public let reason: String
    public let step: NextUpStep
    public let since: Date
    public let trigger: String

    public var id: String { itemID }

    public init(itemID: String, kase: NextUpCase, reason: String, step: NextUpStep, since: Date, trigger: String) {
        self.itemID = itemID
        self.kase = kase
        self.reason = reason
        self.step = step
        self.since = since
        self.trigger = trigger
    }
}

/// Ranks the open tickets by what the user should look at first. Pure, and fed by the same
/// `BoardInput` the board reads, so a row never disagrees with a badge.
///
/// A ticket gives at most one row, at its lowest rank number. A ticket that is disabled, on
/// hold, finished, or has a working agent gives none: the step is already under way.
public func nextUp(inputs: [BoardInput], now: Date) -> [NextUpRow] {
    inputs
        .compactMap { nextUpRow(for: $0, now: now) }
        .sorted { left, right in
            if left.kase != right.kase { return left.kase < right.kase }
            if left.since != right.since { return left.since < right.since }

            return left.itemID < right.itemID
        }
}

private func nextUpRow(for input: BoardInput, now: Date) -> NextUpRow? {
    let item = input.item

    if item.disabled || input.facts.isWorking { return nil }
    if item.prState == .merged || item.prState == .closed { return nil }
    if let issueStatus = input.issueStatus, issueStatus == .onHold || issueStatus == .done || issueStatus == .closed {
        return nil
    }

    func row(_ kase: NextUpCase, _ reason: String, _ step: NextUpStep, since: Date, trigger: String) -> NextUpRow {
        NextUpRow(itemID: item.id, kase: kase, reason: reason, step: step, since: since, trigger: trigger)
    }

    let facts = input.facts
    let status = input.prStatus
    let category = item.category(myLogin: input.myLogin)
    let head = status?.headOID ?? ""
    let waitingSince = status?.updatedAt ?? item.addedAt

    if category == .reviewRequest, item.prState != .draft, needsMyReview(item: item, facts: facts) {
        let since = status?.authorUpdatedAt ?? item.addedAt
        let author = item.author ?? "author"

        return row(
            .reviewRequested,
            "Review requested by \(author) · \(trailAgeLabel(since: since, now: now))",
            .startReview,
            since: since,
            trigger: stamp(since)
        )
    }

    if facts.needsInput {
        let since = input.agentStoppedAt ?? now

        return row(.sessionWaits, "Agent waits for your answer", .open, since: since, trigger: stamp(input.agentStoppedAt))
    }

    if category == .myPR {
        if facts.ciFailing {
            let names = status?.failedChecks ?? []
            let reason = names.isEmpty ? "CI red" : "CI red: \(names.joined(separator: ", "))"

            return row(.ciRed, reason, .startFix, since: waitingSince, trigger: head)
        }

        if let status, hasWorkToAddress(status) {
            let count = status.openThreadsForMe
            let reason = count == 0
                ? "Changes requested"
                : "\(count) \(count == 1 ? "comment" : "comments") to address"

            return row(.changesRequested, reason, .startFix, since: waitingSince, trigger: head)
        }

        if facts.hasConflict {
            return row(.conflict, "Conflict with \(item.baseBranch)", .startFix, since: waitingSince, trigger: head)
        }

        if facts.isBehind {
            return row(.behind, "Behind \(item.baseBranch)", .rebase, since: waitingSince, trigger: head)
        }

        if facts.isReady {
            return row(.readyToMerge, "Approved and green · ready to merge", .open, since: waitingSince, trigger: head)
        }
    }

    if category == .issue, boardColumn(for: input) == .inProgress {
        let since = input.agentStoppedAt ?? item.lastOpenedAt ?? item.addedAt

        return row(
            .issueInProgress,
            "Agent idle \(trailAgeLabel(since: since, now: now))",
            .continueWork,
            since: since,
            trigger: stamp(input.agentStoppedAt)
        )
    }

    return nil
}

private func needsMyReview(item: WorkItem, facts: SidebarItemFacts) -> Bool {
    switch item.myReviewState {
    case nil, .some(.none): return true
    case .approved, .commented, .changesRequested: return facts.hasAuthorUpdate
    }
}

private func hasWorkToAddress(_ status: PRStatus) -> Bool {
    if status.readiness == .changesRequested, !status.changeRequests.isOutdatedOnly { return true }

    return status.openThreadsForMe > 0
}

private func stamp(_ date: Date?) -> String {
    guard let date else { return "" }

    return ISO8601DateFormatter().string(from: date)
}
