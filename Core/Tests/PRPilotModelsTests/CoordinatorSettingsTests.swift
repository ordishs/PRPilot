import Testing
import Foundation
@testable import PRPilotModels

@Test func autoIsOffByDefault() {
    #expect(Settings.default.coordinatorAuto == false)
}

@Test func settingsStoredBeforeTheCoordinatorExistedStillDecode() throws {
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings.default)) as! [String: Any]

    for key in ["coordinatorAuto", "ciFixPromptTemplate", "changesFixPromptTemplate", "conflictFixPromptTemplate", "coordinatorPromptTemplate"] {
        #expect(object.removeValue(forKey: key) != nil)
    }

    let recovered = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(recovered.coordinatorAuto == false)
    #expect(recovered.ciFixPromptTemplate == Settings.defaultCIFixPromptTemplate)
    #expect(recovered.changesFixPromptTemplate == Settings.defaultChangesFixPromptTemplate)
    #expect(recovered.conflictFixPromptTemplate == Settings.defaultConflictFixPromptTemplate)
    #expect(recovered.coordinatorPromptTemplate == Settings.defaultCoordinatorPromptTemplate)
}

@Test func coordinatorSettingsSurviveARoundTrip() throws {
    var settings = Settings.default
    settings.coordinatorAuto = true
    settings.ciFixPromptTemplate = "custom {checks}"

    let recovered = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))

    #expect(recovered.coordinatorAuto == true)
    #expect(recovered.ciFixPromptTemplate == "custom {checks}")
}

@Test func defaultFixPromptsForbidMergingAndPostingAndPushSafely() {
    let fixes = [
        Settings.defaultCIFixPromptTemplate,
        Settings.defaultChangesFixPromptTemplate,
        Settings.defaultConflictFixPromptTemplate,
    ]

    for prompt in fixes {
        let text = prompt.lowercased()

        #expect(text.contains("git push --force-with-lease"))
        #expect(text.contains("do not merge"))
        #expect(text.contains("do not post a review or a comment"))
        #expect(text.contains("drafts"))
    }
}

@Test func defaultFixPromptsUseTheNewPlaceholders() {
    #expect(Settings.defaultCIFixPromptTemplate.contains("{checks}"))
    #expect(Settings.defaultConflictFixPromptTemplate.contains("{base}"))
}

@Test func defaultCoordinatorPromptForbidsMergingPostingAndPushing() {
    let text = Settings.defaultCoordinatorPromptTemplate.lowercased()

    #expect(text.contains("state.json"))
    #expect(text.contains("never merge"))
    #expect(text.contains("never post"))
    #expect(text.contains("never push"))
}
