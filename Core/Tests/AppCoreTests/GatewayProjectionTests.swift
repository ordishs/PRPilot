import Testing
import Foundation
import PRPilotModels
import GatewayKit
@testable import AppCore

private func noFacts(_ id: String) -> GatewayItemFacts {
    GatewayItemFacts(
        id: id,
        isDisabled: false,
        limitMessage: nil,
        awaitsMyResponse: false,
        hasVerdict: false,
        hasUnseenAuthorUpdate: false,
        sessionIsLive: false,
        isQueued: false
    )
}

private func limitedFacts(_ id: String) -> GatewayItemFacts {
    GatewayItemFacts(
        id: id,
        isDisabled: false,
        limitMessage: "5-hour limit reached",
        awaitsMyResponse: false,
        hasVerdict: false,
        hasUnseenAuthorUpdate: false,
        sessionIsLive: false,
        isQueued: false
    )
}

private func prItem(
    id: String = "bsv-blockchain/teranode#4788",
    title: String = "UTXO store: drop the legacy index path",
    disabled: Bool = false,
    label: String? = nil
) -> WorkItem {
    WorkItem(
        id: id,
        title: title,
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "feat/utxo-legacy-drop",
        prRef: PRRef(
            owner: "bsv-blockchain",
            repo: "teranode",
            number: 4788,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/4788")!,
            authorLogin: "bob"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_789_000_000),
        disabled: disabled,
        label: label
    )
}

private let plainDecoration = GatewayProjection.Decoration(
    agent: nil,
    badges: [],
    issueStatus: nil,
    ahead: 0,
    behind: 0,
    localChanges: 0
)

@Test func aPullRequestProjectsItsIdentityOntoTheWireItem() {
    let projected = GatewayProjection.item(
        from: prItem(),
        facts: noFacts("bsv-blockchain/teranode#4788"),
        decoration: GatewayProjection.Decoration(
            agent: nil,
            badges: [],
            issueStatus: nil,
            ahead: 0,
            behind: 12,
            localChanges: 2
        )
    )

    #expect(projected.kind == .pr)
    #expect(projected.owner == "bsv-blockchain")
    #expect(projected.repo == "teranode")
    #expect(projected.number == 4788)
    #expect(projected.author == "bob")
    #expect(projected.baseBranch == "main")
    #expect(projected.headBranch == "feat/utxo-legacy-drop")
    #expect(projected.url == "https://github.com/bsv-blockchain/teranode/pull/4788")
    #expect(projected.behind == 12)
    #expect(projected.localChanges == 2)
}

@Test func aLimitedItemCarriesItsReasonAndPrimaryCommandFromTheGroupingRule() {
    let projected = GatewayProjection.item(
        from: prItem(),
        facts: limitedFacts("bsv-blockchain/teranode#4788"),
        decoration: plainDecoration
    )

    #expect(projected.attentionReason == "Agent hit its usage limit")
    #expect(projected.primaryCommand == .clearAgentLimit(id: "bsv-blockchain/teranode#4788"))
}

@Test func anItemWithNothingOutstandingCarriesNoReasonAndNoPrimaryCommand() {
    let projected = GatewayProjection.item(
        from: prItem(),
        facts: noFacts("bsv-blockchain/teranode#4788"),
        decoration: plainDecoration
    )

    #expect(projected.attentionReason == nil)
    #expect(projected.primaryCommand == nil)
}

@Test func anIssueProjectsAsAnIssue() {
    let issue = WorkItem(
        id: "bsv-blockchain/teranode!391",
        title: "Block validation timeout is too tight",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        issueRef: IssueRef(
            owner: "bsv-blockchain",
            repo: "teranode",
            number: 391,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/issues/391")!,
            authorLogin: "carol"
        ),
        origin: .discovered,
        addedAt: Date(timeIntervalSince1970: 1_789_000_000)
    )

    let projected = GatewayProjection.item(
        from: issue,
        facts: noFacts(issue.id),
        decoration: plainDecoration
    )

    #expect(projected.kind == .issue)
    #expect(projected.number == 391)
    #expect(projected.author == "carol")
}

@Test func aFreeformTaskProjectsAsATaskWithNoNumberOrUrl() {
    let task = WorkItem(
        id: "local/scratch",
        title: "Spike the gateway",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_789_000_000)
    )

    let projected = GatewayProjection.item(
        from: task,
        facts: noFacts("local/scratch"),
        decoration: plainDecoration
    )

    #expect(projected.kind == .task)
    #expect(projected.number == nil)
    #expect(projected.url == nil)
    #expect(projected.owner == nil)
}

@Test func theLabelTravelsToTheClient() {
    let projected = GatewayProjection.item(
        from: prItem(label: "perf"),
        facts: noFacts("bsv-blockchain/teranode#4788"),
        decoration: plainDecoration
    )

    #expect(projected.label == "perf")
}

@Test func groupsAreOrderedNeedsYouRunningQueuedIdleAndEmptyOnesAreDropped() {
    let needy = prItem(id: "a#1", title: "needy")
    let plain = prItem(id: "a#2", title: "plain")

    let groups = GatewayProjection.groups(
        items: [plain, needy],
        facts: ["a#1": limitedFacts("a#1"), "a#2": noFacts("a#2")],
        decorate: { _ in plainDecoration }
    )

    #expect(groups.map(\.kind) == [.needsYou, .idle])
    #expect(groups[0].items.map(\.title) == ["needy"])
    #expect(groups[1].items.map(\.title) == ["plain"])
}

@Test func anItemWithNoFactsIsLeftOutRatherThanGuessedAt() {
    let groups = GatewayProjection.groups(
        items: [prItem(id: "a#1")],
        facts: [:],
        decorate: { _ in plainDecoration }
    )

    #expect(groups.isEmpty)
}

@Test func removeIsRefusedWhileTheWorktreeHasLocalChanges() {
    #expect(GatewayProjection.removalRefusal(localChanges: 2) != nil)
    #expect(GatewayProjection.removalRefusal(localChanges: 1) != nil)
    #expect(GatewayProjection.removalRefusal(localChanges: 0) == nil)
}

@Test func theRemovalRefusalSaysHowManyChangesAndWhereToGo() {
    let refusal = GatewayProjection.removalRefusal(localChanges: 1)

    #expect(refusal?.contains("1 local change") == true)
    #expect(refusal?.contains("Remove it at the Mac") == true)
}
