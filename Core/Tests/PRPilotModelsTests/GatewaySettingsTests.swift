import Testing
import Foundation
@testable import PRPilotModels

@Test func theGatewayIsOffByDefaultOnPort8776() {
    #expect(Settings.default.gatewayEnabled == false)
    #expect(Settings.default.gatewayPort == 8776)
}

@Test func settingsStoredBeforeTheGatewayExistedStillDecode() throws {
    var object = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(Settings.default)
    ) as! [String: Any]
    object.removeValue(forKey: "gatewayEnabled")
    object.removeValue(forKey: "gatewayPort")

    let stripped = try JSONSerialization.data(withJSONObject: object)
    let recovered = try JSONDecoder().decode(Settings.self, from: stripped)

    #expect(recovered.gatewayEnabled == false)
    #expect(recovered.gatewayPort == 8776)
}

@Test func theGatewaySettingsSurviveARoundTrip() throws {
    var settings = Settings.default
    settings.gatewayEnabled = true
    settings.gatewayPort = 9001

    let data = try JSONEncoder().encode(settings)
    let recovered = try JSONDecoder().decode(Settings.self, from: data)

    #expect(recovered.gatewayEnabled)
    #expect(recovered.gatewayPort == 9001)
}
