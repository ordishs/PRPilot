import Foundation

public struct SidebarSections: Sendable, Equatable {
    public let myWork: [WorkItem]
    public let reviewRequests: [WorkItem]
    public let issues: [WorkItem]

    public init(myWork: [WorkItem], reviewRequests: [WorkItem], issues: [WorkItem]) {
        self.myWork = myWork
        self.reviewRequests = reviewRequests
        self.issues = issues
    }
}

/// - Parameter activity: when something last happened on an item. Recent sorts by it, so the
///   order matches the date each row shows. It defaults to the date the item arrived.
public func sidebarSections(
    items: [WorkItem],
    myLogin: String?,
    sort: SidebarSort,
    activity: (WorkItem) -> Date = { $0.addedAt }
) -> SidebarSections {
    var myWork: [WorkItem] = []
    var reviews: [WorkItem] = []
    var issues: [WorkItem] = []
    for item in items {
        switch item.category(myLogin: myLogin) {
        case .task, .myPR:
            myWork.append(item)
        case .reviewRequest:
            reviews.append(item)
        case .issue:
            issues.append(item)
        }
    }
    return SidebarSections(
        myWork: sortWorkItems(myWork, by: sort, activity: activity),
        reviewRequests: sortWorkItems(reviews, by: sort, activity: activity),
        issues: sortWorkItems(issues, by: sort, activity: activity)
    )
}

func sortWorkItems(
    _ items: [WorkItem],
    by sort: SidebarSort,
    activity: (WorkItem) -> Date
) -> [WorkItem] {
    switch sort {
    case .recent:
        return items.sorted { activity($0) > activity($1) }
    case .byStatus:
        return items.sorted {
            let a = statusRank($0.prState)
            let b = statusRank($1.prState)
            if a != b { return a < b }
            return activity($0) > activity($1)
        }
    case .byAuthor:
        return items.sorted {
            let a = $0.author ?? ""
            let b = $1.author ?? ""
            let cmp = a.localizedCaseInsensitiveCompare(b)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return activity($0) > activity($1)
        }
    case .byNumber:
        // Highest first, like Recent: the newest ticket leads. A task has no number and
        // sinks to the bottom.
        return items.sorted {
            switch ($0.displayNumber, $1.displayNumber) {
            case let (a?, b?) where a != b: return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return activity($0) > activity($1)
            }
        }
    }
}

public func statusRank(_ state: PRState?) -> Int {
    switch state {
    case .open, .none: return 0
    case .draft: return 1
    case .merged: return 2
    case .closed: return 3
    }
}
