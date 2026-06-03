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

@Test func appearanceCasesHaveDisplayNames() {
    #expect(Appearance.system.displayName == "System")
    #expect(Appearance.light.displayName == "Light")
    #expect(Appearance.dark.displayName == "Dark")
    #expect(Appearance.allCases.count == 3)
}
