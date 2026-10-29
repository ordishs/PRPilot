import Foundation

/// The three sidebar sections of the Mac, in the order it draws them.
public enum GatewaySectionKind: String, Codable, Sendable, Hashable, CaseIterable {
    case myWork
    case reviewRequests
    case issues
}

public enum GatewayItemKind: String, Codable, Sendable, Hashable {
    case pr
    case issue
    case task
}

public enum GatewayBadgeTone: String, Codable, Sendable, Hashable {
    case green
    case orange
    case red
    case blue
    case grey
}

public struct GatewayBadge: Codable, Sendable, Hashable {
    public var text: String
    public var tone: GatewayBadgeTone
    /// The same sentence the Mac badge shows on hover. A five-letter chip cannot say which
    /// actor it is talking about, and the phone has no hover to fall back on.
    public var help: String

    public init(text: String, tone: GatewayBadgeTone, help: String) {
        self.text = text
        self.tone = tone
        self.help = help
    }
}

public struct GatewayAgent: Codable, Sendable, Hashable {
    public var kind: String
    public var status: String
    public var verdict: String?
    public var elapsedSeconds: Int?
    public var usedPercent: Int?

    public init(
        kind: String,
        status: String,
        verdict: String? = nil,
        elapsedSeconds: Int? = nil,
        usedPercent: Int? = nil
    ) {
        self.kind = kind
        self.status = status
        self.verdict = verdict
        self.elapsedSeconds = elapsedSeconds
        self.usedPercent = usedPercent
    }
}

public struct GatewayRebase: Codable, Sendable, Hashable {
    public var state: String
    public var files: [String]
    public var message: String?

    public init(state: String, files: [String] = [], message: String? = nil) {
        self.state = state
        self.files = files
        self.message = message
    }
}

public struct GatewayDetail: Codable, Sendable, Hashable {
    public var pane: String
    public var paneState: String
    public var paneMessage: String?
    public var runLabel: String?
    public var rebase: GatewayRebase?
    public var agentChoice: String?
    public var agentKey: String
    /// Agents that hold a session for the item, in tab order. Each is a tab beside GitHub.
    public var agentTabs: [String]
    public var canHandOver: Bool
    public var sessionID: String?
    public var canClearAgentBadge: Bool
    public var canClearAuthorBadge: Bool
    public var canClearLimit: Bool

    public init(
        pane: String = "github",
        paneState: String = "idle",
        paneMessage: String? = nil,
        runLabel: String? = nil,
        rebase: GatewayRebase? = nil,
        agentChoice: String? = nil,
        agentKey: String = "claudeCode",
        agentTabs: [String] = [],
        canHandOver: Bool = false,
        sessionID: String? = nil,
        canClearAgentBadge: Bool = false,
        canClearAuthorBadge: Bool = false,
        canClearLimit: Bool = false
    ) {
        self.pane = pane
        self.paneState = paneState
        self.paneMessage = paneMessage
        self.runLabel = runLabel
        self.rebase = rebase
        self.agentChoice = agentChoice
        self.agentKey = agentKey
        self.agentTabs = agentTabs
        self.canHandOver = canHandOver
        self.sessionID = sessionID
        self.canClearAgentBadge = canClearAgentBadge
        self.canClearAuthorBadge = canClearAuthorBadge
        self.canClearLimit = canClearLimit
    }

    public static let empty = GatewayDetail()
}

