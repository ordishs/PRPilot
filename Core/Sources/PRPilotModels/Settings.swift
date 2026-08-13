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
    /// Agent used by a work item that has made no explicit choice of its own.
    public var defaultAgent: AgentKind
    /// Path to the `pi` executable. Nil means resolve it from the shell, the same convention as
    /// `ghPath`, `gitPath` and `claudePath`. `LoginShellResolver` runs an interactive login
    /// shell, so a version-manager PATH set in `.zshrc` is found without help.
    public var piPath: String?
    public var piLaunchArgs: String
    public var piEnv: String
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
    /// First prompt of a pi review session. Separate from the Claude Code template because
    /// `/review` is a Claude Code slash command with no pi equivalent.
    public var piReviewPromptTemplate: String
    /// First prompt of a pi issue session.
    public var piIssuePromptTemplate: String
    /// Live `claude` child processes allowed at once. Each costs roughly 550 MB, so an
    /// uncapped one-per-item spread exhausts swap on a large work list.
    public var maxLiveAgentSessions: Int
    /// Live web views allowed at once. Each holds its own WebContent process.
    public var maxLiveWebViews: Int

    private enum LegacyKeys: String, CodingKey {
        case discoveryQueries
        case sidebarGrouping
    }

    /// Spelled out rather than synthesised, because `maxLiveAgentSessions` must keep the
    /// key it shipped under. The property was renamed when the session layer stopped being
    /// Claude-specific; the stored JSON was not, so a synthesised key would silently reset
    /// every existing user's cap to the default.
    enum CodingKeys: String, CodingKey {
        case managedRoot
        case reviewRequestQueries
        case myPRQueries
        case reviewRequestsEnabled
        case myPRsEnabled
        case pollIntervalSeconds
        case ghPath
        case gitPath
        case claudePath
        case claudeLaunchArgs
        case claudeEnv
        case defaultAgent
        case piPath
        case piLaunchArgs
        case piEnv
        case piReviewPromptTemplate
        case piIssuePromptTemplate
        case autoLoad
        case notificationsEnabled
        case diffMode
        case diffIgnoreWhitespace
        case sidebarSort
        case issueQueries
        case issuesEnabled
        case myWorkCollapsed
        case reviewsCollapsed
        case issuesCollapsed
        case appearance
        case reviewPromptTemplate
        case issuePromptTemplate
        case maxLiveAgentSessions = "maxLiveClaudeSessions"
        case maxLiveWebViews
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
        defaultAgent: AgentKind = .claudeCode,
        piPath: String? = nil,
        piLaunchArgs: String = "",
        piEnv: String = "",
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
        piReviewPromptTemplate: String = Settings.defaultPiReviewPromptTemplate,
        piIssuePromptTemplate: String = Settings.defaultPiIssuePromptTemplate,
        maxLiveAgentSessions: Int = 5,
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
        self.defaultAgent = defaultAgent
        self.piPath = piPath
        self.piLaunchArgs = piLaunchArgs
        self.piEnv = piEnv
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
        self.piReviewPromptTemplate = piReviewPromptTemplate
        self.piIssuePromptTemplate = piIssuePromptTemplate
        self.maxLiveAgentSessions = maxLiveAgentSessions
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
        defaultAgent = try c.decodeIfPresent(AgentKind.self, forKey: .defaultAgent) ?? .claudeCode
        piPath = try c.decodeIfPresent(String.self, forKey: .piPath)
        piLaunchArgs = try c.decodeIfPresent(String.self, forKey: .piLaunchArgs) ?? ""
        piEnv = try c.decodeIfPresent(String.self, forKey: .piEnv) ?? ""
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
        piReviewPromptTemplate = try c.decodeIfPresent(String.self, forKey: .piReviewPromptTemplate)
            ?? Settings.defaultPiReviewPromptTemplate
        piIssuePromptTemplate = try c.decodeIfPresent(String.self, forKey: .piIssuePromptTemplate)
            ?? Settings.defaultPiIssuePromptTemplate
        maxLiveAgentSessions = try c.decodeIfPresent(Int.self, forKey: .maxLiveAgentSessions) ?? 5
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

    /// pi has no `/review` or `/start-issue` command, so its templates are plain prose rather
    /// than a slash command. Kept deliberately short — the user owns and is expected to tune
    /// these, exactly as with the Claude Code templates.
    public static let defaultPiReviewPromptTemplate = "Review the pull request at {url}."
    public static let defaultPiIssuePromptTemplate = "Start work on issue {number}."

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
