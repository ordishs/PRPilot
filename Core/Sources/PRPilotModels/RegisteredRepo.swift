public struct RegisteredRepo: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var remoteIdentity: String
    public var localClonePath: String
    public var defaultBase: String

    public init(remoteIdentity: String, localClonePath: String, defaultBase: String) {
        self.id = remoteIdentity
        self.remoteIdentity = remoteIdentity
        self.localClonePath = localClonePath
        self.defaultBase = defaultBase
    }
}
