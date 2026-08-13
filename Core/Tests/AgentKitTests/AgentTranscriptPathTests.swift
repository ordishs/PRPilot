import Testing
import Foundation
@testable import AgentKit

@Test func encodesSlashesToHyphens() {
    let url = AgentTranscriptPath.directoryURL(for: .claudeCode, worktreePath: "/Users/me/dev/foo")
    #expect(url.lastPathComponent == "-Users-me-dev-foo")
}

@Test func encodesSpacesToHyphens() {
    // Must match Claude Code's own encoding: a space in the path (e.g. the macOS
    // "Application Support" directory) becomes '-', not a preserved space. Otherwise
    // the transcript watcher tails the wrong directory.
    let url = AgentTranscriptPath.directoryURL(for: .claudeCode, worktreePath: "/Users/me/Application Support/foo")
    #expect(url.lastPathComponent == "-Users-me-Application-Support-foo")
}

@Test func encodesDotsToHyphens() {
    let url = AgentTranscriptPath.directoryURL(for: .claudeCode, worktreePath: "/Users/me/masa.gi/code-reviewer")
    #expect(url.lastPathComponent == "-Users-me-masa-gi-code-reviewer")
}

@Test func preservesExistingHyphensAndAlphanumerics() {
    let url = AgentTranscriptPath.directoryURL(for: .claudeCode, worktreePath: "/x/bsv-blockchain-teranode-pr990")
    #expect(url.lastPathComponent == "-x-bsv-blockchain-teranode-pr990")
}

@Test func sitsUnderClaudeProjectsDir() {
    let url = AgentTranscriptPath.directoryURL(for: .claudeCode, worktreePath: "/x")
    let path = url.path
    #expect(path.contains(".claude/projects/"))
    #expect(path.hasSuffix("/-x"))
}

@Test func archiveTranscriptsMovesJsonlAndHidesThemFromLatest() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let a = dir.appendingPathComponent("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl")
    let b = dir.appendingPathComponent("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jsonl")
    try "{}".write(to: a, atomically: true, encoding: .utf8)
    try "{}".write(to: b, atomically: true, encoding: .utf8)

    #expect(AgentTranscriptPath.latestSessionID(in: dir, kind: .claudeCode) != nil)

    let moved = AgentTranscriptPath.archiveTranscripts(in: dir)
    #expect(moved == 2)

    // No longer discoverable as a resumable session.
    #expect(AgentTranscriptPath.latestSessionID(in: dir, kind: .claudeCode) == nil)
    // Preserved under archived/.
    let archived = dir.appendingPathComponent("archived")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: archived.path)) ?? []
    #expect(names.sorted() == ["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jsonl"])
}

@Test func archiveTranscriptsReturnsZeroWhenNothingToArchive() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(AgentTranscriptPath.archiveTranscripts(in: dir) == 0)
}

@Test func latestSessionIDReturnsNilWhenDirectoryMissing() {
    let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)")
    #expect(AgentTranscriptPath.latestSessionID(in: url, kind: .claudeCode) == nil)
}

@Test func latestSessionIDReturnsNilWhenDirectoryEmpty() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(AgentTranscriptPath.latestSessionID(in: url, kind: .claudeCode) == nil)
}

@Test func latestSessionIDPicksNewestJSONLByModificationTime() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }

    let older = url.appendingPathComponent("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl")
    let newer = url.appendingPathComponent("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jsonl")
    let unrelated = url.appendingPathComponent("notes.txt")

    try "{}".write(to: older, atomically: true, encoding: .utf8)
    try "irrelevant".write(to: unrelated, atomically: true, encoding: .utf8)
    try "{}".write(to: newer, atomically: true, encoding: .utf8)

    let past = Date().addingTimeInterval(-3600)
    let now = Date()
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: older.path)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: newer.path)

    let id = AgentTranscriptPath.latestSessionID(in: url, kind: .claudeCode)
    #expect(id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
}

// MARK: - Backend-generic discovery

/// pi prefixes a timestamp to its transcript names, so the caller cannot build the file path
/// from a session ID. `transcriptExists` must discover it by listing instead — this is the case
/// the old string-concatenation implementation could not handle.
@Test func transcriptExistsFindsAPiTranscriptDespiteItsTimestampPrefix() throws {
    let worktree = "/tmp/pi-exists-\(UUID().uuidString)"
    let dir = AgentTranscriptPath.directoryURL(for: .pi, worktreePath: worktree)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let sessionID = "44444444-5555-6666-7777-888888888888"
    let file = dir.appendingPathComponent("2026-08-13T11-54-02-626Z_\(sessionID).jsonl")
    try "{}".write(to: file, atomically: true, encoding: .utf8)

    #expect(AgentTranscriptPath.transcriptExists(for: .pi, worktreePath: worktree, sessionID: sessionID))
    #expect(!AgentTranscriptPath.transcriptExists(for: .pi, worktreePath: worktree, sessionID: "no-such-session"))
}

@Test func transcriptExistsFindsAClaudeCodeTranscript() throws {
    let worktree = "/tmp/cc-exists-\(UUID().uuidString)"
    let dir = AgentTranscriptPath.directoryURL(for: .claudeCode, worktreePath: worktree)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let sessionID = "10889bb0-624c-4ef5-94f7-77480418849c"
    try "{}".write(to: dir.appendingPathComponent("\(sessionID).jsonl"), atomically: true, encoding: .utf8)

    #expect(AgentTranscriptPath.transcriptExists(for: .claudeCode, worktreePath: worktree, sessionID: sessionID))
    #expect(!AgentTranscriptPath.transcriptExists(for: .claudeCode, worktreePath: worktree, sessionID: "other"))
}

@Test func transcriptExistsIsFalseWhenTheDirectoryIsMissing() {
    let worktree = "/tmp/never-created-\(UUID().uuidString)"
    #expect(!AgentTranscriptPath.transcriptExists(for: .pi, worktreePath: worktree, sessionID: "x"))
    #expect(!AgentTranscriptPath.transcriptExists(for: .claudeCode, worktreePath: worktree, sessionID: "x"))
}

/// The session ID returned for a pi transcript must have the timestamp stripped, or resuming
/// would pass a bogus ID.
@Test func latestSessionIDStripsPiTimestampPrefix() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let older = dir.appendingPathComponent("2026-08-12T15-49-39-776Z_aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl")
    let newer = dir.appendingPathComponent("2026-08-13T11-54-02-626Z_bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.jsonl")
    try "{}".write(to: older, atomically: true, encoding: .utf8)
    try "{}".write(to: newer, atomically: true, encoding: .utf8)
    let now = Date()
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: older.path)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: newer.path)

    #expect(AgentTranscriptPath.latestSessionID(in: dir, kind: .pi) == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
}

/// Each backend must ignore the other's file names, otherwise a directory holding both would
/// hand back a session ID the agent cannot resume.
@Test func eachBackendIgnoresTheOthersTranscriptNames() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let claudeName = "10889bb0-624c-4ef5-94f7-77480418849c.jsonl"
    let piName = "2026-08-13T11-54-02-626Z_44444444-5555-6666-7777-888888888888.jsonl"
    try "{}".write(to: dir.appendingPathComponent(claudeName), atomically: true, encoding: .utf8)
    try "{}".write(to: dir.appendingPathComponent(piName), atomically: true, encoding: .utf8)

    #expect(AgentTranscriptPath.latestSessionID(in: dir, kind: .pi) == "44444444-5555-6666-7777-888888888888")
    #expect(AgentTranscriptPath.latestSessionID(in: dir, kind: .claudeCode) == "10889bb0-624c-4ef5-94f7-77480418849c")
}
