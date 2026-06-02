import Foundation

public enum SidebarGrouping: String, Codable, Sendable, CaseIterable, Equatable {
    case byCategory
    case none
    case byDate
    case byAuthor
    case byStatus

    public var displayName: String {
        switch self {
        case .byCategory: return "My Work / Review Requests"
        case .none: return "No grouping"
        case .byDate: return "By date"
        case .byAuthor: return "By author"
        case .byStatus: return "By status"
        }
    }
}
