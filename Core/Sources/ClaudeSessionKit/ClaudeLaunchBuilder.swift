import Foundation
import PRPilotModels

public struct ClaudeLaunchSpec: Sendable, Equatable {
    public let executable: String
    public let cwd: String
    public let arguments: [String]
    public let environment: String
    public let extraArgs: String

    public init(executable: String, cwd: String, arguments: [String], environment: String = "", extraArgs: String = "") {
        self.executable = executable
        self.cwd = cwd
        self.arguments = arguments
        self.environment = environment
        self.extraArgs = extraArgs
    }
}

public enum ClaudeLaunchBuilder {
    public static func build(
        settings: Settings,
        review: WorkItem,
        worktreePath: String,
        resolvedClaudePath: String,
        sessionID: String,
        resume: Bool
    ) -> ClaudeLaunchSpec {
        var args: [String] = []
        args.append(contentsOf: review.claudeFlags ?? [])
        args.append("--name")
        args.append(sessionName(for: review))
        if resume {
            args.append("--resume")
            args.append(sessionID)
        } else {
            args.append("--session-id")
            args.append(sessionID)
            if review.prRef != nil, let url = review.url {
                args.append("/review \(url.absoluteString)")
            } else if let issueNumber = review.issueNumber {
                args.append("/start-issue \(issueNumber)")
            }
        }
        return ClaudeLaunchSpec(
            executable: resolvedClaudePath,
            cwd: worktreePath,
            arguments: args,
            environment: settings.claudeEnv,
            extraArgs: settings.claudeLaunchArgs
        )
    }

    /// Display name for the Claude session (shown in Claude Desktop "Recents").
    /// PR-backed items use "#<number> <title>"; tasks use their title (the branch).
    static func sessionName(for review: WorkItem) -> String {
        if let number = review.displayNumber {
            return "#\(number) \(review.title)"
        }
        return review.title
    }
}
