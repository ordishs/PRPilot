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

    /// Directories that can hold this agent's transcripts for a given working directory.
    ///
    /// Claude Code and pi each derive one folder name from the path, by their own encoding,
    /// and the rules do not agree. codex does not key transcripts by directory at all: it
    /// writes every session of every project into one date-partitioned tree, so it answers
    /// with the day directories a session for this worktree could be in.
    ///
    /// A directory in this list is a *candidate*. Whether a file inside one belongs to this
    /// worktree is `transcript(at:belongsToWorktreePath:)`.
    func transcriptDirectories(forWorktreePath path: String) -> [URL]

    /// Whether one transcript file belongs to `path`.
    ///
    /// True by default, because an agent whose directory name encodes the working directory
    /// has already answered the question. codex has not: its day directory mixes every
    /// project, so it reads the working directory back out of the file.
    ///
    /// Without this, `latestSessionID` would resume a stranger's conversation in this
    /// worktree and `archiveTranscripts` would archive every codex session started that day,
    /// across every project.
    func transcript(at url: URL, belongsToWorktreePath path: String) -> Bool

    /// Whether the app may choose the session ID at launch.
    ///
    /// True for Claude Code and pi, which both take `--session-id`. False for codex, which
    /// has no such flag and names the session itself. For a backend that answers false, a
    /// fresh launch persists no ID, and `SessionAdoption` writes the real one through as soon
    /// as the transcript watcher attaches to the file codex created.
    var acceptsAssignedSessionID: Bool { get }

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

    /// One transcript line read as a conversation turn, or nil when the line is not one.
    ///
    /// Separate from `parse` because the two want different things from the same line. `parse`
    /// drives the status dot and truncates hard; this feeds a handover note and needs the
    /// whole turn. Tool calls and reasoning are deliberately excluded — a handover wants what
    /// was asked and what was answered.
    func conversationEntry(line: Data) -> HandoverEntry?

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

public extension AgentBackend {
    /// An agent whose directory name encodes the working directory has already proved
    /// membership by the file being there at all.
    func transcript(at url: URL, belongsToWorktreePath path: String) -> Bool { true }

    var acceptsAssignedSessionID: Bool { true }

    /// A backend that cannot read its own conversation back contributes no turns. The note is
    /// still written, and says the transcript held nothing readable.
    func conversationEntry(line: Data) -> HandoverEntry? { nil }
}

public enum AgentBackends {
    public static let claudeCode = ClaudeCodeBackend()
    public static let pi = PiBackend()
    public static let codex = CodexBackend()

    public static func backend(for kind: AgentKind) -> any AgentBackend {
        switch kind {
        case .claudeCode: return claudeCode
        case .pi: return pi
        case .codex: return codex
        }
    }
}
