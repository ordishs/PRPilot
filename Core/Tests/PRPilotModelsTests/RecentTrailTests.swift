import Testing
import Foundation
@testable import PRPilotModels

private func prItem(lastPane: PaneSelection?, agent: AgentKind? = nil, disabled: Bool = false) -> WorkItem {
    var item = WorkItem(
        title: "t",
        repoKey: "github.com/o/r",
        baseBranch: "main",
        headBranch: "h",
        prRef: PRRef(
            owner: "o", repo: "r", number: 1,
            url: URL(string: "https://github.com/o/r/pull/1")!,
            authorLogin: "a"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 0)
    )
    item.lastPane = lastPane
    item.agent = agent
    item.disabled = disabled
    return item
}

@Test func visitPutsNewestFirst() {
    var trail = RecentTrail()
    trail.visit("a", at: Date(timeIntervalSince1970: 1))
    trail.visit("b", at: Date(timeIntervalSince1970: 2))

    #expect(trail.entries.map(\.itemID) == ["b", "a"])
}

@Test func secondVisitMovesAndDoesNotDuplicate() {
    var trail = RecentTrail()
    trail.visit("a", at: Date(timeIntervalSince1970: 1))
    trail.visit("b", at: Date(timeIntervalSince1970: 2))
    trail.visit("a", at: Date(timeIntervalSince1970: 3))

    #expect(trail.entries.map(\.itemID) == ["a", "b"])
    #expect(trail.entries[0].visitedAt == Date(timeIntervalSince1970: 3))
}

@Test func capacityHoldsAtTwenty() {
    var trail = RecentTrail()
    for n in 1...21 { trail.visit("t\(n)", at: Date(timeIntervalSince1970: Double(n))) }

    #expect(trail.entries.count == 20)
    #expect(trail.entries.first?.itemID == "t21")
    #expect(trail.entries.last?.itemID == "t2")
}

@Test func pruneDropsDeadTickets() {
    var trail = RecentTrail()
    for id in ["a", "b", "c"] { trail.visit(id, at: Date(timeIntervalSince1970: 1)) }
    trail.prune(keeping: ["a", "c"])

    #expect(trail.entries.map(\.itemID) == ["c", "a"])
}

@Test func ageLabel() {
    let now = Date(timeIntervalSince1970: 100_000)

    #expect(trailAgeLabel(since: now.addingTimeInterval(-59), now: now) == "now")
    #expect(trailAgeLabel(since: now.addingTimeInterval(-60), now: now) == "1m")
    #expect(trailAgeLabel(since: now.addingTimeInterval(-3_599), now: now) == "59m")
    #expect(trailAgeLabel(since: now.addingTimeInterval(-3_600), now: now) == "1h")
    #expect(trailAgeLabel(since: now.addingTimeInterval(-86_400), now: now) == "1d")
    #expect(trailAgeLabel(since: now.addingTimeInterval(60), now: now) == "now")
}

@Test func tabLabelIsGitHubForGitHubPane() {
    #expect(trailTabLabel(for: prItem(lastPane: .github), defaultAgent: .claudeCode) == "GitHub")
}

@Test func tabLabelIsAgentNameForAgentPane() {
    #expect(trailTabLabel(for: prItem(lastPane: .claude, agent: .codex), defaultAgent: .claudeCode) == "Codex")
    #expect(trailTabLabel(for: prItem(lastPane: .claude), defaultAgent: .pi) == "pi")
}

@Test func tabLabelIsGitHubForDisabledItem() {
    #expect(trailTabLabel(for: prItem(lastPane: .claude, disabled: true), defaultAgent: .claudeCode) == "GitHub")
}
