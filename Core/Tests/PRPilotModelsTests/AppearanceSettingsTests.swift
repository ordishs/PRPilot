import Testing
import Foundation
@testable import PRPilotModels

@Test func appearanceDefaultsToSystemWhenAbsent() throws {
    let json = """
    {
      "managedRoot": "/tmp",
      "reviewRequestQueries": [{"text": "author:@me is:open", "allowUnscoped": false}],
      "myPRQueries": [{"text": "author:@me is:open", "allowUnscoped": false}],
      "pollIntervalSeconds": 120,
      "claudeLaunchArgs": "", "claudeEnv": "",
      "notificationsEnabled": true, "diffMode": "unified",
      "diffIgnoreWhitespace": false, "sidebarSort": "recent"
    }
    """
    let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(s.appearance == .system)
}

@Test func appearanceRoundTrips() throws {
    var s = Settings.default
    s.appearance = .light
    let data = try JSONEncoder().encode(s)
    let decoded = try JSONDecoder().decode(Settings.self, from: data)
    #expect(decoded.appearance == .light)
}

@Test func appearanceDecodesExplicitDark() throws {
    let json = """
    {
      "managedRoot": "/tmp",
      "reviewRequestQueries": [{"text": "author:@me is:open", "allowUnscoped": false}],
      "myPRQueries": [{"text": "author:@me is:open", "allowUnscoped": false}],
      "pollIntervalSeconds": 120,
      "claudeLaunchArgs": "", "claudeEnv": "",
      "notificationsEnabled": true, "diffMode": "unified",
      "diffIgnoreWhitespace": false, "sidebarSort": "recent",
      "appearance": "dark"
    }
    """
    let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(s.appearance == .dark)
}

@Test func settingsDefaultToDocumentedCaps() {
    #expect(Settings.default.maxLiveClaudeSessions == 5)
    #expect(Settings.default.maxLiveWebViews == 8)
}

@Test func settingsWithoutCapsDecodeToDefaults() throws {
    let json = """
    {
      "managedRoot": "/tmp/prpilot",
      "reviewRequestQueries": [],
      "myPRQueries": [],
      "pollIntervalSeconds": 120,
      "notificationsEnabled": true,
      "diffMode": "unified",
      "diffIgnoreWhitespace": false
    }
    """
    let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))

    #expect(decoded.maxLiveClaudeSessions == 5)
    #expect(decoded.maxLiveWebViews == 8)
}

@Test func settingsRoundTripPreservesCaps() throws {
    var settings = Settings.default
    settings.maxLiveClaudeSessions = 2
    settings.maxLiveWebViews = 3

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(Settings.self, from: encoder.encode(settings))

    #expect(decoded.maxLiveClaudeSessions == 2)
    #expect(decoded.maxLiveWebViews == 3)
}

@Test func appearanceCasesHaveDisplayNames() {
    #expect(Appearance.system.displayName == "System")
    #expect(Appearance.light.displayName == "Light")
    #expect(Appearance.dark.displayName == "Dark")
    #expect(Appearance.allCases.count == 3)
}
