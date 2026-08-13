import Foundation
import PRPilotModels

public struct AgentLaunchSpec: Sendable, Equatable {
    public let executable: String
    public let cwd: String
    public let arguments: [String]
    public let environment: String
    public let extraArgs: String
    /// Prepend the executable's own directory to PATH before exec. Needed by agents that are
    /// interpreted scripts — see `AgentBackend.prependsExecutableDirectoryToPath`.
    public let prependExecutableDirectoryToPath: Bool
    /// Which agent this spec launches, so a failure can name the right binary.
    public let kind: AgentKind

    /// Short name of the binary, for user-facing failure messages.
    public var executableName: String { kind.defaultExecutableName }

    public init(
        executable: String,
        cwd: String,
        arguments: [String],
        environment: String = "",
        extraArgs: String = "",
        prependExecutableDirectoryToPath: Bool = false,
        kind: AgentKind = .claudeCode
    ) {
        self.executable = executable
        self.cwd = cwd
        self.arguments = arguments
        self.environment = environment
        self.extraArgs = extraArgs
        self.prependExecutableDirectoryToPath = prependExecutableDirectoryToPath
        self.kind = kind
    }
}

public enum AgentLaunchBuilder {
    public static func build(
        settings: Settings,
        review: WorkItem,
        worktreePath: String,
        kind: AgentKind,
        resolvedExecutablePath: String,
        sessionID: String,
        resume: Bool
    ) -> AgentLaunchSpec {
        let backend = AgentBackends.backend(for: kind)
        var args: [String] = []
        args.append(contentsOf: review.agentFlags ?? [])
        args.append(contentsOf: backend.launchArguments(
            settings: settings,
            review: review,
            sessionID: sessionID,
            resume: resume
        ))
        return AgentLaunchSpec(
            executable: resolvedExecutablePath,
            cwd: worktreePath,
            arguments: args,
            environment: environment(for: kind, settings: settings),
            extraArgs: extraArgs(for: kind, settings: settings),
            prependExecutableDirectoryToPath: backend.prependsExecutableDirectoryToPath,
            kind: kind
        )
    }

    static func environment(for kind: AgentKind, settings: Settings) -> String {
        switch kind {
        case .claudeCode: return settings.claudeEnv
        case .pi: return settings.piEnv
        }
    }

    static func extraArgs(for kind: AgentKind, settings: Settings) -> String {
        switch kind {
        case .claudeCode: return settings.claudeLaunchArgs
        case .pi: return settings.piLaunchArgs
        }
    }

    /// Display name for the agent session (shown in the agent's own session list).
    /// PR-backed items use "#<number> <title>"; tasks use their title (the branch).
    static func sessionName(for review: WorkItem) -> String {
        if let number = review.displayNumber {
            return "#\(number) \(review.title)"
        }
        return review.title
    }
}
