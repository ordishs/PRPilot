import Foundation

public enum ClaudeStatus: Sendable, Equatable {
    case starting
    case working
    case awaitingInput(since: Date, lastVerdictSnippet: String?)
    case idle(since: Date, lastVerdictSnippet: String?)
    case ready(exitCode: Int32)
    case failed(reason: String)
}
