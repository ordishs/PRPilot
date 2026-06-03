public enum SidebarSort: String, Codable, Sendable, CaseIterable, Equatable {
    case recent
    case byStatus
    case byAuthor

    public var displayName: String {
        switch self {
        case .recent: return "Recent"
        case .byStatus: return "By status"
        case .byAuthor: return "By author"
        }
    }

    public init(legacyGrouping: String) {
        switch legacyGrouping {
        case "byStatus": self = .byStatus
        case "byAuthor": self = .byAuthor
        default: self = .recent
        }
    }
}
