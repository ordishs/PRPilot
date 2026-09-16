import Foundation
@testable import GatewayKit

@MainActor
final class FakeGatewayBackend: GatewayBackend {
    private(set) var received: [GatewayCommand] = []
    var nextStatus: GatewayCommandResult.Status = .accepted
    var nextMessage: String?
    var login: String? = "ordishs"
    var groups: [GatewayGroup] = []

    func snapshot() -> GatewaySnapshot {
        GatewaySnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_789_000_000),
            appVersion: "test",
            login: login,
            groups: groups,
            warnings: []
        )
    }

    func perform(_ command: GatewayCommand) async -> GatewayCommandResult {
        received.append(command)
        return GatewayCommandResult(status: nextStatus, message: nextMessage, snapshot: snapshot())
    }
}
