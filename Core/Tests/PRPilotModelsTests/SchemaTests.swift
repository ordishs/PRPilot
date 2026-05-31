import Testing
import Foundation
@testable import PRPilotModels

@Test func schemaVersionIsOne() {
    #expect(PRPilotModels.schemaVersion == 1)
}

@Test func reviewDefaultsDisabledToFalse() throws {
    let json = """
    {
      "id": "owner/repo#1",
      "owner": "owner",
      "repo": "repo",
      "number": 1,
      "url": "https://github.com/owner/repo/pull/1",
      "title": "test",
      "author": "alice",
      "headBranch": "feature",
      "baseBranch": "main",
      "origin": "added",
      "prState": "open",
      "addedAt": 700000000.0
    }
    """
    let decoded = try JSONDecoder().decode(Review.self, from: Data(json.utf8))
    #expect(decoded.disabled == false)
}

@Test func reviewDecodesPersistedDisabledTrue() throws {
    let json = """
    {
      "id": "owner/repo#1",
      "owner": "owner",
      "repo": "repo",
      "number": 1,
      "url": "https://github.com/owner/repo/pull/1",
      "title": "test",
      "author": "alice",
      "headBranch": "feature",
      "baseBranch": "main",
      "origin": "added",
      "prState": "open",
      "addedAt": 700000000.0,
      "disabled": true
    }
    """
    let decoded = try JSONDecoder().decode(Review.self, from: Data(json.utf8))
    #expect(decoded.disabled == true)
}

@Test func settingsDefaultsSidebarGroupingToByDate() throws {
    let s = Settings.default
    #expect(s.sidebarGrouping == .byDate)
}

@Test func settingsDecodesPersistedSettingsWithoutSidebarGrouping() throws {
    let json = """
    {
      "managedRoot": "/tmp",
      "discoveryQueries": ["review-requested:@me is:open"],
      "pollIntervalSeconds": 120,
      "claudeLaunchArgs": [],
      "notificationsEnabled": true,
      "diffMode": "unified",
      "diffIgnoreWhitespace": false
    }
    """
    let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(decoded.sidebarGrouping == .none)
}

@Test func reviewDefaultsViewedFilesToEmpty() throws {
    let json = """
    {
      "id": "owner/repo#1",
      "owner": "owner",
      "repo": "repo",
      "number": 1,
      "url": "https://github.com/owner/repo/pull/1",
      "title": "test",
      "author": "alice",
      "headBranch": "feature",
      "baseBranch": "main",
      "origin": "added",
      "prState": "open",
      "addedAt": 700000000.0
    }
    """
    let decoded = try JSONDecoder().decode(Review.self, from: Data(json.utf8))
    #expect(decoded.viewedFiles.isEmpty)
}

@Test func reviewDecodesPersistedViewedFiles() throws {
    let json = """
    {
      "id": "owner/repo#1",
      "owner": "owner",
      "repo": "repo",
      "number": 1,
      "url": "https://github.com/owner/repo/pull/1",
      "title": "test",
      "author": "alice",
      "headBranch": "feature",
      "baseBranch": "main",
      "origin": "added",
      "prState": "open",
      "addedAt": 700000000.0,
      "viewedFiles": ["src/a.swift", "src/b.swift"]
    }
    """
    let decoded = try JSONDecoder().decode(Review.self, from: Data(json.utf8))
    #expect(decoded.viewedFiles == ["src/a.swift", "src/b.swift"])
}
