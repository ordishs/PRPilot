import Testing
import Foundation
@testable import PRPilotModels

/// A store written before pi support existed. Nothing in it mentions an agent, and the
/// per-item flags are under their original `claudeFlags` key.
private let preAgentJSON = """
{
  "id": "bsv-blockchain/teranode#944",
  "title": "centrifuge fix",
  "repoKey": "github.com/bsv-blockchain/teranode",
  "baseBranch": "main",
  "headBranch": "fix/centrifuge",
  "worktreePath": "/tmp/wt/pr944",
  "origin": "discovered",
  "claudeSessionID": "abc-123",
  "claudeFlags": ["--dangerously-skip-permissions"],
  "addedAt": "2021-01-01T00:00:00Z",
  "disabled": false,
  "viewedFiles": []
}
"""

private func decodeItem(_ json: String) throws -> WorkItem {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(WorkItem.self, from: Data(json.utf8))
}

@Test func existingItemDecodesWithNoAgentChoiceAndKeepsItsClaudeSession() throws {
    let item = try decodeItem(preAgentJSON)
    // No explicit choice, so the item follows the global default rather than being pinned.
    #expect(item.agent == nil)
    #expect(item.claudeSessionID == "abc-123")
    #expect(item.piSessionID == nil)
}

/// The Swift property was renamed to `agentFlags`; the stored key must stay `claudeFlags` or
/// every existing item silently loses its configured flags.
@Test func perItemFlagsStillDecodeFromTheClaudeFlagsKey() throws {
    let item = try decodeItem(preAgentJSON)
    #expect(item.agentFlags == ["--dangerously-skip-permissions"])
}

@Test func perItemFlagsReencodeUnderTheClaudeFlagsKey() throws {
    let item = try decodeItem(preAgentJSON)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(item)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["claudeFlags"] as? [String] == ["--dangerously-skip-permissions"])
    #expect(object["agentFlags"] == nil)
}

@Test func effectiveAgentFollowsTheGlobalDefaultUntilTheItemChooses() throws {
    var item = try decodeItem(preAgentJSON)
    #expect(item.effectiveAgent(default: .claudeCode) == .claudeCode)
    // Changing the global default moves an item that has made no choice of its own.
    #expect(item.effectiveAgent(default: .pi) == .pi)

    item.agent = .claudeCode
    // Once the item chooses, the global default no longer moves it.
    #expect(item.effectiveAgent(default: .pi) == .claudeCode)
}

/// The point of two slots: switching an item's agent must not destroy the other agent's
/// conversation, because their transcripts are mutually unreadable.
@Test func eachAgentKeepsItsOwnSessionIDSlot() throws {
    var item = try decodeItem(preAgentJSON)
    #expect(item.sessionID(for: .claudeCode) == "abc-123")
    #expect(item.sessionID(for: .pi) == nil)

    item.setSessionID("pi-session-1", for: .pi)
    #expect(item.sessionID(for: .pi) == "pi-session-1")
    #expect(item.sessionID(for: .claudeCode) == "abc-123", "setting pi must not disturb Claude Code")

    item.setSessionID(nil, for: .claudeCode)
    #expect(item.sessionID(for: .claudeCode) == nil)
    #expect(item.sessionID(for: .pi) == "pi-session-1", "clearing Claude Code must not disturb pi")
}

@Test func bothSessionIDsSurviveARoundTrip() throws {
    var item = try decodeItem(preAgentJSON)
    item.setSessionID("pi-session-1", for: .pi)
    item.agent = .pi

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoded = try decodeItem(String(decoding: try encoder.encode(item), as: UTF8.self))

    #expect(decoded.agent == .pi)
    #expect(decoded.claudeSessionID == "abc-123")
    #expect(decoded.piSessionID == "pi-session-1")
}

@Test func settingsDefaultAgentIsClaudeCodeAndPiSettingsStartEmpty() {
    let s = Settings.default
    #expect(s.defaultAgent == .claudeCode)
    #expect(s.piPath == nil)
    #expect(s.piLaunchArgs.isEmpty)
    #expect(s.piEnv.isEmpty)
    #expect(s.piReviewPromptTemplate == "Review the pull request at {url}.")
    #expect(s.piIssuePromptTemplate == "Start work on issue {number}.")
}

@Test func settingsWrittenBeforePiSupportDefaultToClaudeCode() throws {
    let json = """
    {
      "managedRoot": "/tmp",
      "reviewRequestQueries": [],
      "myPRQueries": [],
      "pollIntervalSeconds": 120,
      "claudeLaunchArgs": "",
      "notificationsEnabled": true,
      "diffMode": "unified",
      "diffIgnoreWhitespace": false
    }
    """
    let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(decoded.defaultAgent == .claudeCode)
    #expect(decoded.piPath == nil)
    #expect(decoded.piReviewPromptTemplate == Settings.defaultPiReviewPromptTemplate)
}
