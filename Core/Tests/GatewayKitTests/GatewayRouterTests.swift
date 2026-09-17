import Testing
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
@testable import GatewayKit

private let testToken = "test-token"

@MainActor
private func makeApp(_ backend: FakeGatewayBackend) -> some ApplicationProtocol {
    Application(
        router: GatewayRouter.make(
            backend: backend,
            verifier: BearerTokenVerifier(token: testToken),
            ledger: CommandLedger(capacity: 8),
            appVersion: "test"
        )
    )
}

private let authHeaders: HTTPFields = [.authorization: "Bearer \(testToken)"]

@Test func healthNeedsNoTokenAndReportsTheVersion() async throws {
    let backend = await FakeGatewayBackend()
    let app = await makeApp(backend)

    try await app.test(.router) { client in
        try await client.execute(uri: "/api/health", method: .get) { response in
            #expect(response.status == .ok)
            let json = try JSONSerialization.jsonObject(with: Data(buffer: response.body)) as? [String: Any]
            #expect(json?["appVersion"] as? String == "test")
            #expect(json?["gatewayVersion"] as? Int == GatewayVersion.current)
        }
    }
}

@Test func theSnapshotRouteRejectsARequestWithNoToken() async throws {
    let backend = await FakeGatewayBackend()
    let app = await makeApp(backend)

    try await app.test(.router) { client in
        try await client.execute(uri: "/api/snapshot", method: .get) { response in
            #expect(response.status == .unauthorized)
        }
    }
}

@Test func theSnapshotRouteRejectsAWrongToken() async throws {
    let backend = await FakeGatewayBackend()
    let app = await makeApp(backend)

    try await app.test(.router) { client in
        try await client.execute(
            uri: "/api/snapshot",
            method: .get,
            headers: [.authorization: "Bearer wrong"]
        ) { response in
            #expect(response.status == .unauthorized)
        }
    }
}

@Test func theSnapshotRouteReturnsTheBackendSnapshot() async throws {
    let backend = await FakeGatewayBackend()
    let app = await makeApp(backend)

    try await app.test(.router) { client in
        try await client.execute(uri: "/api/snapshot", method: .get, headers: authHeaders) { response in
            #expect(response.status == .ok)
            let snapshot = try GatewayCoding.decoder.decode(GatewaySnapshot.self, from: Data(buffer: response.body))
            #expect(snapshot.login == "ordishs")
            #expect(snapshot.appVersion == "test")
        }
    }
}

@Test func aCommandReachesTheBackendAndReturnsItsResult() async throws {
    let backend = await FakeGatewayBackend()
    let app = await makeApp(backend)
    let body = #"{"commandID":"c-1","command":{"type":"refreshAll"}}"#

    try await app.test(.router) { client in
        try await client.execute(
            uri: "/api/command",
            method: .post,
            headers: authHeaders,
            body: ByteBuffer(string: body)
        ) { response in
            #expect(response.status == .ok)
            let result = try GatewayCoding.decoder.decode(GatewayCommandResult.self, from: Data(buffer: response.body))
            #expect(result.status == .accepted)
        }
    }

    #expect(await backend.received == [.refreshAll])
}

@Test func aRepeatedCommandIdDoesNotReachTheBackendASecondTime() async throws {
    let backend = await FakeGatewayBackend()
    let app = await makeApp(backend)
    let body = #"{"commandID":"c-1","command":{"type":"refreshAll"}}"#

    try await app.test(.router) { client in
        for _ in 0..<3 {
            try await client.execute(
                uri: "/api/command",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: body)
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    #expect(await backend.received.count == 1)
}

@Test func aCommandWithNoTokenIsRejectedAndNeverReachesTheBackend() async throws {
    let backend = await FakeGatewayBackend()
    let app = await makeApp(backend)
    let body = #"{"commandID":"c-1","command":{"type":"refreshAll"}}"#

    try await app.test(.router) { client in
        try await client.execute(
            uri: "/api/command",
            method: .post,
            body: ByteBuffer(string: body)
        ) { response in
            #expect(response.status == .unauthorized)
        }
    }

    #expect(await backend.received.isEmpty)
}

@Test func aGitCommandCannotBeDecodedSoItIsRejectedAsBadRequest() async throws {
    let backend = await FakeGatewayBackend()
    let app = await makeApp(backend)
    let body = #"{"commandID":"c-1","command":{"type":"push","id":"a#1"}}"#

    try await app.test(.router) { client in
        try await client.execute(
            uri: "/api/command",
            method: .post,
            headers: authHeaders,
            body: ByteBuffer(string: body)
        ) { response in
            #expect(response.status == .badRequest)
        }
    }

    #expect(await backend.received.isEmpty)
}

@Test func aRejectedCommandIsReportedAsRejectedWithItsMessage() async throws {
    let backend = await FakeGatewayBackend()
    await MainActor.run {
        backend.nextStatus = .rejected
        backend.nextMessage = "worktree is dirty"
    }
    let app = await makeApp(backend)
    let body = #"{"commandID":"c-9","command":{"type":"removeItem","id":"a#1"}}"#

    try await app.test(.router) { client in
        try await client.execute(
            uri: "/api/command",
            method: .post,
            headers: authHeaders,
            body: ByteBuffer(string: body)
        ) { response in
            #expect(response.status == .ok)
            let result = try GatewayCoding.decoder.decode(GatewayCommandResult.self, from: Data(buffer: response.body))
            #expect(result.status == .rejected)
            #expect(result.message == "worktree is dirty")
        }
    }
}

@Test func theStreamRouteAcceptsATokenInTheQueryStringBecauseEventSourceCannotSetHeaders() async throws {
    let backend = await FakeGatewayBackend()
    let broadcaster = SnapshotBroadcaster(backend: backend, interval: .seconds(3600))
    let app = await MainActor.run {
        Application(
            router: GatewayRouter.make(
                backend: backend,
                verifier: BearerTokenVerifier(token: testToken),
                ledger: CommandLedger(capacity: 8),
                appVersion: "test",
                broadcaster: broadcaster
            )
        )
    }

    // An SSE body never ends on its own, and the test client collects the whole body.
    // Shutting the broadcaster down finishes the stream so the response can complete.
    let closer = Task {
        try? await Task.sleep(for: .milliseconds(150))
        await broadcaster.shutdown()
    }

    try await app.test(.router) { client in
        try await client.execute(uri: "/api/events?token=\(testToken)", method: .get) { response in
            #expect(response.status == .ok)
            #expect(String(buffer: response.body).hasPrefix("data: "))
        }
    }

    await closer.value
}

@Test func theStreamRouteStillRejectsAWrongTokenInTheQueryString() async throws {
    let backend = await FakeGatewayBackend()
    let app = await makeApp(backend)

    try await app.test(.router) { client in
        try await client.execute(uri: "/api/events?token=wrong", method: .get) { response in
            #expect(response.status == .unauthorized)
        }
    }
}

@Test func noOtherRouteAcceptsATokenInTheQueryString() async throws {
    let backend = await FakeGatewayBackend()
    let app = await makeApp(backend)

    try await app.test(.router) { client in
        try await client.execute(uri: "/api/snapshot?token=\(testToken)", method: .get) { response in
            #expect(response.status == .unauthorized)
        }
        try await client.execute(
            uri: "/api/command?token=\(testToken)",
            method: .post,
            body: ByteBuffer(string: #"{"commandID":"q-1","command":{"type":"refreshAll"}}"#)
        ) { response in
            #expect(response.status == .unauthorized)
        }
    }

    #expect(await backend.received.isEmpty)
}
