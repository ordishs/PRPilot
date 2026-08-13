import Foundation
import Observation

/// What the quit window shows while the app waits for agent processes to exit.
///
/// Quitting is not instant any more. The app signals each agent, then waits for the agent and
/// every process it started to leave the process table. Without something on screen the app looks
/// frozen for those seconds, and a user who force-quits at that moment recreates the exact leak
/// the wait exists to prevent.
@MainActor
@Observable
public final class ShutdownProgress {
    /// How many agents the quit started with. Fixed for the life of the shutdown, so the
    /// progress bar does not rescale as agents stop.
    public let total: Int

    /// Titles of the agents that have not stopped yet, in the order the quit found them.
    public private(set) var stopping: [String]

    public init(titles: [String]) {
        self.total = titles.count
        self.stopping = titles
    }

    public var remaining: Int { stopping.count }
    public var stopped: Int { total - stopping.count }
    public var isFinished: Bool { stopping.isEmpty }

    /// Fraction complete, for a determinate progress bar. A shutdown with no agents reads as done.
    public var fraction: Double {
        guard total > 0 else { return 1 }
        return Double(stopped) / Double(total)
    }

    public func markStopped(_ title: String) {
        if let index = stopping.firstIndex(of: title) {
            stopping.remove(at: index)
        }
    }
}
