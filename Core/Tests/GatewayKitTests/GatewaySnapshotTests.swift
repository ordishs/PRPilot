import Testing
import Foundation
@testable import GatewayKit

private func sampleItem() -> GatewayItem {
    GatewayItem(
        id: "bsv-blockchain/teranode#4788",
        kind: .pr,
        owner: "bsv-blockchain",
        repo: "teranode",
        number: 4788,
        url: "https://github.com/bsv-blockchain/teranode/pull/4788",
        title: "UTXO store: drop the legacy index path",
        author: "bob",
        headBranch: "feat/utxo-legacy-drop",
        baseBranch: "main",
        attentionReason: "Agent hit its usage limit",
        agent: GatewayAgent(
            kind: "codex",
            status: "limited",
            verdict: "Two concerns.",
            elapsedSeconds: 1080,
            usedPercent: 100
        ),
        badges: [GatewayBadge(text: "✗ CI", tone: .red, help: "CI is failing")],
        issueStatus: nil,
        label: nil,
        isDisabled: false,
        ahead: 0,
        behind: 12,
        localChanges: 2,
        lastActivityAt: Date(timeIntervalSince1970: 1_789_000_000),
        primaryCommand: nil
    )
}

@Test func snapshotSurvivesACodableRoundTrip() throws {
    let snapshot = GatewaySnapshot(
        generatedAt: Date(timeIntervalSince1970: 1_789_000_100),
        gatewayVersion: GatewayVersion.current,
        appVersion: "0.9.1",
        login: "ordishs",
        groups: [GatewayGroup(kind: .needsYou, items: [sampleItem()])],
        warnings: ["discovery query failed"]
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(GatewaySnapshot.self, from: data)

    #expect(decoded == snapshot)
}

@Test func groupKindsEncodeAsTheNamesTheClientReads() throws {
    let encoded = try JSONEncoder().encode(
        [GatewayGroupKind.needsYou, .running, .queued, .idle]
    )
    #expect(String(decoding: encoded, as: UTF8.self) == #"["needsYou","running","queued","idle"]"#)
}

@Test func badgeTonesEncodeAsTheNamesTheClientReads() throws {
    let encoded = try JSONEncoder().encode(
        [GatewayBadgeTone.green, .orange, .red, .blue, .grey]
    )
    #expect(String(decoding: encoded, as: UTF8.self) == #"["green","orange","red","blue","grey"]"#)
}
