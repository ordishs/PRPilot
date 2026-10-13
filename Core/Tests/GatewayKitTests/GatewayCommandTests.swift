import Testing
import Foundation
@testable import GatewayKit

private func decode(_ json: String) throws -> GatewayCommand {
    try JSONDecoder().decode(GatewayCommand.self, from: Data(json.utf8))
}

@Test func refreshAllDecodesFromItsTypeAlone() throws {
    #expect(try decode(#"{"type":"refreshAll"}"#) == .refreshAll)
}

@Test func commandsCarryingAnIdDecodeThatId() throws {
    #expect(try decode(#"{"type":"refreshItem","id":"a#1"}"#) == .refreshItem(id: "a#1"))
    #expect(try decode(#"{"type":"clearWaiting","id":"a#1"}"#) == .clearWaiting(id: "a#1"))
    #expect(try decode(#"{"type":"clearSession","id":"a#1"}"#) == .clearSession(id: "a#1"))
    #expect(try decode(#"{"type":"clearAgentLimit","id":"a#1"}"#) == .clearAgentLimit(id: "a#1"))
    #expect(try decode(#"{"type":"handOver","id":"a#1"}"#) == .handOver(id: "a#1"))
    #expect(try decode(#"{"type":"removeItem","id":"a#1"}"#) == .removeItem(id: "a#1"))
    #expect(try decode(#"{"type":"markAuthorUpdateSeen","id":"a#1"}"#) == .markAuthorUpdateSeen(id: "a#1"))
}

@Test func startSessionCarriesItsFreshFlag() throws {
    #expect(
        try decode(#"{"type":"startSession","id":"a#1","forceFresh":true}"#)
            == .startSession(id: "a#1", forceFresh: true)
    )
}

@Test func startSessionDefaultsToResumingWhenTheFlagIsAbsent() throws {
    #expect(
        try decode(#"{"type":"startSession","id":"a#1"}"#)
            == .startSession(id: "a#1", forceFresh: false)
    )
}

@Test func setDisabledCarriesItsFlag() throws {
    #expect(
        try decode(#"{"type":"setDisabled","id":"a#1","disabled":true}"#)
            == .setDisabled(id: "a#1", disabled: true)
    )
}

@Test func setLabelAcceptsAValueAndAClear() throws {
    #expect(try decode(#"{"type":"setLabel","id":"a#1","label":"perf"}"#) == .setLabel(id: "a#1", label: "perf"))
    #expect(try decode(#"{"type":"setLabel","id":"a#1"}"#) == .setLabel(id: "a#1", label: nil))
}

@Test func addCommandsCarryTheirUrl() throws {
    let url = "https://github.com/o/r/pull/1"
    #expect(try decode(#"{"type":"addPR","url":"\#(url)"}"#) == .addPR(url: url))
    #expect(try decode(#"{"type":"addIssue","url":"\#(url)"}"#) == .addIssue(url: url))
}

@Test func everyCommandSurvivesARoundTrip() throws {
    let all: [GatewayCommand] = [
        .refreshAll,
        .refreshItem(id: "a#1"),
        .markAuthorUpdateSeen(id: "a#1"),
        .clearWaiting(id: "a#1"),
        .setPane(id: "a#1", pane: "github"),
        .startSession(id: "a#1", forceFresh: false),
        .clearSession(id: "a#1"),
        .clearAgentLimit(id: "a#1"),
        .handOver(id: "a#1"),
        .addPR(url: "https://example.com/1"),
        .addIssue(url: "https://example.com/2"),
        .setIssueStatus(id: "a#1", status: "done"),
        .setLabel(id: "a#1", label: "perf"),
        .setDisabled(id: "a#1", disabled: true),
        .removeItem(id: "a#1"),
    ]

    for command in all {
        let data = try JSONEncoder().encode(command)
        #expect(try JSONDecoder().decode(GatewayCommand.self, from: data) == command)
    }
}

@Test func aGitCommandTypeIsRejectedBecauseNoCaseEncodesOne() {
    #expect(throws: DecodingError.self) {
        try decode(#"{"type":"push","id":"a#1"}"#)
    }
    #expect(throws: DecodingError.self) {
        try decode(#"{"type":"rebase","id":"a#1"}"#)
    }
}

@Test func theEnvelopeCarriesACommandIdAlongsideTheCommand() throws {
    let envelope = try JSONDecoder().decode(
        GatewayCommandEnvelope.self,
        from: Data(#"{"commandID":"c-1","command":{"type":"refreshAll"}}"#.utf8)
    )

    #expect(envelope.commandID == "c-1")
    #expect(envelope.command == .refreshAll)
}

@Test func setAgentCarriesItsChoice() throws {
    #expect(
        try decode(#"{"type":"setAgent","id":"a#1","agent":"codex"}"#)
            == .setAgent(id: "a#1", agent: "codex")
    )
}

@Test func setAgentWithNoAgentMeansFollowTheDefault() throws {
    #expect(
        try decode(#"{"type":"setAgent","id":"a#1"}"#)
            == .setAgent(id: "a#1", agent: nil)
    )
}

@Test func setAgentSurvivesARoundTrip() throws {
    let command = GatewayCommand.setAgent(id: "a#1", agent: "pi")
    let data = try JSONEncoder().encode(command)
    #expect(try JSONDecoder().decode(GatewayCommand.self, from: data) == command)
}
