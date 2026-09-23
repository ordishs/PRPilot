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
        hasUnseenAuthorUpdate: false
    )
}

private func limitedFacts(_ id: String) -> GatewayItemFacts {
    GatewayItemFacts(
        id: id,
        isDisabled: false,
        limitMessage: "5-hour limit reached",
        awaitsMyResponse: false,
        hasUnseenAuthorUpdate: false
    )
}

private func prItem(
    id: String = "bsv-blockchain/teranode#4788",
    title: String = "UTXO store: drop the legacy index path",
    disabled: Bool = false,
    label: String? = nil,
    author: String = "bob",
    prState: PRState = .open,
    addedAt: Date = Date(timeIntervalSince1970: 1_789_000_000)
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
            authorLogin: author
        ),
        prState: prState,
        origin: .added,
        addedAt: addedAt,
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
        sidebar: SidebarItemFacts(),
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

@Test func aLimitedItemCarriesItsReasonAndPrimaryCommandFromTheAttentionRule() {
    let projected = GatewayProjection.item(
        from: prItem(),
        facts: limitedFacts("bsv-blockchain/teranode#4788"),
        sidebar: SidebarItemFacts(),
        decoration: plainDecoration
    )

    #expect(projected.attentionReason == "Agent hit its usage limit")
    #expect(projected.primaryCommand == .clearAgentLimit(id: "bsv-blockchain/teranode#4788"))
}

@Test func anItemWithNothingOutstandingCarriesNoReasonAndNoPrimaryCommand() {
    let projected = GatewayProjection.item(
        from: prItem(),
        facts: noFacts("bsv-blockchain/teranode#4788"),
        sidebar: SidebarItemFacts(),
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
        sidebar: SidebarItemFacts(),
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
        sidebar: SidebarItemFacts(),
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
        sidebar: SidebarItemFacts(),
        decoration: plainDecoration
    )

    #expect(projected.label == "perf")
}

@Test func signalsResourcesAndParkedTravelInTheMacPillOrder() {
    let projected = GatewayProjection.item(
        from: prItem(prState: .draft),
        facts: noFacts("bsv-blockchain/teranode#4788"),
        sidebar: SidebarItemFacts(
            awaitsMyResponse: true,
            ciFailing: true,
            hasConflict: true,
            hasWorktree: true,
            hasWebView: true,
            isParked: true
        ),
        decoration: plainDecoration
    )

    #expect(projected.signals == ["agent", "ciFailing", "conflict"])
    #expect(projected.resources == ["worktree", "web"])
    #expect(projected.isParked)
    #expect(projected.statusRank == statusRank(.draft))
    #expect(projected.addedAt == Date(timeIntervalSince1970: 1_789_000_000))
}

@Test func sectionsFollowTheMacSplitAndAreAlwaysAllThree() {
    let mine = prItem(id: "a#1", title: "mine", author: "ordishs")
    let theirs = prItem(id: "a#2", title: "theirs", author: "bob")

    let sections = GatewayProjection.sections(
        items: [theirs, mine],
        myLogin: "ordishs",
        sort: .recent,
        facts: ["a#1": noFacts("a#1"), "a#2": noFacts("a#2")],
        sidebarFacts: { _ in SidebarItemFacts() },
        decorate: { _ in plainDecoration }
    )

    #expect(sections.map(\.kind) == [.myWork, .reviewRequests, .issues])
    #expect(sections[0].items.map(\.title) == ["mine"])
    #expect(sections[1].items.map(\.title) == ["theirs"])
    #expect(sections[2].items.isEmpty)
}

@Test func sectionsAreSortedTheWayTheMacSortsThem() {
    let older = prItem(id: "a#1", title: "older", author: "amy", addedAt: Date(timeIntervalSince1970: 100))
    let newer = prItem(id: "a#2", title: "newer", author: "zed", addedAt: Date(timeIntervalSince1970: 200))
    let facts = ["a#1": noFacts("a#1"), "a#2": noFacts("a#2")]

    let recent = GatewayProjection.sections(
        items: [older, newer], myLogin: nil, sort: .recent, facts: facts,
        sidebarFacts: { _ in SidebarItemFacts() }, decorate: { _ in plainDecoration }
    )
    let byAuthor = GatewayProjection.sections(
        items: [newer, older], myLogin: nil, sort: .byAuthor, facts: facts,
        sidebarFacts: { _ in SidebarItemFacts() }, decorate: { _ in plainDecoration }
    )

    #expect(recent[1].items.map(\.title) == ["newer", "older"])
    #expect(byAuthor[1].items.map(\.title) == ["older", "newer"])
}

@Test func anItemWithNoFactsIsLeftOutRatherThanGuessedAt() {
    let sections = GatewayProjection.sections(
        items: [prItem(id: "a#1")],
        myLogin: nil,
        sort: .recent,
        facts: [:],
        sidebarFacts: { _ in SidebarItemFacts() },
        decorate: { _ in plainDecoration }
    )

    #expect(sections.allSatisfy { $0.items.isEmpty })
}

@Test func theListingWordsEveryPillAndSortTheWayTheMacDoes() {
    let listing = GatewayProjection.listing(sort: .byStatus, hideParked: true)

    #expect(listing.signalFilters.map(\.label) == SignalFilter.ordered.map(\.displayName))
    #expect(listing.signalFilters.map(\.help) == SignalFilter.ordered.map(\.help))
    #expect(listing.resourceFilters.map(\.label) == ResourceFilter.ordered.map(\.displayName))
    #expect(listing.sorts.map(\.label) == SidebarSort.allCases.map(\.displayName))
    #expect(listing.sort == "byStatus")
    #expect(listing.hideParked)
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
