import Foundation
import PRPilotModels

/// Per-transcript state a backend carries across lines while it parses.
///
/// `TranscriptWatcher` replays a transcript from the start every time it attaches to a file,
/// so this rebuilds itself on resume and must reset whenever the watched file changes.
public struct TranscriptParseState: Sendable {
    /// Workflows launched from this session that have not reported back. Claude Code only —
    /// pi has no workflow concept and leaves this at zero.
    public var pendingWorkflows: Int = 0

    public init() {}
}

/// Everything that differs between one coding agent and another.
///
/// Each agent owns its session-directory layout, its transcript filenames, its launch
/// arguments and its JSONL event schema. Nothing outside this protocol's conformances knows
/// any of it.
public protocol AgentBackend: Sendable {
    var kind: AgentKind { get }

    /// Directory holding this agent's transcripts for a given working directory. Each agent
    /// derives the folder name from the path by its own encoding, and the rules do not agree.
    func transcriptDirectory(forWorktreePath path: String) -> URL

    /// Session ID for a transcript file name, or nil when the name is not a transcript.
    /// Claude Code names files `<uuid>.jsonl`; pi prefixes a timestamp.
    func sessionID(fromTranscriptFilename name: String) -> String?

    /// Arguments after the executable. Excludes the per-item flags and the user's own extra
    /// arguments, which `AgentLaunchBuilder` adds around this.
    func launchArguments(
        settings: Settings,
        review: WorkItem,
        sessionID: String,
        resume: Bool
    ) -> [String]

    /// One transcript line reduced to what drives review status, or nil when the line carries
    /// nothing usable. `state` persists across the lines of one transcript.
    func parse(line: Data, state: inout TranscriptParseState) -> TranscriptEvent?

    /// Whether to prepend the executable's own directory to PATH before exec.
    ///
    /// pi is a node script whose shebang is `#!/usr/bin/env node`. PR Pilot launches through
    /// a login shell, which reads `.zprofile` but not `.zshrc`, and nvm puts node on the PATH
    /// in `.zshrc`. So a GUI-launched pi cannot find its own interpreter and exits 127 without
    /// drawing anything. pi's bin directory holds the sibling `node`, so prepending it fixes
    /// the launch.
    ///
    /// False for Claude Code, which is a native binary. Setting it true there would change the
    /// PATH its child processes inherit, for no benefit.
    var prependsExecutableDirectoryToPath: Bool { get }
}

public enum AgentBackends {
    public static let claudeCode = ClaudeCodeBackend()
    public static let pi = PiBackend()

    public static func backend(for kind: AgentKind) -> any AgentBackend {
        switch kind {
        case .claudeCode: return claudeCode
        case .pi: return pi
        }
    }
}
