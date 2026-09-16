/// Remembers recent command results so a retry over a dropped tunnel does not run the
/// command twice.
///
/// A phone on a tunnel retries. Without this, one retried `addPR` adds the PR twice and
/// one retried `startSession` spawns a second agent process.
public actor CommandLedger {
    private let capacity: Int
    private var order: [String] = []
    private var results: [String: GatewayCommandResult] = [:]

    public init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    public func result(for commandID: String) -> GatewayCommandResult? {
        results[commandID]
    }

    public func record(_ result: GatewayCommandResult, for commandID: String) {
        if results[commandID] == nil {
            order.append(commandID)
        }
        results[commandID] = result

        while order.count > capacity {
            let evicted = order.removeFirst()
            results.removeValue(forKey: evicted)
        }
    }
}
