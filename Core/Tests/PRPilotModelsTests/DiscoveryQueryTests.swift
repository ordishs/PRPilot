import Testing
import Foundation
@testable import PRPilotModels

@Test func discoveryQueryRoundTripsThroughCodable() throws {
    let q = DiscoveryQuery(text: "author:@me is:open", allowUnscoped: true)
    let data = try JSONEncoder().encode(q)
    #expect(try JSONDecoder().decode(DiscoveryQuery.self, from: data) == q)
}

@Test func scopedQueriesAreRecognised() {
    let scoped = [
        "author:@me is:open",
        "review-requested:@me is:open",
        "assignee:@me",
        "mentions:@me",
        "involves:ordishs",
        "commenter:@me",
        "org:bsv-blockchain is:open",
        "repo:bsv-blockchain/teranode",
        "user:ordishs is:pr",
        "is:open author:someone-else",
    ]
    for t in scoped { #expect(DiscoveryQuery.isScoped(t), "expected scoped: \(t)") }
}

@Test func unscopedQueriesAreRejected() {
    let unscoped = [
        "is:open",
        "is:pr",
        "is:open is:pr archived:false",
        "draft:false label:bug",
        "is:open language:swift created:>2024-01-01",
        "",
    ]
    for t in unscoped { #expect(!DiscoveryQuery.isScoped(t), "expected unscoped: \(t)") }
}

@Test func isScopedIsCaseInsensitive() {
    #expect(DiscoveryQuery.isScoped("AUTHOR:@me"))
    #expect(DiscoveryQuery(text: "Org:bsv", allowUnscoped: false).isScoped)
}
