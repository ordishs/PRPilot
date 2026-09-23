import Testing
import Foundation
@testable import GatewayKit

/// The web client lives outside the Swift package, so nothing else stops its command names
/// drifting from the decoder. This reads the real file and checks every one.
private var clientSource: String {
    get throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GatewayKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("App/Resources/web/app.js")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

/// The list logic lives in its own module so node can test it without a browser.
private var listingSource: String {
    get throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Resources/web/listing.mjs")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private func commandTypes(in source: String) -> [String] {
    let pattern = #"type:\s*'([A-Za-z]+)'"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(source.startIndex..., in: source)

    var found: [String] = []
    regex.enumerateMatches(in: source, range: range) { match, _, _ in
        guard let match, let r = Range(match.range(at: 1), in: source) else { return }
        found.append(String(source[r]))
    }
    return Array(Set(found)).sorted()
}

@Test func theClientSendsCommandTypesTheServerCanDecode() throws {
    let types = commandTypes(in: try clientSource)

    #expect(!types.isEmpty, "the client should issue at least one command")

    for type in types {
        // Every command the client builds carries an id except refreshAll, and the extra
        // keys are ignored by the decoder, so one shape covers them all.
        let json = #"{"type":"\#(type)","id":"a#1","disabled":true,"forceFresh":true,"pane":"github","label":"x","status":"done","text":"x","url":"https://example.com"}"#
        #expect(
            throws: Never.self,
            "client sends '\(type)', which the server cannot decode"
        ) {
            try JSONDecoder().decode(GatewayCommand.self, from: Data(json.utf8))
        }
    }
}

@Test func theClientNeverSendsAGitCommand() throws {
    let types = commandTypes(in: try clientSource)
    let git = ["push", "rebase", "continueRebase", "abortRebase", "forcePush", "discardLocalChanges"]

    for forbidden in git {
        #expect(!types.contains(forbidden), "the client must not offer '\(forbidden)'")
    }
}

@Test func theClientHasATitleForEverySectionTheServerSends() throws {
    let source = try listingSource

    for kind in GatewaySectionKind.allCases {
        #expect(
            source.contains("\(kind.rawValue): '"),
            "SECTION_TITLES has no title for the '\(kind.rawValue)' section"
        )
    }
}

@Test func theClientStylesEveryBadgeToneTheServerCanSend() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("App/Resources/web/app.css")
    let css = try String(contentsOf: url, encoding: .utf8)

    for tone in ["green", "orange", "red", "blue", "grey"] {
        #expect(css.contains(".badge.\(tone)"), "no style for badge tone '\(tone)'")
    }
}

@Test func theTabBarListsEverySectionInTheMacOrder() throws {
    let source = try listingSource
    guard let start = source.range(of: "export const SECTION_ORDER = ["),
          let end = source.range(of: "]", range: start.upperBound..<source.endIndex)
    else {
        Issue.record("SECTION_ORDER not found in the client")
        return
    }

    let declared = source[start.upperBound..<end.lowerBound]
    let expected = GatewaySectionKind.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    #expect(declared == Substring(expected), "SECTION_ORDER must be \(expected)")
}

@Test func theClientCanReachTheTranscriptRouteAndSendPrompts() throws {
    let source = try clientSource

    #expect(source.contains("/api/transcript?id="), "client never calls the transcript route")
    #expect(source.contains("'sendPrompt'"), "client cannot reply to an agent")
}

@Test func theClientCanSearchSortFilterAndShowEveryBadge() throws {
    let app = try clientSource
    let listing = try listingSource

    #expect(listing.contains("export function matchesQuery("), "no search predicate in the client")
    #expect(listing.contains("export function matchesFilters("), "no pill filter in the client")
    #expect(listing.contains("export function sortItems("), "no sort in the client")
    #expect(app.contains("from '/listing.mjs'"), "the page never loads the list logic")
    #expect(app.contains("row-badges"), "rows do not render the badge set")
}

@Test func everyFieldTheListLogicReadsIsOneTheServerSends() throws {
    let listing = try listingSource
    let item = GatewayItem(
        id: "a#1", kind: .pr, owner: "o", repo: "r", number: 1, url: nil, title: "t",
        author: "a", headBranch: "h", baseBranch: "main", attentionReason: nil, agent: nil,
        badges: [], issueStatus: nil, label: nil, isDisabled: false, ahead: 0, behind: 0,
        localChanges: 0, lastActivityAt: nil, primaryCommand: nil, addedAt: Date()
    )
    let data = try GatewayCoding.encoder.encode(item)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    for field in ["signals", "resources", "isParked", "addedAt", "statusRank", "title", "author", "headBranch", "number"] {
        #expect(listing.contains(".\(field)"), "the list logic never reads '\(field)'")
        #expect(json[field] != nil, "the server does not send '\(field)'")
    }
}
