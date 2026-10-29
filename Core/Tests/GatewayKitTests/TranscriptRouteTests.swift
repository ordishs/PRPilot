import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
@testable import GatewayKit

private let token = "test-token"
private let auth: HTTPFields = [.authorization: "Bearer \(token)"]

@MainActor
private func app(_ backend: FakeGatewayBackend) -> some ApplicationProtocol {
    Application(
        router: GatewayRouter.make(
            backend: backend,
            verifier: BearerTokenVerifier(token: token),
            ledger: CommandLedger(capacity: 8),
            appVersion: "test"
        )
    )
}

@Test func theTranscriptRouteNeedsAToken() async throws {
    let backend = await FakeGatewayBackend()
    try await app(backend).test(.router) { client in
        try await client.execute(uri: "/api/transcript?id=a%231", method: .get) { response in
            #expect(response.status == .unauthorized)
        }
    }
    #expect(await backend.transcriptRequests.isEmpty)
}

@Test func theTranscriptRouteRejectsAMissingId() async throws {
    let backend = await FakeGatewayBackend()
    try await app(backend).test(.router) { client in
        try await client.execute(uri: "/api/transcript", method: .get, headers: auth) { response in
            #expect(response.status == .badRequest)
        }
    }
}

@Test func anIdWithSlashAndHashSurvivesTheQueryString() async throws {
    let backend = await FakeGatewayBackend()
    // Real ids look like "owner/repo#4788" — both characters break a path parameter.
    try await app(backend).test(.router) { client in
        try await client.execute(
            uri: "/api/transcript?id=bsv-blockchain%2Fteranode%234788",
            method: .get,
            headers: auth
        ) { response in
            #expect(response.status == .ok)
        }
    }

    #expect(await backend.transcriptRequests.first?.id == "bsv-blockchain/teranode#4788")
}

@Test func anItemWithNoSessionReportsUnavailableRatherThanAnEmptyConversation() async throws {
    let backend = await FakeGatewayBackend()
    try await app(backend).test(.router) { client in
        try await client.execute(uri: "/api/transcript?id=a%231", method: .get, headers: auth) { response in
            let transcript = try GatewayCoding.decoder.decode(GatewayTranscript.self, from: Data(buffer: response.body))
            #expect(transcript.available == false)
            #expect(transcript.turns.isEmpty)
            #expect(transcript.note != nil)
        }
    }
}

@Test func theTurnsComeBackOldestFirst() async throws {
    let backend = await FakeGatewayBackend()
    await MainActor.run {
        backend.cannedTranscript = GatewayTranscript(
            itemID: "a#1",
            agent: "Claude Code",
            turns: [
                GatewayTurn(role: .user, at: Date(timeIntervalSince1970: 100), text: "review this"),
                GatewayTurn(role: .assistant, at: Date(timeIntervalSince1970: 200), text: "two concerns"),
            ],
            truncated: true,
            available: true
        )
    }

    try await app(backend).test(.router) { client in
        try await client.execute(uri: "/api/transcript?id=a%231", method: .get, headers: auth) { response in
            let transcript = try GatewayCoding.decoder.decode(GatewayTranscript.self, from: Data(buffer: response.body))
            #expect(transcript.turns.map(\.role) == [.user, .assistant])
            #expect(transcript.turns.first?.at ?? .distantFuture < transcript.turns.last?.at ?? .distantPast)
            #expect(transcript.truncated)
            #expect(transcript.agent == "Claude Code")
        }
    }
}

@Test func theLimitIsClampedSoAClientCannotAskForEverything() async throws {
    let backend = await FakeGatewayBackend()
    try await app(backend).test(.router) { client in
        for (query, expected) in [("limit=5", 5), ("limit=100000", 500), ("limit=0", 1), ("", 80)] {
            let uri = query.isEmpty ? "/api/transcript?id=a%231" : "/api/transcript?id=a%231&\(query)"
            try await client.execute(uri: uri, method: .get, headers: auth) { response in
                #expect(response.status == .ok)
            }
            #expect(await backend.transcriptRequests.last?.limit == expected)
        }
    }
}

@Test func sendPromptDecodesItsText() throws {
    let decoded = try JSONDecoder().decode(
        GatewayCommand.self,
        from: Data(#"{"type":"sendPrompt","id":"a#1","text":"carry on"}"#.utf8)
    )

    #expect(decoded == .sendPrompt(id: "a#1", text: "carry on"))
}

@Test func sendPromptSurvivesARoundTripWithAwkwardText() throws {
    let command = GatewayCommand.sendPrompt(id: "a#1", text: "line one\nline \"two\"\ttabbed")
    let data = try JSONEncoder().encode(command)

    #expect(try JSONDecoder().decode(GatewayCommand.self, from: data) == command)
}

@Test func theGitHubRouteNeedsATokenAndAnId() async throws {
    let backend = await FakeGatewayBackend()
    try await app(backend).test(.router) { client in
        try await client.execute(uri: "/api/github?id=a%231", method: .get) { response in
            #expect(response.status == .unauthorized)
        }
        try await client.execute(uri: "/api/github", method: .get, headers: auth) { response in
            #expect(response.status == .badRequest)
        }
    }
    #expect(await backend.threadRequests.isEmpty)
}

@Test func theGitHubRouteReturnsTheThreadForTheDecodedId() async throws {
    let backend = await FakeGatewayBackend()
    await MainActor.run {
        backend.cannedThread = GatewayThread(
            itemID: "o/r#7",
            available: true,
            title: "Fix it",
            state: "OPEN",
            author: "alice",
            body: "details",
            labels: ["bug"],
            entries: [GatewayThread.Entry(author: "bob", at: "2026-10-21T09:00:00Z", body: "hm")]
        )
    }

    try await app(backend).test(.router) { client in
        try await client.execute(uri: "/api/github?id=o%2Fr%237", method: .get, headers: auth) { response in
            #expect(response.status == .ok)
            let thread = try GatewayCoding.decoder.decode(GatewayThread.self, from: Data(buffer: response.body))
            #expect(thread.title == "Fix it")
            #expect(thread.entries.map(\.author) == ["bob"])
        }
    }
    #expect(await backend.threadRequests == ["o/r#7"])
}
