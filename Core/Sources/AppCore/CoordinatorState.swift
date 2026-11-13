import Foundation
import PRPilotModels

/// What the coordinator agent reads first. One entry for each open ticket, with the same
/// signals the board and the next-up list use, so the agent and the app never disagree.
public struct CoordinatorState: Codable, Sendable, Equatable {
    public struct NextUp: Codable, Sendable, Equatable {
        public var kase: String
        public var reason: String
        public var step: String

        enum CodingKeys: String, CodingKey {
            case kase = "case"
            case reason, step
        }
    }

    public struct Ticket: Codable, Sendable, Equatable {
        public var id: String
        public var number: Int?
        public var title: String
        public var url: String?
        public var repo: String
        public var kind: String
        public var author: String?
        public var headBranch: String?
        public var baseBranch: String
        public var boardColumn: String
        public var nextUp: NextUp?
        public var ci: String?
        public var failedChecks: [String]?
        public var mergeState: String?
        public var reviewReadiness: String?
        public var readyToMerge: Bool?
        public var unresolvedThreads: Int?
        public var threadsAwaitingMe: Int?
        public var changeRequestsCurrent: Int?
        public var agentStatus: String
        public var lastVerdict: String?
        public var worktreePath: String?
        public var disabled: Bool
    }

    public var generatedAt: Date
    public var tickets: [Ticket]
    public var autoLog: [AutoLogEntry]

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        return try encoder.encode(self)
    }
}
