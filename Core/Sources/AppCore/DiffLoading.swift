import DiffKit
import PRPilotModels

public enum DiffLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded([DiffFile])
    case failed(String)
}

public struct DiffResult: Sendable, Equatable {
    public var worktreePath: String
    public var files: [DiffFile]

    public init(worktreePath: String, files: [DiffFile]) {
        self.worktreePath = worktreePath
        self.files = files
    }
}

public protocol DiffLoading: Sendable {
    func loadDiff(for review: WorkItem, registeredClonePath: String?) async throws -> DiffResult
}
