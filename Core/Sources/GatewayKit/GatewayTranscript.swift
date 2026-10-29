import Foundation

/// One turn of the conversation, as the agent's own transcript recorded it.
public struct GatewayTurn: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable, Hashable {
        case user
        case assistant
    }

    public var role: Role
    public var at: Date
    public var text: String

    public init(role: Role, at: Date, text: String) {
        self.role = role
        self.at = at
        self.text = text
    }
}

/// The recent conversation for one work item.
///
/// Read from the transcript on disk rather than from the terminal. The terminal shows only
/// the visible screen, so anything the agent wrote before the last scroll is gone; the
/// transcript has the lot and survives the session being restarted.
public struct GatewayTranscript: Codable, Sendable, Hashable {
    public var itemID: String
    /// The agent that wrote it, for display.
    public var agent: String
    /// Oldest first, so the client can append without reversing.
    public var turns: [GatewayTurn]
    /// True when older turns were dropped to fit the limit.
    public var truncated: Bool
    /// False when no transcript could be found — no session has run yet, or the agent
    /// writes none. The client says so rather than showing an empty conversation.
    public var available: Bool
    /// Why it is unavailable, when it is.
    public var note: String?

    public init(
        itemID: String,
        agent: String,
        turns: [GatewayTurn],
        truncated: Bool,
        available: Bool,
        note: String? = nil
    ) {
        self.itemID = itemID
        self.agent = agent
        self.turns = turns
        self.truncated = truncated
        self.available = available
        self.note = note
    }

    public static func unavailable(itemID: String, note: String) -> GatewayTranscript {
        GatewayTranscript(
            itemID: itemID,
            agent: "",
            turns: [],
            truncated: false,
            available: false,
            note: note
        )
    }
}

/// The text of a GitHub issue or PR, for a client that cannot embed github.com.
public struct GatewayThread: Codable, Sendable, Hashable {
    public struct Entry: Codable, Sendable, Hashable {
        public var author: String
        public var at: String?
        public var body: String
        public var verdict: String?

        public init(author: String, at: String?, body: String, verdict: String? = nil) {
            self.author = author
            self.at = at
            self.body = body
            self.verdict = verdict
        }
    }

    public var itemID: String
    /// False for a task with no GitHub page, or when `gh` failed. `note` says which.
    public var available: Bool
    public var note: String?
    public var title: String
    public var state: String
    public var author: String
    public var createdAt: String?
    public var body: String
    public var labels: [String]
    public var entries: [Entry]

    public init(
        itemID: String,
        available: Bool,
        note: String? = nil,
        title: String = "",
        state: String = "",
        author: String = "",
        createdAt: String? = nil,
        body: String = "",
        labels: [String] = [],
        entries: [Entry] = []
    ) {
        self.itemID = itemID
        self.available = available
        self.note = note
        self.title = title
        self.state = state
        self.author = author
        self.createdAt = createdAt
        self.body = body
        self.labels = labels
        self.entries = entries
    }

    public static func unavailable(itemID: String, note: String) -> GatewayThread {
        GatewayThread(itemID: itemID, available: false, note: note)
    }
}
