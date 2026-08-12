import Foundation

public struct Settings: Codable, Sendable, Equatable {
    public var managedRoot: String
    public var reviewRequestQueries: [DiscoveryQuery]
    public var myPRQueries: [DiscoveryQuery]
    public var reviewRequestsEnabled: Bool
    public var myPRsEnabled: Bool
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
    public var sidebarSort: SidebarSort
    public var issueQueries: [DiscoveryQuery]
    public var issuesEnabled: Bool
    public var myWorkCollapsed: Bool
    public var reviewsCollapsed: Bool
    public var issuesCollapsed: Bool
    public var appearance: Appearance
    /// First prompt of a review session. The user owns it because what `/review` does is
    /// decided upstream and has changed under us before.
    public var reviewPromptTemplate: String
    /// First prompt of an issue session.
    public var issuePromptTemplate: String
    /// Live `claude` child processes allowed at once. Each costs roughly 550 MB, so an
    /// uncapped one-per-item spread exhausts swap on a large work list.
    public var maxLiveClaudeSessions: Int
    /// Live web views allowed at once. Each holds its own WebContent process.
    public var maxLiveWebViews: Int

    private enum LegacyKeys: String, CodingKey {
        case discoveryQueries
        case sidebarGrouping
    }

    public init(
        managedRoot: String,
        reviewRequestQueries: [DiscoveryQuery],
        myPRQueries: [DiscoveryQuery],
        reviewRequestsEnabled: Bool = true,
        myPRsEnabled: Bool = true,
        issueQueries: [DiscoveryQuery] = Settings.defaultIssueQueries,
        issuesEnabled: Bool = true,
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
        sidebarSort: SidebarSort = .recent,
        myWorkCollapsed: Bool = false,
        reviewsCollapsed: Bool = false,
        issuesCollapsed: Bool = false,
        appearance: Appearance = .system,
        reviewPromptTemplate: String = Settings.defaultReviewPromptTemplate,
        issuePromptTemplate: String = Settings.defaultIssuePromptTemplate,
        maxLiveClaudeSessions: Int = 5,
        maxLiveWebViews: Int = 8
    ) {
        self.managedRoot = managedRoot
        self.reviewRequestQueries = reviewRequestQueries
        self.myPRQueries = myPRQueries
        self.reviewRequestsEnabled = reviewRequestsEnabled
        self.myPRsEnabled = myPRsEnabled
        self.issueQueries = issueQueries
        self.issuesEnabled = issuesEnabled
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
        self.sidebarSort = sidebarSort
        self.myWorkCollapsed = myWorkCollapsed
        self.reviewsCollapsed = reviewsCollapsed
        self.issuesCollapsed = issuesCollapsed
        self.appearance = appearance
        self.reviewPromptTemplate = reviewPromptTemplate
        self.issuePromptTemplate = issuePromptTemplate
        self.maxLiveClaudeSessions = maxLiveClaudeSessions
        self.maxLiveWebViews = maxLiveWebViews
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        managedRoot = try c.decode(String.self, forKey: .managedRoot)
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
        if let sort = try c.decodeIfPresent(SidebarSort.self, forKey: .sidebarSort) {
            sidebarSort = sort
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
                  let legacyGrouping = (try? legacy.decodeIfPresent(String.self, forKey: .sidebarGrouping)) ?? nil {
            sidebarSort = SidebarSort(legacyGrouping: legacyGrouping)
        } else {
            sidebarSort = .recent
        }
        myWorkCollapsed = try c.decodeIfPresent(Bool.self, forKey: .myWorkCollapsed) ?? false
        reviewsCollapsed = try c.decodeIfPresent(Bool.self, forKey: .reviewsCollapsed) ?? false
        issuesCollapsed = try c.decodeIfPresent(Bool.self, forKey: .issuesCollapsed) ?? false
        issueQueries = try c.decodeIfPresent([DiscoveryQuery].self, forKey: .issueQueries) ?? Settings.defaultIssueQueries
        issuesEnabled = try c.decodeIfPresent(Bool.self, forKey: .issuesEnabled) ?? true
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
        reviewPromptTemplate = try c.decodeIfPresent(String.self, forKey: .reviewPromptTemplate)
            ?? Settings.defaultReviewPromptTemplate
        issuePromptTemplate = try c.decodeIfPresent(String.self, forKey: .issuePromptTemplate)
            ?? Settings.defaultIssuePromptTemplate
        maxLiveClaudeSessions = try c.decodeIfPresent(Int.self, forKey: .maxLiveClaudeSessions) ?? 5
        maxLiveWebViews = try c.decodeIfPresent(Int.self, forKey: .maxLiveWebViews) ?? 8

        if let rrq = try c.decodeIfPresent([DiscoveryQuery].self, forKey: .reviewRequestQueries) {
            reviewRequestQueries = rrq
            myPRQueries = try c.decodeIfPresent([DiscoveryQuery].self, forKey: .myPRQueries) ?? Settings.defaultMyPRQueries
            reviewRequestsEnabled = try c.decodeIfPresent(Bool.self, forKey: .reviewRequestsEnabled) ?? true
            myPRsEnabled = try c.decodeIfPresent(Bool.self, forKey: .myPRsEnabled) ?? true
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let old = try legacy.decodeIfPresent([String].self, forKey: .discoveryQueries) ?? []
            reviewRequestQueries = old.map { DiscoveryQuery(text: $0, allowUnscoped: false) }
            myPRQueries = Settings.defaultMyPRQueries
            reviewRequestsEnabled = true
            myPRsEnabled = true
        }
    }

    public static let defaultReviewPromptTemplate = "/review {url}"
    public static let defaultIssuePromptTemplate = "/start-issue {number}"

    public static let defaultReviewRequestQueries: [DiscoveryQuery] = [
        DiscoveryQuery(text: "review-requested:@me is:open"),
        DiscoveryQuery(text: "assignee:@me is:open"),
    ]
    public static let defaultMyPRQueries: [DiscoveryQuery] = [
        DiscoveryQuery(text: "author:@me is:open"),
    ]
    public static let defaultIssueQueries: [DiscoveryQuery] = [
        DiscoveryQuery(text: "assignee:@me is:open"),
    ]

    public static let `default` = Settings(
        managedRoot: Settings.defaultManagedRoot(),
        reviewRequestQueries: Settings.defaultReviewRequestQueries,
        myPRQueries: Settings.defaultMyPRQueries,
        pollIntervalSeconds: 120,
        notificationsEnabled: true,
        diffMode: .unified,
        diffIgnoreWhitespace: false,
        sidebarSort: .recent
    )

    public static func defaultManagedRoot() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PRPilot", isDirectory: true).path
    }
}
