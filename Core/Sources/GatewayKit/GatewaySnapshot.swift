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
        statusRank: Int = 0
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

    public init(
        signalFilters: [GatewayOption],
        resourceFilters: [GatewayOption],
        sorts: [GatewayOption],
        sort: String,
        hideParked: Bool
    ) {
        self.signalFilters = signalFilters
        self.resourceFilters = resourceFilters
        self.sorts = sorts
        self.sort = sort
        self.hideParked = hideParked
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
