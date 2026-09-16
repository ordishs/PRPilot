import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

struct GatewayAuthMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext

    let verifier: any IdentityVerifier

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        var lowered: [String: String] = [:]
        for field in request.headers {
            lowered[field.name.canonicalName.lowercased()] = field.value
        }

        guard verifier.verify(headers: lowered) != nil else {
            throw HTTPError(.unauthorized)
        }
        return try await next(request, context)
    }
}

public enum GatewayRouter {
    public static func make(
        backend: any GatewayBackend,
        verifier: any IdentityVerifier,
        ledger: CommandLedger,
        appVersion: String
    ) -> Router<BasicRequestContext> {
        let router = Router()
        let encoder = GatewayCoding.encoder
        let decoder = GatewayCoding.decoder

        // Health carries no state and no secret. It exists to tell you the tunnel is up
        // before you have pasted a token in.
        router.get("/api/health") { _, _ -> Response in
            let payload: [String: Any] = [
                "gatewayVersion": GatewayVersion.current,
                "appVersion": appVersion,
            ]
            return json(try JSONSerialization.data(withJSONObject: payload))
        }

        let guarded = router.group("/api").add(middleware: GatewayAuthMiddleware(verifier: verifier))

        guarded.get("/snapshot") { _, _ -> Response in
            let snapshot = await MainActor.run { backend.snapshot() }
            return json(try encoder.encode(snapshot))
        }

        guarded.post("/command") { request, _ -> Response in
            var request = request
            let body = try await request.collectBody(upTo: 64 * 1024)

            let envelope: GatewayCommandEnvelope
            do {
                envelope = try decoder.decode(GatewayCommandEnvelope.self, from: Data(buffer: body))
            } catch {
                throw HTTPError(.badRequest, message: "\(error)")
            }

            if let cached = await ledger.result(for: envelope.commandID) {
                return json(try encoder.encode(cached))
            }

            let result = await backend.perform(envelope.command)
            await ledger.record(result, for: envelope.commandID)
            return json(try encoder.encode(result))
        }

        return router
    }

    static func json(_ data: Data) -> Response {
        Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }
}
