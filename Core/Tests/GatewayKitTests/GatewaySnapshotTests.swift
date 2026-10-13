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
        primaryCommand: nil,
        signals: ["ciFailing", "dirty"],
        resources: ["worktree", "session"],
        isParked: true,
        addedAt: Date(timeIntervalSince1970: 1_788_000_000),
        statusRank: 1
    )
}

@Test func snapshotSurvivesACodableRoundTrip() throws {
    let snapshot = GatewaySnapshot(
        generatedAt: Date(timeIntervalSince1970: 1_789_000_100),
        gatewayVersion: GatewayVersion.current,
        appVersion: "0.9.1",
        login: "ordishs",
        sections: [
            GatewaySection(kind: .myWork, items: []),
            GatewaySection(kind: .reviewRequests, items: [sampleItem()]),
            GatewaySection(kind: .issues, items: []),
        ],
        listing: GatewayListing(
            signalFilters: [GatewayOption(key: "agent", label: "Agent", help: "unanswered turn")],
            resourceFilters: [GatewayOption(key: "worktree", label: "Worktree", help: "on disk")],
            sorts: [GatewayOption(key: "byStatus", label: "By status", help: "")],
            sort: "byStatus",
            hideParked: true
        ),
        warnings: ["discovery query failed"]
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(GatewaySnapshot.self, from: data)

    #expect(decoded == snapshot)
}

@Test func sectionKindsEncodeAsTheNamesTheClientReads() throws {
    let encoded = try JSONEncoder().encode(GatewaySectionKind.allCases)
    #expect(String(decoding: encoded, as: UTF8.self) == #"["myWork","reviewRequests","issues"]"#)
}

@Test func theSortKeyTravelsAsAnISO8601StringTheBrowserCanParse() throws {
    let data = try GatewayCoding.encoder.encode(sampleItem())
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(json["addedAt"] as? String == "2026-08-29T10:40:00Z")
    #expect(json["statusRank"] as? Int == 1)
    #expect(json["signals"] as? [String] == ["ciFailing", "dirty"])
    #expect(json["isParked"] as? Bool == true)
}

@Test func badgeTonesEncodeAsTheNamesTheClientReads() throws {
    let encoded = try JSONEncoder().encode(
        [GatewayBadgeTone.green, .orange, .red, .blue, .grey]
    )
    #expect(String(decoding: encoded, as: UTF8.self) == #"["green","orange","red","blue","grey"]"#)
}

@Test func anItemWithoutADetailDecodesWithAnEmptyOne() throws {
    let item = sampleItem()
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
    object.removeValue(forKey: "detail")
    let data = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(GatewayItem.self, from: data)

    #expect(decoded.detail == .empty)
}

@Test func theDetailSurvivesARoundTrip() throws {
    var item = sampleItem()
    item.detail = GatewayDetail(
        pane: "claude",
        paneState: "failed",
        paneMessage: "worktree failed",
        runLabel: "started today",
        rebase: GatewayRebase(state: "conflicted", files: ["a.go"], message: nil),
        agentChoice: "codex",
        agentKey: "codex",
        canHandOver: true,
        sessionID: "abc",
        canClearAgentBadge: true,
        canClearAuthorBadge: false,
        canClearLimit: true
    )

    let data = try JSONEncoder().encode(item)

    #expect(try JSONDecoder().decode(GatewayItem.self, from: data) == item)
}
