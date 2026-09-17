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
        let json = #"{"type":"\#(type)","id":"a#1","disabled":true,"forceFresh":true,"pane":"github","label":"x","status":"done","url":"https://example.com"}"#
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

@Test func theClientReadsGroupNamesTheServerActuallySends() throws {
    let source = try clientSource

    for kind in GatewayGroupKind.allCases {
        #expect(
            source.contains(kind.rawValue),
            "the client has no label for the '\(kind.rawValue)' group"
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
