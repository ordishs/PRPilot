public enum SidebarSort: String, Codable, Sendable, CaseIterable, Equatable {
    case recent
    case byStatus
    case byAuthor
    case byNumber

    public var displayName: String {
        switch self {
        case .recent: return "Recent"
        case .byStatus: return "By status"
        case .byAuthor: return "By author"
        case .byNumber: return "By number"
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
