import Foundation

public struct TrailSwitcher: Sendable, Equatable {
    public enum Key: Sendable {
        case tab
        case shiftTab
        case escape
        case controlReleased
    }

    public enum Outcome: Sendable, Equatable {
        case none
        case commit(itemID: String)
    }

    public private(set) var ids: [String] = []
    public private(set) var highlight: Int?

    public var isOpen: Bool { highlight != nil }

    public init() {}

    public mutating func handle(_ key: Key, trail: [String]) -> Outcome {
        guard let current = highlight else {
            open(key, trail: trail)
            return .none
        }

        switch key {
        case .tab:
            highlight = (current + 1) % ids.count
            return .none

        case .shiftTab:
            highlight = (current - 1 + ids.count) % ids.count
            return .none

        case .escape:
            close()
            return .none

        case .controlReleased:
            let chosen = ids[current]
            close()
            return current == 0 ? .none : .commit(itemID: chosen)
        }
    }

    private mutating func open(_ key: Key, trail: [String]) {
        guard trail.count >= 2 else { return }

        switch key {
        case .tab:
            ids = trail
            highlight = 1

        case .shiftTab:
            ids = trail
            highlight = trail.count - 1

        case .escape, .controlReleased:
            break
        }
    }

    private mutating func close() {
        ids = []
        highlight = nil
    }
}
