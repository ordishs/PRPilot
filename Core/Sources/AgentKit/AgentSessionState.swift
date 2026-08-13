public enum AgentSessionState: Sendable, Equatable {
    case starting
    case running
    case exited(code: Int32)
    case failedToLaunch(String)
}
