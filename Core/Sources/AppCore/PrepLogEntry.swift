import Foundation

public struct PrepLogEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let date: Date
    public let message: String

    public init(id: UUID = UUID(), date: Date, message: String) {
        self.id = id
        self.date = date
        self.message = message
    }
}