public struct GatewayItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: GatewayItemKind
    public var owner: String?
    public var repo: String?
    public var number: Int?
    public var url: String?
    public var title: String
    public var author: String?
    public var headBranch: String?
    public var baseBranch: String
    public var attentionReason: String?
    public var agent: GatewayAgent?
    public var badges: [GatewayBadge]
    public var issueStatus: String?
    public var label: String?
    public var isDisabled: Bool
    public var ahead: Int
    public var behind: Int
    public var localChanges: Int
    public var lastActivityAt: Date?
    public var primaryCommand: GatewayCommand?
    /// The `SignalFilter` keys this item carries. The client filters and counts on these,
    /// so a pill on the phone matches the same pill on the Mac.
    public var signals: [String]
    /// The `ResourceFilter` keys this item holds.
    public var resources: [String]
    /// You approved it and nothing has happened since — the Mac's "Hide parked" test.
    public var isParked: Bool
    /// Sort keys for the Mac's orders: Recent reads `addedAt`, By status reads `statusRank`.
    public var addedAt: Date
    public var statusRank: Int
    public var detail: GatewayDetail

    public init(
        id: String,
        kind: GatewayItemKind,
        owner: String?,
        repo: String?,
        number: Int?,
        url: String?,
        title: String,
        author: String?,
        headBranch: String?,
        baseBranch: String,
        attentionReason: String?,
        agent: GatewayAgent?,
        badges: [GatewayBadge],
        issueStatus: String?,
        label: String?,
        isDisabled: Bool,
        ahead: Int,
        behind: Int,
        localChanges: Int,
        lastActivityAt: Date?,
        primaryCommand: GatewayCommand?,
        signals: [String] = [],
        resources: [String] = [],
        isParked: Bool = false,
        addedAt: Date,
        statusRank: Int = 0,
        detail: GatewayDetail = .empty
    ) {
        self.id = id
        self.kind = kind
        self.owner = owner
        self.repo = repo
        self.number = number
        self.url = url
        self.title = title
        self.author = author
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.attentionReason = attentionReason
        self.agent = agent
        self.badges = badges
        self.issueStatus = issueStatus
        self.label = label
        self.isDisabled = isDisabled
        self.ahead = ahead
        self.behind = behind
        self.localChanges = localChanges
        self.lastActivityAt = lastActivityAt
        self.primaryCommand = primaryCommand
        self.signals = signals
        self.resources = resources
        self.isParked = isParked
        self.addedAt = addedAt
        self.statusRank = statusRank
        self.detail = detail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(GatewayItemKind.self, forKey: .kind)
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        number = try c.decodeIfPresent(Int.self, forKey: .number)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        headBranch = try c.decodeIfPresent(String.self, forKey: .headBranch)
        baseBranch = try c.decode(String.self, forKey: .baseBranch)
        attentionReason = try c.decodeIfPresent(String.self, forKey: .attentionReason)
        agent = try c.decodeIfPresent(GatewayAgent.self, forKey: .agent)
        badges = try c.decode([GatewayBadge].self, forKey: .badges)
        issueStatus = try c.decodeIfPresent(String.self, forKey: .issueStatus)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        isDisabled = try c.decode(Bool.self, forKey: .isDisabled)
        ahead = try c.decode(Int.self, forKey: .ahead)
        behind = try c.decode(Int.self, forKey: .behind)
        localChanges = try c.decode(Int.self, forKey: .localChanges)
        lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        primaryCommand = try c.decodeIfPresent(GatewayCommand.self, forKey: .primaryCommand)
        signals = try c.decode([String].self, forKey: .signals)
        resources = try c.decode([String].self, forKey: .resources)
        isParked = try c.decode(Bool.self, forKey: .isParked)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        statusRank = try c.decode(Int.self, forKey: .statusRank)
        detail = try c.decodeIfPresent(GatewayDetail.self, forKey: .detail) ?? .empty
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, owner, repo, number, url, title, author, headBranch, baseBranch
        case attentionReason, agent, badges, issueStatus, label, isDisabled, ahead, behind
        case localChanges, lastActivityAt, primaryCommand, signals, resources, isParked
        case addedAt, statusRank, detail
    }
}

public struct GatewaySection: Codable, Sendable, Equatable {
    public var kind: GatewaySectionKind
    public var items: [GatewayItem]

    public init(kind: GatewaySectionKind, items: [GatewayItem]) {
        self.kind = kind
        self.items = items
    }
}

/// One choice the client offers: a filter pill or a sort order. The label and help come
/// from the same source the Mac draws, so the two never word a choice differently.
public struct GatewayOption: Codable, Sendable, Hashable {
    public var key: String
    public var label: String
    public var help: String

    public init(key: String, label: String, help: String) {
        self.key = key
        self.label = label
        self.help = help
    }
}

/// What the Mac sidebar shows by default. The phone starts from it and keeps its own
/// changes, so a tap on the phone never rearranges the Mac.
public struct GatewayListing: Codable, Sendable, Equatable {
    public var signalFilters: [GatewayOption]
    public var resourceFilters: [GatewayOption]
    public var sorts: [GatewayOption]
    public var sort: String
    public var hideParked: Bool
    public var agents: [GatewayOption]
    public var issueStatuses: [GatewayOption]
    public var defaultAgent: String
    public var failoverAgent: String

    public init(
        signalFilters: [GatewayOption],
        resourceFilters: [GatewayOption],
        sorts: [GatewayOption],
        sort: String,
        hideParked: Bool,
        agents: [GatewayOption] = [],
        issueStatuses: [GatewayOption] = [],
        defaultAgent: String = "claudeCode",
        failoverAgent: String = "claudeCode"
    ) {
        self.signalFilters = signalFilters
        self.resourceFilters = resourceFilters
        self.sorts = sorts
        self.sort = sort
        self.hideParked = hideParked
        self.agents = agents
        self.issueStatuses = issueStatuses
        self.defaultAgent = defaultAgent
        self.failoverAgent = failoverAgent
    }

    public static let empty = GatewayListing(
        signalFilters: [], resourceFilters: [], sorts: [], sort: "recent", hideParked: false
    )
}

public struct GatewaySnapshot: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var gatewayVersion: Int
    public var appVersion: String
    public var login: String?
    public var sections: [GatewaySection]
    public var listing: GatewayListing
    public var warnings: [String]

    public init(
        generatedAt: Date,
        gatewayVersion: Int = GatewayVersion.current,
        appVersion: String,
        login: String?,
        sections: [GatewaySection],
        listing: GatewayListing = .empty,
        warnings: [String]
    ) {
        self.generatedAt = generatedAt
        self.gatewayVersion = gatewayVersion
        self.appVersion = appVersion
        self.login = login
        self.sections = sections
        self.listing = listing
        self.warnings = warnings
    }
}
