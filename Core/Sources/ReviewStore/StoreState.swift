import PRPilotModels

struct StoreState: Codable, Sendable {
    var schemaVersion: Int
    var reviews: [WorkItem]
    var registeredRepos: [RegisteredRepo]
    var settings: Settings
    var recentTrail: RecentTrail?
    var handledCauses: [String: HandledKind]?
    var autoLog: [AutoLogEntry]?
}
