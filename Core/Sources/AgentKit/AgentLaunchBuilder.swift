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
        resume: Bool,
        denyRules: [String] = [],
        promptOverride: String? = nil
    ) -> AgentLaunchSpec {
        let backend = AgentBackends.backend(for: kind)
        var args: [String] = []
        if kind == .claudeCode, !denyRules.isEmpty {
            args.append("--disallowedTools")
            args.append(denyRules.joined(separator: ","))
        }
        args.append(contentsOf: review.agentFlags ?? [])
        args.append(contentsOf: backend.launchArguments(
            settings: promptOverride.map { settings.withEveryLaunchPrompt($0) } ?? settings,
            review: review,
            sessionID: sessionID,
            resume: resume
        ))
        if !resume, let promptOverride, review.prRef == nil, review.issueNumber == nil {
            args.append(LaunchPrompt.render(promptOverride, for: review, url: nil))
        }
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
        case .codex: return settings.codexEnv
        }
    }

    static func extraArgs(for kind: AgentKind, settings: Settings) -> String {
        switch kind {
        case .claudeCode: return settings.claudeLaunchArgs
        case .pi: return settings.piLaunchArgs
        case .codex: return settings.codexLaunchArgs
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

extension Settings {
    /// Settings whose launch templates all say `prompt`. The backends pick a template by agent
    /// and by ticket kind, so setting every one makes a one-off first prompt reach whichever
    /// backend launches. A resume sends no prompt, so it ignores them.
    fileprivate func withEveryLaunchPrompt(_ prompt: String) -> Settings {
        var copy = self
        copy.reviewPromptTemplate = prompt
        copy.issuePromptTemplate = prompt
        copy.piReviewPromptTemplate = prompt
        copy.piIssuePromptTemplate = prompt
        copy.codexReviewPromptTemplate = prompt
        copy.codexIssuePromptTemplate = prompt
        return copy
    }
}

/// Claude Code deny rules for sessions the app starts on its own. A prompt is not a limit,
/// so these block the commands that merge or post, at the tool layer.
public enum DenyRules {
    public static let autoFix: [String] = [
        "Bash(gh pr merge:*)",
        "Bash(gh pr review:*)",
        "Bash(gh pr comment:*)",
        "Bash(gh issue comment:*)",
        "Bash(gh api*graphql*)",
        "Bash(gh api* -X*)",
        "Bash(gh api* --method*)",
        "Bash(gh api* -f *)",
        "Bash(gh api* -F *)",
        "Bash(gh api* --field*)",
        "Bash(gh api* --raw-field*)",
        "Bash(gh api* --input*)",
    ]

    public static let coordinator: [String] = autoFix + ["Bash(git push:*)"]
}
