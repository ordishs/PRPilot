import Foundation
import PRPilotModels

public struct ClaudeCodeBackend: AgentBackend {
    public let kind: AgentKind = .claudeCode

    /// Claude Code is a native binary found on the login PATH. See the protocol comment.
    public let prependsExecutableDirectoryToPath = false

    public init() {}

    // MARK: - Transcript location

    public func transcriptDirectories(forWorktreePath path: String) -> [URL] {
        [transcriptDirectory(forWorktreePath: path)]
    }

    public func transcriptDirectory(forWorktreePath path: String) -> URL {
        // Claude Code derives the transcript folder name from the working directory by
        // replacing every character that is not ASCII-alphanumeric or '-' with '-'.
        // This must match exactly — e.g. "/Users/me/Application Support/x" must encode to
        // "-Users-me-Application-Support-x" (space -> '-') and "masa.gi" to "masa-gi"
        // ('.' -> '-'). If it doesn't, the transcript watcher tails the wrong (empty)
        // directory, status stays .starting, and review state never updates.
        let encoded = String(path.map { Self.encodedCharacters.contains($0) ? $0 : "-" })
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".claude/projects/\(encoded)")
    }

    private static let encodedCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")

    public func sessionID(fromTranscriptFilename name: String) -> String? {
        guard name.hasSuffix(".jsonl") else { return nil }
        let id = String(name.dropLast(".jsonl".count))
        guard !id.isEmpty else { return nil }
        // Claude Code session IDs never contain an underscore, but pi separates its timestamp
        // prefix from the session ID with one. Rejecting underscores keeps a pi transcript from
        // parsing as a Claude Code session ID with the timestamp glued to the front, which
        // would then fail to resume. Deliberately narrower than requiring a UUID: the watcher
        // discovers files by this same check, and it should keep tailing any transcript Claude
        // Code writes even if that naming ever changes.
        guard !id.contains("_") else { return nil }
        return id
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
            args.append("--resume")
            args.append(sessionID)
        } else {
            args.append("--session-id")
            args.append(sessionID)
            // The prompt comes from a user-owned template, so upstream changing what
            // /review does no longer requires an app change. A blank template deliberately
            // launches the session with no prompt at all.
            let template = review.prRef != nil
                ? settings.reviewPromptTemplate
                : (review.issueNumber != nil ? settings.issuePromptTemplate : "")
            let prompt = LaunchPrompt.render(template, for: review, url: review.url)
            if !prompt.isEmpty {
                args.append(prompt)
            }
        }
        return args
    }

    // MARK: - Transcript parsing

    public func parse(line: Data, state: inout TranscriptParseState) -> TranscriptEvent? {
        struct MinimalEvent: Decodable {
            let type: String?
            let timestamp: String?
        }
        guard let event = try? JSONDecoder().decode(MinimalEvent.self, from: line) else { return nil }
        guard let ts = event.timestamp else { return nil }
        guard let date = TranscriptTimestamp.date(from: ts) else { return nil }
        updatePendingWorkflows(from: line, type: event.type, state: &state)
        let snippet = extractSnippet(from: line, type: event.type)
        let turnCompleted = isCompletedTurn(from: line, type: event.type) && state.pendingWorkflows == 0
        return TranscriptEvent(
            date: date,
            snippet: snippet,
            turnCompleted: turnCompleted,
            workflowPending: state.pendingWorkflows > 0,
            limitMessage: limitMessage(from: line, type: event.type)
        )
    }

    // MARK: - Handover

    /// Claude Code types a line by role at the top level, and puts the text in
    /// `message.content[]` as `text` blocks. A user line whose content is a tool result is not
    /// a turn the user typed, so it is skipped.
    public func conversationEntry(line: Data) -> HandoverEntry? {
        struct Line: Decodable {
            let type: String?
            let timestamp: String?
            let message: Message?

            struct Message: Decodable {
                let content: ContentField?
                enum CodingKeys: String, CodingKey { case content }

                /// A user turn can carry either a bare string or an array of blocks.
                enum ContentField: Decodable {
                    case text(String)
                    case blocks([Block])

                    init(from decoder: Decoder) throws {
                        if let single = try? decoder.singleValueContainer().decode(String.self) {
                            self = .text(single)
                            return
                        }
                        self = .blocks(try decoder.singleValueContainer().decode([Block].self))
                    }
                }

                struct Block: Decodable {
                    let type: String?
                    let text: String?
                }
            }
        }
        guard let event = try? JSONDecoder().decode(Line.self, from: line) else { return nil }
        let role: HandoverEntry.Role
        switch event.type {
        case "assistant": role = .assistant
        case "user": role = .user
        default: return nil
        }
        guard let ts = event.timestamp, let date = TranscriptTimestamp.date(from: ts) else { return nil }
        let text: String
        switch event.message?.content {
        case .text(let single):
            text = single
        case .blocks(let blocks):
            // A tool_result block means this "user" line is the harness reporting back, not the
            // person. Carrying those into a handover would drown the actual conversation.
            guard !blocks.contains(where: { $0.type == "tool_result" }) else { return nil }
            text = blocks.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n\n")
        case nil:
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A system reminder is harness plumbing, not conversation.
        guard !trimmed.hasPrefix("<system-reminder>") else { return nil }
        return HandoverEntry(role: role, date: date, text: trimmed)
    }

    /// The message of a limit stop, or nil. Reads the same assistant text `extractSnippet`
    /// uses, but keeps it whole: the badge shows the exact wording, including any reset time.
    private func limitMessage(from data: Data, type: String?) -> String? {
        guard type == "assistant" else { return nil }
        struct LimitEvent: Decodable {
            let message: MessageEnvelope?
            struct MessageEnvelope: Decodable {
                let stopReason: String?
                let content: [ContentBlock]?
                struct ContentBlock: Decodable {
                    let type: String?
                    let text: String?
                }
                enum CodingKeys: String, CodingKey {
                    case stopReason = "stop_reason"
                    case content
                }
            }
        }
        guard let event = try? JSONDecoder().decode(LimitEvent.self, from: data) else { return nil }
        let text = event.message?.content?.first { $0.type == "text" }?.text
        return LimitStop.message(stopReason: event.message?.stopReason, text: text)
    }

    /// Runs before a line is reported, so an end_turn on the same line as a workflow launch
    /// is never mistaken for a completion.
    ///
    /// Three signals, in the order a transcript emits them: the `Workflow` tool call starts
    /// the count; the `turn_duration` system event carries the authoritative
    /// `pendingWorkflowCount` (omitted entirely once nothing is outstanding); and a
    /// `<task-notification>` is one workflow reporting back.
    private func updatePendingWorkflows(from data: Data, type: String?, state: inout TranscriptParseState) {
        switch type {
        case "assistant":
            struct ToolUseEvent: Decodable {
                let message: MessageEnvelope?
                struct MessageEnvelope: Decodable {
                    let content: [ContentBlock]?
                    struct ContentBlock: Decodable {
                        let type: String?
                        let name: String?
                    }
                }
            }
            guard let event = try? JSONDecoder().decode(ToolUseEvent.self, from: data) else { return }
            let launches = event.message?.content?.filter { $0.type == "tool_use" && $0.name == "Workflow" }.count ?? 0
            state.pendingWorkflows += launches
        case "system":
            struct SystemEvent: Decodable {
                let subtype: String?
                let pendingWorkflowCount: Int?
            }
            guard let event = try? JSONDecoder().decode(SystemEvent.self, from: data) else { return }
            guard event.subtype == "turn_duration" else { return }
            state.pendingWorkflows = event.pendingWorkflowCount ?? 0
        case "user":
            guard let text = String(data: data, encoding: .utf8),
                  text.contains("<task-notification>")
            else { return }
            state.pendingWorkflows = max(0, state.pendingWorkflows - 1)
        default:
            return
        }
    }

    private func isCompletedTurn(from data: Data, type: String?) -> Bool {
        guard type == "assistant" else { return false }
        struct AssistantStop: Decodable {
            let message: MessageEnvelope?
            struct MessageEnvelope: Decodable {
                let stopReason: String?
                enum CodingKeys: String, CodingKey { case stopReason = "stop_reason" }
            }
        }
        guard let event = try? JSONDecoder().decode(AssistantStop.self, from: data) else { return false }
        return event.message?.stopReason == "end_turn"
    }

    private func extractSnippet(from data: Data, type: String?) -> String? {
        guard type == "assistant" else { return nil }
        struct AssistantEvent: Decodable {
            let message: MessageEnvelope?
            struct MessageEnvelope: Decodable {
                let content: [ContentBlock]?
                struct ContentBlock: Decodable {
                    let type: String?
                    let text: String?
                }
            }
        }
        guard let event = try? JSONDecoder().decode(AssistantEvent.self, from: data) else { return nil }
        guard let first = event.message?.content?.first(where: { $0.type == "text" }) else { return nil }
        guard let text = first.text else { return nil }
        return String(text.prefix(80))
    }
}
