import PRPilotModels

struct StoreState: Codable, Sendable {
    var schemaVersion: Int
    var reviews: [WorkItem]
    var registeredRepos: [RegisteredRepo]
    var settings: Settings
}
