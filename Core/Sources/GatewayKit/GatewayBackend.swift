/// What the gateway needs from the app, and nothing more.
///
/// `AppCore` conforms `AppModel` to this. The dependency flows `AppCore -> GatewayKit`, so
/// every route in this module is testable against a fake with no `AppModel`, no `gh` and
/// no git.
@MainActor
public protocol GatewayBackend: AnyObject, Sendable {
    func snapshot() -> GatewaySnapshot
    func perform(_ command: GatewayCommand) async -> GatewayCommandResult
    /// The recent conversation for one item. Separate from the snapshot because a
    /// transcript is far larger than the queue and is only wanted for the open item.
    func transcript(for id: String, limit: Int) -> GatewayTranscript
}
