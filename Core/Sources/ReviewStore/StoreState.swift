import PRPilotModels

struct StoreState: Codable, Sendable {
    var schemaVersion: Int
    var reviews: [Review]
    var registeredRepos: [RegisteredRepo]
    var settings: Settings
}
