import Testing
import Foundation
@testable import PRPilotModels

private let legacyReviewJSON = """
{
  "id": "bsv-blockchain/teranode#944",
  "owner": "bsv-blockchain", "repo": "teranode", "number": 944,
  "url": "https://github.com/bsv-blockchain/teranode/pull/944",
  "title": "centrifuge fix", "author": "icellan",
  "headBranch": "fix/centrifuge", "baseBranch": "main",
  "origin": "discovered", "prState": "open",
  "worktreePath": "/tmp/wt/bsv-blockchain-teranode-pr944",
  "claudeSessionID": "abc-123",
  "addedAt": "2021-01-01T00:00:00Z", "disabled": false, "viewedFiles": []
}
"""

@Test func legacyReviewMigratesToWorkItem() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let item = try decoder.decode(WorkItem.self, from: Data(legacyReviewJSON.utf8))
    #expect(item.repoKey == "github.com/bsv-blockchain/teranode")
    #expect(item.prRef?.owner == "bsv-blockchain")
    #expect(item.prRef?.number == 944)
    #expect(item.prRef?.url.absoluteString == "https://github.com/bsv-blockchain/teranode/pull/944")
    #expect(item.prRef?.authorLogin == "icellan")
    #expect(item.prState == .open)
    #expect(item.origin == .discovered)
    #expect(item.worktreePath == "/tmp/wt/bsv-blockchain-teranode-pr944")
    #expect(item.claudeSessionID == "abc-123")
    #expect(item.autoReview == false)
    #expect(item.id != "bsv-blockchain/teranode#944")
    #expect(UUID(uuidString: item.id) != nil)
}
