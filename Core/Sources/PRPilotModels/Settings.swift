import Foundation

public struct Settings: Codable, Sendable, Equatable {
    public var managedRoot: String
    public var discoveryQueries: [String]
    public var pollIntervalSeconds: Int
    public var ghPath: String?
    public var gitPath: String?
    public var claudePath: String?
    public var claudeLaunchArgs: String
    public var claudeEnv: String
    public var autoLoad: Bool
    public var notificationsEnabled: Bool
    public var diffMode: DiffMode
    public var diffIgnoreWhitespace: Bool
    public var sidebarGrouping: SidebarGrouping

    public init(
        managedRoot: String,
        discoveryQueries: [String],
        pollIntervalSeconds: Int,
        ghPath: String? = nil,
        gitPath: String? = nil,
        claudePath: String? = nil,
        claudeLaunchArgs: String = "",
        claudeEnv: String = "",
        autoLoad: Bool = false,
        notificationsEnabled: Bool,
        diffMode: DiffMode,
        diffIgnoreWhitespace: Bool,
        sidebarGrouping: SidebarGrouping = .none
    ) {
        self.managedRoot = managedRoot
        self.discoveryQueries = discoveryQueries
        self.pollIntervalSeconds = pollIntervalSeconds
        self.ghPath = ghPath
        self.gitPath = gitPath
        self.claudePath = claudePath
        self.claudeLaunchArgs = claudeLaunchArgs
        self.claudeEnv = claudeEnv
        self.autoLoad = autoLoad
        self.notificationsEnabled = notificationsEnabled
        self.diffMode = diffMode
        self.diffIgnoreWhitespace = diffIgnoreWhitespace
        self.sidebarGrouping = sidebarGrouping
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        managedRoot = try c.decode(String.self, forKey: .managedRoot)
        discoveryQueries = try c.decode([String].self, forKey: .discoveryQueries)
        pollIntervalSeconds = try c.decode(Int.self, forKey: .pollIntervalSeconds)
        ghPath = try c.decodeIfPresent(String.self, forKey: .ghPath)
        gitPath = try c.decodeIfPresent(String.self, forKey: .gitPath)
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
        if let argsString = try? c.decodeIfPresent(String.self, forKey: .claudeLaunchArgs) {
            claudeLaunchArgs = argsString
        } else {
            let argsArray = try c.decodeIfPresent([String].self, forKey: .claudeLaunchArgs) ?? []
            claudeLaunchArgs = argsArray.joined(separator: " ")
        }
        if let envString = try? c.decodeIfPresent(String.self, forKey: .claudeEnv) {
            claudeEnv = envString
        } else {
            let envArray = try c.decodeIfPresent([String].self, forKey: .claudeEnv) ?? []
            claudeEnv = envArray.joined(separator: " ")
        }
        autoLoad = try c.decodeIfPresent(Bool.self, forKey: .autoLoad) ?? false
        notificationsEnabled = try c.decode(Bool.self, forKey: .notificationsEnabled)
        diffMode = try c.decode(DiffMode.self, forKey: .diffMode)
        diffIgnoreWhitespace = try c.decode(Bool.self, forKey: .diffIgnoreWhitespace)
        sidebarGrouping = try c.decodeIfPresent(SidebarGrouping.self, forKey: .sidebarGrouping) ?? .none
    }

    public static let `default` = Settings(
        managedRoot: Settings.defaultManagedRoot(),
        discoveryQueries: ["review-requested:@me is:open", "assignee:@me is:open"],
        pollIntervalSeconds: 120,
        notificationsEnabled: true,
        diffMode: .unified,
        diffIgnoreWhitespace: false,
        sidebarGrouping: .byDate
    )

    public static func defaultManagedRoot() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PRReview", isDirectory: true).path
    }
}
