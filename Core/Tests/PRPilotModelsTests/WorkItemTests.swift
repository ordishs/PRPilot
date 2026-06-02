import Testing
import Foundation
@testable import PRPilotModels

@Test func prRefRoundTripsThroughCodable() throws {
    let ref = PRRef(
        owner: "bsv-blockchain",
        repo: "teranode",
        number: 944,
        url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!,
        authorLogin: "icellan"
    )
    let data = try JSONEncoder().encode(ref)
    let decoded = try JSONDecoder().decode(PRRef.self, from: data)
    #expect(decoded == ref)
    #expect(decoded.authorLogin == "icellan")
}
