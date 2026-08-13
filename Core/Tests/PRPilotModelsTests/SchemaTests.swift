import Testing
import Foundation
@testable import PRPilotModels

@Test func schemaVersionIsThree() {
    #expect(PRPilotModels.schemaVersion == 3)
}

@Test func settingsMigratesLegacyDiscoveryQueries() throws {
    let json = """
    {
      "managedRoot": "/tmp",
      "discoveryQueries": ["review-requested:@me is:open", "assignee:@me is:open"],
      "pollIntervalSeconds": 120,
      "claudeLaunchArgs": "", "claudeEnv": "",
      "notificationsEnabled": true, "diffMode": "unified",
      "diffIgnoreWhitespace": false, "sidebarGrouping": "byCategory"
    }
    """
    let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(s.reviewRequestQueries.map(\.text) == ["review-requested:@me is:open", "assignee:@me is:open"])
    #expect(s.reviewRequestQueries.allSatisfy { !$0.allowUnscoped })
    #expect(s.myPRQueries.map(\.text) == ["author:@me is:open"])
    #expect(s.reviewRequestsEnabled == true && s.myPRsEnabled == true)
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
    let decoded = try JSONDecoder().decode(WorkItem.self, from: Data(json.utf8))
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
    let decoded = try JSONDecoder().decode(WorkItem.self, from: Data(json.utf8))
    #expect(decoded.disabled == true)
}

@Test func settingsDefaultSidebarSortIsRecent() throws {
    let s = Settings.default
    #expect(s.sidebarSort == .recent)
    #expect(s.myWorkCollapsed == false)
    #expect(s.reviewsCollapsed == false)
}

@Test func settingsDecodesWithoutSidebarSortDefaultsRecent() throws {
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
    #expect(decoded.sidebarSort == .recent)
    #expect(decoded.myWorkCollapsed == false)
    #expect(decoded.reviewsCollapsed == false)
}

@Test func settingsSessionCapKeepsItsShippedKeyAfterTheAgentRename() throws {
    // The property became `maxLiveAgentSessions` when the session layer stopped being
    // Claude-specific. The persisted key must still be `maxLiveClaudeSessions`, or every
    // existing store silently loses the user's cap and falls back to the default of 5.
    let json = """
    {
      "managedRoot": "/tmp",
      "reviewRequestQueries": [],
      "myPRQueries": [],
      "pollIntervalSeconds": 120,
      "claudeLaunchArgs": "",
      "notificationsEnabled": true,
      "diffMode": "unified",
      "diffIgnoreWhitespace": false,
      "maxLiveClaudeSessions": 9
    }
    """
    let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(decoded.maxLiveAgentSessions == 9)

    let reencoded = try JSONEncoder().encode(decoded)
    let object = try #require(
        try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
    )
    #expect(object["maxLiveClaudeSessions"] as? Int == 9)
    #expect(object["maxLiveAgentSessions"] == nil)
}

@Test func settingsMigratesLegacySidebarGroupingByStatus() throws {
    let json = """
    {
      "managedRoot": "/tmp",
      "reviewRequestQueries": [],
      "myPRQueries": [],
      "pollIntervalSeconds": 120,
      "claudeLaunchArgs": "", "claudeEnv": "",
      "notificationsEnabled": true, "diffMode": "unified",
      "diffIgnoreWhitespace": false, "sidebarGrouping": "byStatus"
    }
    """
    let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(s.sidebarSort == .byStatus)
}

@Test func settingsMigratesLegacyByCategoryToRecent() throws {
    let json = """
    {
      "managedRoot": "/tmp",
      "reviewRequestQueries": [],
      "myPRQueries": [],
      "pollIntervalSeconds": 120,
      "claudeLaunchArgs": "", "claudeEnv": "",
      "notificationsEnabled": true, "diffMode": "unified",
      "diffIgnoreWhitespace": false, "sidebarGrouping": "byCategory"
    }
    """
    let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(s.sidebarSort == .recent)
}

@Test func settingsCollapseFlagsRoundTrip() throws {
    var s = Settings.default
    s.myWorkCollapsed = true
    s.reviewsCollapsed = false
    let data = try JSONEncoder().encode(s)
    let decoded = try JSONDecoder().decode(Settings.self, from: data)
    #expect(decoded.myWorkCollapsed == true)
    #expect(decoded.reviewsCollapsed == false)
    #expect(decoded.sidebarSort == s.sidebarSort)
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
    let decoded = try JSONDecoder().decode(WorkItem.self, from: Data(json.utf8))
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
    let decoded = try JSONDecoder().decode(WorkItem.self, from: Data(json.utf8))
    #expect(decoded.viewedFiles == ["src/a.swift", "src/b.swift"])
}
