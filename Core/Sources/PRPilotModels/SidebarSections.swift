import Foundation

public struct SidebarSections: Sendable, Equatable {
    public let myWork: [WorkItem]
    public let reviewRequests: [WorkItem]

    public init(myWork: [WorkItem], reviewRequests: [WorkItem]) {
        self.myWork = myWork
        self.reviewRequests = reviewRequests
    }
}

public func sidebarSections(items: [WorkItem], myLogin: String?, sort: SidebarSort) -> SidebarSections {
    var myWork: [WorkItem] = []
    var reviews: [WorkItem] = []
    for item in items {
        switch item.category(myLogin: myLogin) {
        case .task, .myPR:
            myWork.append(item)
        case .reviewRequest:
            reviews.append(item)
        }
    }
    return SidebarSections(
        myWork: sortWorkItems(myWork, by: sort),
        reviewRequests: sortWorkItems(reviews, by: sort)
    )
}

func sortWorkItems(_ items: [WorkItem], by sort: SidebarSort) -> [WorkItem] {
    switch sort {
    case .recent:
        return items.sorted { $0.addedAt > $1.addedAt }
    case .byStatus:
        return items.sorted {
            let a = statusRank($0.prState)
            let b = statusRank($1.prState)
            if a != b { return a < b }
            return $0.addedAt > $1.addedAt
        }
    case .byAuthor:
        return items.sorted {
            let a = $0.author ?? ""
            let b = $1.author ?? ""
            let cmp = a.localizedCaseInsensitiveCompare(b)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return $0.addedAt > $1.addedAt
        }
    }
}

func statusRank(_ state: PRState?) -> Int {
    switch state {
    case .open, .none: return 0
    case .draft: return 1
    case .merged: return 2
    case .closed: return 3
    }
}
