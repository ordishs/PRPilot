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

// MARK: - codex and failover settings

@Test func codexSettingsStartEmptyAndFailoverDefaultsToManual() {
    let s = Settings.default
    #expect(s.codexPath == nil)
    #expect(s.codexLaunchArgs.isEmpty)
    #expect(s.codexEnv.isEmpty)
    #expect(s.codexReviewPromptTemplate == "Review the pull request at {url}.")
    #expect(s.codexIssuePromptTemplate == "Start work on issue {number}.")
    // Manual by default: a switch hands a half-finished worktree to an agent with a different
    // sandbox and approval model, so it should be a deliberate act until the user says
    // otherwise.
    #expect(s.agentFailover == .manual)
    #expect(s.failoverAgent == .codex)
}

@Test func settingsWrittenBeforeCodexSupportDecodeWithTheNewDefaults() throws {
    let json = """
    {
      "managedRoot": "/tmp",
      "reviewRequestQueries": [],
      "myPRQueries": [],
      "pollIntervalSeconds": 120,
      "claudeLaunchArgs": "",
      "notificationsEnabled": true,
      "diffMode": "unified",
      "diffIgnoreWhitespace": false,
      "defaultAgent": "pi",
      "piPath": "/opt/node/bin/pi"
    }
    """
    let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(decoded.codexPath == nil)
    #expect(decoded.codexReviewPromptTemplate == Settings.defaultCodexReviewPromptTemplate)
    #expect(decoded.agentFailover == .manual)
    #expect(decoded.failoverAgent == .codex)
    // The settings that were already there are untouched.
    #expect(decoded.defaultAgent == .pi)
    #expect(decoded.piPath == "/opt/node/bin/pi")
}

@Test func failoverSettingsRoundTrip() throws {
    var s = Settings.default
    s.agentFailover = .automatic
    s.failoverAgent = .pi
    s.codexPath = "/opt/node/bin/codex"
    let decoded = try JSONDecoder().decode(Settings.self, from: try JSONEncoder().encode(s))
    #expect(decoded.agentFailover == .automatic)
    #expect(decoded.failoverAgent == .pi)
    #expect(decoded.codexPath == "/opt/node/bin/codex")
}

@Test func theUsageWarningThresholdDefaultsAndMigrates() throws {
    #expect(Settings.default.usageWarningPercent == 90)

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
    #expect(decoded.usageWarningPercent == SessionDefaults.usageWarningPercent)

    var edited = Settings.default
    edited.usageWarningPercent = 75
    let roundTripped = try JSONDecoder().decode(Settings.self, from: try JSONEncoder().encode(edited))
    #expect(roundTripped.usageWarningPercent == 75)
}

@Test func anItemStoredBeforeTheGaugeHasNoUsage() throws {
    let json = """
    {
      "id": "X", "title": "t", "repoKey": "github.com/o/r",
      "baseBranch": "main", "origin": "added", "autoReview": false,
      "addedAt": "2023-11-14T22:13:20Z", "disabled": false, "viewedFiles": [], "approvedByMe": false,
      "codexSessionID": "01a03df8-9e0c-7672-908a-546665225b9b"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(WorkItem.self, from: Data(json.utf8))
    #expect(decoded.agentUsage == nil)
    #expect(decoded.codexSessionID == "01a03df8-9e0c-7672-908a-546665225b9b")
}
