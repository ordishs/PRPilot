import Testing
import Foundation
@testable import GatewayKit

@Test @MainActor func theServiceReportsTheTailscaleCommandForItsPort() {
    let backend = FakeGatewayBackend()
    let service = GatewayService(backend: backend, port: 8776, token: "t", appVersion: "test")

    #expect(service.tailscaleCommand == "tailscale serve --bg 8776")
}

@Test @MainActor func theServiceIsNotRunningBeforeItIsStarted() {
    let backend = FakeGatewayBackend()
    let service = GatewayService(backend: backend, port: 8776, token: "t", appVersion: "test")

    #expect(service.isRunning == false)
}

@Test @MainActor func startingThenStoppingLeavesTheServiceStopped() async throws {
    let backend = FakeGatewayBackend()
    let service = GatewayService(backend: backend, port: 0, token: "t", appVersion: "test")

    service.start()
    try await Task.sleep(for: .milliseconds(250))
    #expect(service.isRunning)

    service.stop()
    #expect(service.isRunning == false)
}

@Test @MainActor func startingTwiceDoesNotCreateASecondListener() async throws {
    let backend = FakeGatewayBackend()
    let service = GatewayService(backend: backend, port: 0, token: "t", appVersion: "test")

    service.start()
    service.start()
    try await Task.sleep(for: .milliseconds(250))
    #expect(service.isRunning)

    service.stop()
    #expect(service.isRunning == false)
}

/// Drives the assembled service over a real loopback socket, not the in-memory router, so
/// the binding, the middleware and the JSON encoding are all exercised together.
@Test @MainActor func theRunningServiceServesHealthAndSnapshotOverARealSocket() async throws {
    let port = 18_776
    let backend = FakeGatewayBackend()
    let service = GatewayService(backend: backend, port: port, token: "live-token", appVersion: "live")
    service.start()
    defer { service.stop() }

    try await Task.sleep(for: .milliseconds(400))

    let health = try await get("http://127.0.0.1:\(port)/api/health", token: nil)
    #expect(health.status == 200)
    #expect(String(decoding: health.body, as: UTF8.self).contains("\"appVersion\":\"live\""))

    let unauthorized = try await get("http://127.0.0.1:\(port)/api/snapshot", token: nil)
    #expect(unauthorized.status == 401)

    let wrong = try await get("http://127.0.0.1:\(port)/api/snapshot", token: "nope")
    #expect(wrong.status == 401)

    let ok = try await get("http://127.0.0.1:\(port)/api/snapshot", token: "live-token")
    #expect(ok.status == 200)
    let snapshot = try GatewayCoding.decoder.decode(GatewaySnapshot.self, from: ok.body)
    #expect(snapshot.login == "ordishs")
}

private func get(_ urlString: String, token: String?) async throws -> (status: Int, body: Data) {
    var request = URLRequest(url: URL(string: urlString)!)
    if let token {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as! HTTPURLResponse).statusCode, data)
}
