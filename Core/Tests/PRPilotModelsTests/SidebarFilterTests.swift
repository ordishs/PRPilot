import Testing
import Foundation
@testable import PRPilotModels

private func sample() -> WorkItem {
    WorkItem(
        title: "centrifuge fix",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "fix/centrifuge",
        prRef: PRRef(owner: "bsv-blockchain", repo: "teranode", number: 944,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!,
            authorLogin: "icellan"),
        prState: .open, origin: .added, addedAt: Date()
    )
}

private let noFacts = SidebarItemFacts()
private let noSelection = SidebarFilterSelection()

@Test func emptySelectionMatchesEverything() {
    #expect(sidebarItemMatches(sample(), query: "", selection: noSelection, facts: noFacts))
}

@Test func queryMatchesEachField() {
    let i = sample()
    #expect(sidebarItemMatches(i, query: "centrifuge", selection: noSelection, facts: noFacts))  // title
    #expect(sidebarItemMatches(i, query: "teranode", selection: noSelection, facts: noFacts))    // repo
    #expect(sidebarItemMatches(i, query: "icellan", selection: noSelection, facts: noFacts))     // author
    #expect(sidebarItemMatches(i, query: "fix/cent", selection: noSelection, facts: noFacts))    // branch
    #expect(sidebarItemMatches(i, query: "#944", selection: noSelection, facts: noFacts))        // number
    #expect(sidebarItemMatches(i, query: "TERANODE", selection: noSelection, facts: noFacts))    // case-insensitive
}

@Test func queryMatchesLabel() {
    var i = sample()
    i.label = "Blocks the mainnet upgrade"
    #expect(sidebarItemMatches(i, query: "mainnet", selection: noSelection, facts: noFacts))
    #expect(sidebarItemMatches(i, query: "MAINNET", selection: noSelection, facts: noFacts))
    #expect(!sidebarItemMatches(sample(), query: "mainnet", selection: noSelection, facts: noFacts))
}

@Test func nonMatchingQueryFails() {
    #expect(!sidebarItemMatches(sample(), query: "nope-zzz", selection: noSelection, facts: noFacts))
}

@Test func oneSignalNeedsThatFact() {
    let selection = SidebarFilterSelection(signals: .agent)
    #expect(sidebarItemMatches(sample(), query: "", selection: selection,
                               facts: SidebarItemFacts(awaitsMyResponse: true)))
    #expect(!sidebarItemMatches(sample(), query: "", selection: selection,
                                facts: SidebarItemFacts(isWorking: true)))
}

@Test func signalsCombineAsOr() {
    let selection = SidebarFilterSelection(signals: [.agent, .author])
    #expect(sidebarItemMatches(sample(), query: "", selection: selection,
                               facts: SidebarItemFacts(awaitsMyResponse: true)))
    #expect(sidebarItemMatches(sample(), query: "", selection: selection,
                               facts: SidebarItemFacts(hasAuthorUpdate: true)))
    #expect(!sidebarItemMatches(sample(), query: "", selection: selection,
                                facts: SidebarItemFacts(ciFailing: true)))
}

@Test func resourcesCombineAsOr() {
    let selection = SidebarFilterSelection(resources: [.worktree, .web])
    #expect(sidebarItemMatches(sample(), query: "", selection: selection,
                               facts: SidebarItemFacts(hasWorktree: true)))
    #expect(sidebarItemMatches(sample(), query: "", selection: selection,
                               facts: SidebarItemFacts(hasWebView: true)))
    #expect(!sidebarItemMatches(sample(), query: "", selection: selection,
                                facts: SidebarItemFacts(hasSession: true)))
}

@Test func signalsAndResourcesCombineAsAnd() {
    let selection = SidebarFilterSelection(signals: .agent, resources: .session)
    #expect(sidebarItemMatches(sample(), query: "", selection: selection,
                               facts: SidebarItemFacts(awaitsMyResponse: true, hasSession: true)))
    // Signal alone is not enough once a resource is also selected.
    #expect(!sidebarItemMatches(sample(), query: "", selection: selection,
                                facts: SidebarItemFacts(awaitsMyResponse: true)))
    // Resource alone is not enough either.
    #expect(!sidebarItemMatches(sample(), query: "", selection: selection,
                                facts: SidebarItemFacts(hasSession: true)))
}

@Test func everySignalReadsItsOwnFact() {
    let cases: [(SignalFilter, SidebarItemFacts)] = [
        (.agent, SidebarItemFacts(awaitsMyResponse: true)),
        (.needsInput, SidebarItemFacts(needsInput: true)),
        (.working, SidebarItemFacts(isWorking: true)),
        (.author, SidebarItemFacts(hasAuthorUpdate: true)),
        (.ciFailing, SidebarItemFacts(ciFailing: true)),
        (.behind, SidebarItemFacts(isBehind: true)),
        (.dirty, SidebarItemFacts(hasLocalChanges: true)),
    ]
    for (signal, facts) in cases {
        #expect(facts.has(signal), "\(signal.displayName) should read its own fact")
        #expect(!noFacts.has(signal), "\(signal.displayName) should be off with no facts")
        for (other, _) in cases where other != signal {
            #expect(!facts.has(other), "\(signal.displayName) must not satisfy \(other.displayName)")
        }
    }
}

@Test func everyResourceReadsItsOwnFact() {
    let cases: [(ResourceFilter, SidebarItemFacts)] = [
        (.worktree, SidebarItemFacts(hasWorktree: true)),
        (.session, SidebarItemFacts(hasSession: true)),
        (.web, SidebarItemFacts(hasWebView: true)),
    ]
    for (resource, facts) in cases {
        #expect(facts.has(resource))
        #expect(!noFacts.has(resource))
        for (other, _) in cases where other != resource {
            #expect(!facts.has(other))
        }
    }
}

@Test func filterAndQueryBothApply() {
    let selection = SidebarFilterSelection(signals: .agent)
    // Query matches but the signal is off → excluded.
    #expect(!sidebarItemMatches(sample(), query: "centrifuge", selection: selection, facts: noFacts))
    // Signal is on but the query does not match → excluded.
    #expect(!sidebarItemMatches(sample(), query: "nope-zzz", selection: selection,
                                facts: SidebarItemFacts(awaitsMyResponse: true)))
}

@Test func toggleAddsThenRemoves() {
    var selection = SidebarFilterSelection()
    #expect(selection.isEmpty)
    selection.toggle(.agent)
    #expect(selection.signals.contains(.agent))
    #expect(!selection.isEmpty)
    selection.toggle(.worktree)
    #expect(selection.resources.contains(.worktree))
    selection.toggle(.agent)
    #expect(!selection.signals.contains(.agent))
    #expect(!selection.isEmpty)  // the resource is still selected
    selection.clear()
    #expect(selection.isEmpty)
}

@Test func orderedListsCoverEveryOption() {
    #expect(SignalFilter.ordered.count == 7)
    #expect(ResourceFilter.ordered.count == 3)
    #expect(SignalFilter.ordered.allSatisfy { !$0.displayName.isEmpty })
    #expect(ResourceFilter.ordered.allSatisfy { !$0.displayName.isEmpty })
    #expect(SignalFilter.ordered.allSatisfy { !$0.help.isEmpty })
    #expect(ResourceFilter.ordered.allSatisfy { !$0.help.isEmpty })
    #expect(ResourceFilter.ordered.allSatisfy { !$0.symbolName.isEmpty })
}
