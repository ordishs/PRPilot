import Testing
import Hummingbird
import HummingbirdTesting
@testable import GatewayKit

@Test func hummingbirdServesAPlainRoute() async throws {
    let router = Router()
    router.get("/ping") { _, _ in "pong" }
    let app = Application(router: router)

    try await app.test(.router) { client in
        try await client.execute(uri: "/ping", method: .get) { response in
            #expect(response.status == .ok)
            #expect(String(buffer: response.body) == "pong")
        }
    }
}

// Version 2 replaced the attention groups with the Mac's sidebar sections.
@Test func gatewayVersionIsTwo() {
    #expect(GatewayVersion.current == 2)
}
