import Foundation
import PRPilotModels

public struct PiBackend: AgentBackend {
    public let kind: AgentKind = .pi

    /// pi is a node script and a GUI-launched login shell has no nvm PATH. See the protocol
    /// comment on this requirement — without it pi exits 127 before drawing anything.
    public let prependsExecutableDirectoryToPath = true

    public init() {}

    // MARK: - Transcript location

    public func transcriptDirectories(forWorktreePath path: String) -> [URL] {
        [transcriptDirectory(forWorktreePath: path)]
    }

    public func transcriptDirectory(forWorktreePath path: String) -> URL {
        // pi derives the folder name by dropping the leading '/', replacing the remaining
        // '/' with '-', and wrapping the result in '--'. Unlike Claude Code it does NOT
        // sanitise anything else, so spaces and dots survive verbatim:
        //   /Users/me/Library/Application Support/PRPilot/worktrees.noindex/x
        //     -> --Users-me-Library-Application Support-PRPilot-worktrees.noindex-x--
        // Verified against real pi sessions, including a PR Pilot worktree whose path
        // contains both a space and a dot. If this drifts, the watcher tails an empty
        // directory and status stays .starting forever.
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let encoded = trimmed.replacingOccurrences(of: "/", with: "-")
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".pi/agent/sessions/--\(encoded)--")
    }

    public func sessionID(fromTranscriptFilename name: String) -> String? {
        // pi names transcripts "<iso-timestamp>_<uuid>.jsonl", e.g.
        // "2026-08-13T11-54-02-626Z_44444444-5555-6666-7777-888888888888.jsonl".
        // The timestamp itself contains no underscore, so the session ID is everything after
        // the first one. A name with no underscore is not a pi transcript.
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(".jsonl".count))
        guard let separator = stem.firstIndex(of: "_") else { return nil }
        let id = String(stem[stem.index(after: separator)...])
        return id.isEmpty ? nil : id
    }

    // MARK: - Launch

    public func launchArguments(
        settings: Settings,
        review: WorkItem,
        sessionID: String,
        resume: Bool
    ) -> [String] {
        var args: [String] = []
        args.append("--name")
        args.append(AgentLaunchBuilder.sessionName(for: review))
        if resume {
            // NOT `--resume`. That flag opens an interactive session picker and would leave
            // the pane waiting on a keypress forever. `--session <id>` resumes directly.
            args.append("--session")
            args.append(sessionID)
        } else {
            args.append("--session-id")
            args.append(sessionID)
            let template = review.prRef != nil
                ? settings.piReviewPromptTemplate
                : (review.issueNumber != nil ? settings.piIssuePromptTemplate : "")
            let prompt = LaunchPrompt.render(template, for: review, url: review.url)
            if !prompt.isEmpty {
                args.append(prompt)
            }
        }
        return args
    }

    // MARK: - Handover

    /// pi wraps every turn in a `message` envelope and types it by `message.role`. Text lives
    /// in `content[]` blocks of type `text`, the same shape `parse` reads for its snippet.
    public func conversationEntry(line: Data) -> HandoverEntry? {
        struct Line: Decodable {
            let type: String?
            let timestamp: String?
            let message: Message?

            struct Message: Decodable {
                let role: String?
                let content: [Block]?

                struct Block: Decodable {
                    let type: String?
                    let text: String?
                }
            }
        }
        guard let event = try? JSONDecoder().decode(Line.self, from: line) else { return nil }
        guard event.type == "message" else { return nil }
        guard let ts = event.timestamp, let date = TranscriptTimestamp.date(from: ts) else { return nil }
        let role: HandoverEntry.Role
        switch event.message?.role {
        case "assistant": role = .assistant
        case "user": role = .user
        default: return nil
        }
        let text = (event.message?.content ?? [])
            .compactMap { $0.type == "text" ? $0.text : nil }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return HandoverEntry(role: role, date: date, text: text)
    }

    // MARK: - Transcript parsing

    public func parse(line: Data, state: inout TranscriptParseState) -> TranscriptEvent? {
        // pi wraps everything in a "message" envelope rather than typing the line by role:
        //   {"type":"message","timestamp":"…","message":{"role":"assistant",…}}
        // Session headers, model_change and thinking_level_change lines carry no message and
        // are skipped.
        struct Line: Decodable {
            let type: String?
            let timestamp: String?
            let message: Message?

            struct Message: Decodable {
                let role: String?
                let stopReason: String?
                let content: [Block]?

                struct Block: Decodable {
                    let type: String?
                    let text: String?
                }
            }
        }
        guard let event = try? JSONDecoder().decode(Line.self, from: line) else { return nil }
        guard event.type == "message" else { return nil }
        guard let ts = event.timestamp, let date = TranscriptTimestamp.date(from: ts) else { return nil }
        guard let message = event.message, message.role == "assistant" else {
            // A user turn or a tool result still proves the session is alive, so it must move
            // the status clock. It is never a completion and carries no verdict snippet.
            return TranscriptEvent(date: date, snippet: nil, turnCompleted: false, workflowPending: false)
        }

        let snippet = message.content?
            .first(where: { $0.type == "text" })
            .flatMap(\.text)
            .map { String($0.prefix(80)) }

        // Observed stop reasons: "toolUse" (pi keeps working), "stop" (pi yielded to the
        // user), "aborted" (interrupted), "error" (failed). Only "stop" is a completed turn.
        // "aborted" and "error" fall through to the idle-decay path, which matches how Claude
        // Code already behaves after an interrupt.
        let turnCompleted = message.stopReason == "stop"

        // pi has no workflow concept, so this stays false and `state` is never touched.
        return TranscriptEvent(
            date: date,
            snippet: snippet,
            turnCompleted: turnCompleted,
            workflowPending: false
        )
    }
}
