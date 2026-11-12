import Foundation

public struct TrailEntry: Codable, Sendable, Equatable {
    public var itemID: String
    public var visitedAt: Date

    public init(itemID: String, visitedAt: Date) {
        self.itemID = itemID
        self.visitedAt = visitedAt
    }
}

public struct RecentTrail: Codable, Sendable, Equatable {
    public static let capacity = 20

    public private(set) var entries: [TrailEntry]

    public init(entries: [TrailEntry] = []) {
        self.entries = entries
    }

    public mutating func visit(_ itemID: String, at date: Date) {
        entries.removeAll { $0.itemID == itemID }
        entries.insert(TrailEntry(itemID: itemID, visitedAt: date), at: 0)

        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
    }

    public mutating func prune(keeping liveIDs: Set<String>) {
        entries.removeAll { !liveIDs.contains($0.itemID) }
    }
}

public func trailAgeLabel(since date: Date, now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date))

    if seconds < 60 { return "now" }
    if seconds < 3_600 { return "\(seconds / 60)m" }
    if seconds < 86_400 { return "\(seconds / 3_600)h" }

    return "\(seconds / 86_400)d"
}

public func trailTabLabel(for item: WorkItem, defaultAgent: AgentKind) -> String {
    if resolvedPane(for: item) == .github { return "GitHub" }

    return item.effectiveAgent(default: defaultAgent).displayName
}
