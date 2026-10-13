import Foundation

/// Every command the phone can send.
///
/// There is deliberately no case for `push`, `rebase`, `continueRebase` or `abortRebase`.
/// A request cannot reach a git action, because no case encodes one.
public enum GatewayCommand: Codable, Sendable, Hashable {
    case refreshAll
    case refreshItem(id: String)
    case markAuthorUpdateSeen(id: String)
    case clearWaiting(id: String)
    case setPane(id: String, pane: String)
    case startSession(id: String, forceFresh: Bool)
    case clearSession(id: String)
    case clearAgentLimit(id: String)
    case handOver(id: String)
    case addPR(url: String)
    case addIssue(url: String)
    case setIssueStatus(id: String, status: String?)
    case setLabel(id: String, label: String?)
    case setDisabled(id: String, disabled: Bool)
    case setAgent(id: String, agent: String?)
    case removeItem(id: String)
    /// Type a line into the running agent, as if at the keyboard.
    case sendPrompt(id: String, text: String)

    private enum CodingKeys: String, CodingKey {
        case type, id, url, pane, status, label, disabled, forceFresh, text, agent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)

        func id() throws -> String { try c.decode(String.self, forKey: .id) }

        switch type {
        case "refreshAll":
            self = .refreshAll
        case "refreshItem":
            self = .refreshItem(id: try id())
        case "markAuthorUpdateSeen":
            self = .markAuthorUpdateSeen(id: try id())
        case "clearWaiting":
            self = .clearWaiting(id: try id())
        case "setPane":
            self = .setPane(id: try id(), pane: try c.decode(String.self, forKey: .pane))
        case "startSession":
            self = .startSession(
                id: try id(),
                forceFresh: try c.decodeIfPresent(Bool.self, forKey: .forceFresh) ?? false
            )
        case "clearSession":
            self = .clearSession(id: try id())
        case "clearAgentLimit":
            self = .clearAgentLimit(id: try id())
        case "handOver":
            self = .handOver(id: try id())
        case "addPR":
            self = .addPR(url: try c.decode(String.self, forKey: .url))
        case "addIssue":
            self = .addIssue(url: try c.decode(String.self, forKey: .url))
        case "setIssueStatus":
            self = .setIssueStatus(
                id: try id(),
                status: try c.decodeIfPresent(String.self, forKey: .status)
            )
        case "setLabel":
            self = .setLabel(
                id: try id(),
                label: try c.decodeIfPresent(String.self, forKey: .label)
            )
        case "setDisabled":
            self = .setDisabled(
                id: try id(),
                disabled: try c.decode(Bool.self, forKey: .disabled)
            )
        case "setAgent":
            self = .setAgent(
                id: try id(),
                agent: try c.decodeIfPresent(String.self, forKey: .agent)
            )
        case "removeItem":
            self = .removeItem(id: try id())
        case "sendPrompt":
            self = .sendPrompt(id: try id(), text: try c.decode(String.self, forKey: .text))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "unknown command type \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .refreshAll:
            try c.encode("refreshAll", forKey: .type)
        case .refreshItem(let id):
            try c.encode("refreshItem", forKey: .type)
            try c.encode(id, forKey: .id)
        case .markAuthorUpdateSeen(let id):
            try c.encode("markAuthorUpdateSeen", forKey: .type)
            try c.encode(id, forKey: .id)
        case .clearWaiting(let id):
            try c.encode("clearWaiting", forKey: .type)
            try c.encode(id, forKey: .id)
        case .setPane(let id, let pane):
            try c.encode("setPane", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(pane, forKey: .pane)
        case .startSession(let id, let forceFresh):
            try c.encode("startSession", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(forceFresh, forKey: .forceFresh)
        case .clearSession(let id):
            try c.encode("clearSession", forKey: .type)
            try c.encode(id, forKey: .id)
        case .clearAgentLimit(let id):
            try c.encode("clearAgentLimit", forKey: .type)
            try c.encode(id, forKey: .id)
        case .handOver(let id):
            try c.encode("handOver", forKey: .type)
            try c.encode(id, forKey: .id)
        case .addPR(let url):
            try c.encode("addPR", forKey: .type)
            try c.encode(url, forKey: .url)
        case .addIssue(let url):
            try c.encode("addIssue", forKey: .type)
            try c.encode(url, forKey: .url)
        case .setIssueStatus(let id, let status):
            try c.encode("setIssueStatus", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(status, forKey: .status)
        case .setLabel(let id, let label):
            try c.encode("setLabel", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(label, forKey: .label)
        case .setDisabled(let id, let disabled):
            try c.encode("setDisabled", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(disabled, forKey: .disabled)
        case .setAgent(let id, let agent):
            try c.encode("setAgent", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(agent, forKey: .agent)
        case .removeItem(let id):
            try c.encode("removeItem", forKey: .type)
            try c.encode(id, forKey: .id)
        case .sendPrompt(let id, let text):
            try c.encode("sendPrompt", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
        }
    }
}

public struct GatewayCommandEnvelope: Codable, Sendable, Equatable {
    public var commandID: String
    public var command: GatewayCommand

    public init(commandID: String, command: GatewayCommand) {
        self.commandID = commandID
        self.command = command
    }
}

public struct GatewayCommandResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case accepted
        case rejected
    }

    public var status: Status
    public var message: String?
    public var snapshot: GatewaySnapshot

    public init(status: Status, message: String? = nil, snapshot: GatewaySnapshot) {
        self.status = status
        self.message = message
        self.snapshot = snapshot
    }
}
