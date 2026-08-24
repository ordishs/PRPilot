import Foundation

public enum AgentStatus: Sendable, Equatable {
    case starting
    case working
    case awaitingInput(since: Date, lastVerdictSnippet: String?)
    case idle(since: Date, lastVerdictSnippet: String?)
    /// The agent ran out of allowance and stopped. Its process is alive and holds the
    /// conversation, but it can do no work until the user restores credit.
    case limited(since: Date, message: String)
    case ready(exitCode: Int32)
    case failed(reason: String)
}
