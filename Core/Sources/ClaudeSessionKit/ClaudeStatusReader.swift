import Foundation

public struct ClaudeStatusReader: Sendable {
    public let idleThresholdSeconds: TimeInterval

    public init(idleThresholdSeconds: TimeInterval = 30) {
        self.idleThresholdSeconds = idleThresholdSeconds
    }

    public func status(
        processState: ClaudeSessionState,
        lastEventAt: Date?,
        lastVerdictSnippet: String?,
        now: Date = Date(),
        lastEventWasTurnCompletion: Bool = false
    ) -> ClaudeStatus {
        switch processState {
        case .failedToLaunch(let reason):
            return .failed(reason: reason)
        case .exited(let code):
            return .ready(exitCode: code)
        case .starting:
            return .starting
        case .running:
            guard let lastEventAt else {
                return .starting
            }
            if lastEventWasTurnCompletion {
                return .awaitingInput(since: lastEventAt, lastVerdictSnippet: lastVerdictSnippet)
            }
            if now.timeIntervalSince(lastEventAt) < idleThresholdSeconds {
                return .working
            } else {
                return .idle(since: lastEventAt, lastVerdictSnippet: lastVerdictSnippet)
            }
        }
    }
}
