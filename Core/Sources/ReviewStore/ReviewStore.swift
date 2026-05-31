import Foundation
import PRPilotModels

public actor ReviewStore {
    private let fileURL: URL
    private var state: StoreState

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        self.state = try ReviewStore.loadOrCreate(at: fileURL)
    }

    public func allReviews() -> [Review] {
        state.reviews
    }

    public func review(id: String) -> Review? {
        state.reviews.first { $0.id == id }
    }

    public func upsert(_ review: Review) throws {
        if let index = state.reviews.firstIndex(where: { $0.id == review.id }) {
            state.reviews[index] = review
        } else {
            state.reviews.append(review)
        }
        try persist()
    }

    public func removeReview(id: String) throws {
        state.reviews.removeAll { $0.id == id }
        try persist()
    }

    public func allRepos() -> [RegisteredRepo] {
        state.registeredRepos
    }

    public func repo(forRemote remoteIdentity: String) -> RegisteredRepo? {
        state.registeredRepos.first { $0.remoteIdentity == remoteIdentity }
    }

    public func upsert(_ repo: RegisteredRepo) throws {
        if let index = state.registeredRepos.firstIndex(where: { $0.id == repo.id }) {
            state.registeredRepos[index] = repo
        } else {
            state.registeredRepos.append(repo)
        }
        try persist()
    }

    public func removeRepo(id: String) throws {
        state.registeredRepos.removeAll { $0.id == id }
        try persist()
    }

    public func settings() -> Settings {
        state.settings
    }

    public func updateSettings(_ settings: Settings) throws {
        state.settings = settings
        try persist()
    }

    private func persist() throws {
        let data = try ReviewStore.makeEncoder().encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }

    private static func loadOrCreate(at url: URL) throws -> StoreState {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return try makeDecoder().decode(StoreState.self, from: data)
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let initial = StoreState(
            schemaVersion: PRPilotModels.schemaVersion,
            reviews: [],
            registeredRepos: [],
            settings: .default
        )
        let data = try makeEncoder().encode(initial)
        try data.write(to: url, options: [.atomic])
        return initial
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
