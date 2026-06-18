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

@Test func emptyQueryAllFilterMatches() {
    #expect(sidebarItemMatches(sample(), query: "", filter: .all, isWorking: false, isAwaiting: false))
}

@Test func queryMatchesEachField() {
    let i = sample()
    #expect(sidebarItemMatches(i, query: "centrifuge", filter: .all, isWorking: false, isAwaiting: false))   // title
    #expect(sidebarItemMatches(i, query: "teranode", filter: .all, isWorking: false, isAwaiting: false))     // repo
    #expect(sidebarItemMatches(i, query: "icellan", filter: .all, isWorking: false, isAwaiting: false))      // author
    #expect(sidebarItemMatches(i, query: "fix/cent", filter: .all, isWorking: false, isAwaiting: false))     // branch
    #expect(sidebarItemMatches(i, query: "#944", filter: .all, isWorking: false, isAwaiting: false))         // number
    #expect(sidebarItemMatches(i, query: "TERANODE", filter: .all, isWorking: false, isAwaiting: false))     // case-insensitive
}

@Test func nonMatchingQueryFails() {
    #expect(!sidebarItemMatches(sample(), query: "nope-zzz", filter: .all, isWorking: false, isAwaiting: false))
}

@Test func activeFilterNeedsWorkingOrAwaiting() {
    let i = sample()
    #expect(sidebarItemMatches(i, query: "", filter: .active, isWorking: true, isAwaiting: false))
    #expect(sidebarItemMatches(i, query: "", filter: .active, isWorking: false, isAwaiting: true))
    #expect(!sidebarItemMatches(i, query: "", filter: .active, isWorking: false, isAwaiting: false))
}

@Test func awaitingFilterNeedsAwaiting() {
    let i = sample()
    #expect(sidebarItemMatches(i, query: "", filter: .awaiting, isWorking: false, isAwaiting: true))
    #expect(!sidebarItemMatches(i, query: "", filter: .awaiting, isWorking: true, isAwaiting: false))
}

@Test func filterAndQueryBothApply() {
    let i = sample()
    // Query matches but filter excludes (awaiting required, not awaiting) → false.
    #expect(!sidebarItemMatches(i, query: "centrifuge", filter: .awaiting, isWorking: true, isAwaiting: false))
}
