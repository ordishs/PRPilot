import Testing
import Foundation
@testable import PRPilotModels

@Test func sidebarSortDisplayNames() {
    #expect(SidebarSort.recent.displayName == "Recent")
    #expect(SidebarSort.byStatus.displayName == "By status")
    #expect(SidebarSort.byAuthor.displayName == "By author")
}

@Test func sidebarSortMapsLegacyGrouping() {
    #expect(SidebarSort(legacyGrouping: "byStatus") == .byStatus)
    #expect(SidebarSort(legacyGrouping: "byAuthor") == .byAuthor)
    #expect(SidebarSort(legacyGrouping: "byCategory") == .recent)
    #expect(SidebarSort(legacyGrouping: "none") == .recent)
    #expect(SidebarSort(legacyGrouping: "byDate") == .recent)
    #expect(SidebarSort(legacyGrouping: "garbage") == .recent)
}

private func makeItem(
    id: String,
    repoKey: String = "github.com/acme/app",
    authorLogin: String? = nil,
    number: Int? = nil,
    state: PRState? = nil,
    addedAt: Date
) -> WorkItem {
    let prRef: PRRef? = number.map {
        PRRef(owner: "acme", repo: "app", number: $0,
              url: URL(string: "https://github.com/acme/app/pull/\($0)")!,
              authorLogin: authorLogin ?? "someone")
    }
    return WorkItem(
        id: id, title: id, repoKey: repoKey, baseBranch: "main",
        headBranch: number == nil ? "feature/\(id)" : nil,
        prRef: prRef, prState: state, origin: .added, addedAt: addedAt
    )
}

@Test func sidebarSectionsPartitionsByCategory() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let items = [
        makeItem(id: "task1", addedAt: base),
        makeItem(id: "mine", authorLogin: "me", number: 10, state: .open, addedAt: base),
        makeItem(id: "review", authorLogin: "other", number: 20, state: .open, addedAt: base),
    ]
    let s = sidebarSections(items: items, myLogin: "me", sort: .recent)
    #expect(s.myWork.map(\.id).sorted() == ["mine", "task1"])
    #expect(s.reviewRequests.map(\.id) == ["review"])
}

@Test func sidebarSectionsRecentSortsNewestFirst() {
    let old = Date(timeIntervalSince1970: 1_700_000_000)
    let new = Date(timeIntervalSince1970: 1_700_001_000)
    let items = [
        makeItem(id: "old", addedAt: old),
        makeItem(id: "new", addedAt: new),
    ]
    let s = sidebarSections(items: items, myLogin: "me", sort: .recent)
    #expect(s.myWork.map(\.id) == ["new", "old"])
}

@Test func sidebarSectionsByStatusOrdersOpenDraftMergedClosed() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let items = [
        makeItem(id: "closed", authorLogin: "me", number: 1, state: .closed, addedAt: base),
        makeItem(id: "open", authorLogin: "me", number: 2, state: .open, addedAt: base),
        makeItem(id: "merged", authorLogin: "me", number: 3, state: .merged, addedAt: base),
        makeItem(id: "draft", authorLogin: "me", number: 4, state: .draft, addedAt: base),
        makeItem(id: "task", addedAt: base),
    ]
    let s = sidebarSections(items: items, myLogin: "me", sort: .byStatus)
    let ids = s.myWork.map(\.id)
    #expect(ids.prefix(2).sorted() == ["open", "task"])
    #expect(ids[2] == "draft")
    #expect(ids[3] == "merged")
    #expect(ids[4] == "closed")
}

@Test func sidebarSectionsByAuthorIsCaseInsensitiveAlphabetical() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let items = [
        makeItem(id: "z", authorLogin: "Zoe", number: 1, state: .open, addedAt: base),
        makeItem(id: "a", authorLogin: "alice", number: 2, state: .open, addedAt: base),
    ]
    let s = sidebarSections(items: items, myLogin: "nobody", sort: .byAuthor)
    #expect(s.reviewRequests.map(\.id) == ["a", "z"])
}

@Test func sidebarSectionsEmptyWhenNoItems() {
    let s = sidebarSections(items: [], myLogin: "me", sort: .recent)
    #expect(s.myWork.isEmpty)
    #expect(s.reviewRequests.isEmpty)
}

@Test func issuesGoIntoIssuesBucket() {
    let issue = WorkItem(
        title: "bug", repoKey: "github.com/o/r", baseBranch: "main",
        headBranch: "issue-1-bug",
        issueRef: IssueRef(owner: "o", repo: "r", number: 1,
            url: URL(string: "https://github.com/o/r/issues/1")!, authorLogin: "alice"),
        prState: .open, origin: .discovered, addedAt: Date()
    )
    let task = WorkItem(
        title: "feat/x", repoKey: "github.com/o/r", baseBranch: "main",
        headBranch: "feat/x", origin: .added, addedAt: Date()
    )
    let sections = sidebarSections(items: [issue, task], myLogin: "me", sort: .recent)
    #expect(sections.issues.map(\.id) == [issue.id])
    #expect(sections.myWork.map(\.id) == [task.id])
    #expect(sections.reviewRequests.isEmpty)
}
