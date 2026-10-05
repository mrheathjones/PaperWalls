import XCTest

// MARK: - AI generation gating (Studio › Wallpapers)

final class AIGenerationPolicyTests: XCTestCase {
    func testEverythingIsOffByDefault() {
        let policy = AIGenerationPolicy()
        XCTAssertFalse(policy.enabled)
        XCTAssertFalse(policy.offersGeneration)
        XCTAssertTrue(policy.enabledProviders.isEmpty)
    }

    func testMasterSwitchGatesEverySubToggle() {
        let policy = AIGenerationPolicy(enabled: false, appleOnDevice: true, localModel: true, externalModel: true)
        XCTAssertFalse(policy.offersGeneration)
        for kind in AIProviderKind.allCases {
            XCTAssertFalse(policy.isEnabled(kind), kind.rawValue)
        }
    }

    func testMasterSwitchAloneOffersNothing() {
        let policy = AIGenerationPolicy(enabled: true)
        XCTAssertFalse(policy.offersGeneration)
    }

    func testEnabledProvidersFollowTheSubToggles() {
        let policy = AIGenerationPolicy(enabled: true, appleOnDevice: true, localModel: false, externalModel: true)
        XCTAssertEqual(policy.enabledProviders, [.appleOnDevice, .externalModel])
        XCTAssertTrue(policy.isEnabled(.appleOnDevice))
        XCTAssertFalse(policy.isEnabled(.localModel))
        XCTAssertTrue(policy.offersGeneration)
    }

    func testPromptImproverFollowsTheMasterSwitch() {
        XCTAssertFalse(AIGenerationPolicy(enabled: false, promptImprover: true).offersPromptImprovement)
        XCTAssertFalse(AIGenerationPolicy(enabled: true).offersPromptImprovement)
        XCTAssertTrue(AIGenerationPolicy(enabled: true, promptImprover: true).offersPromptImprovement)
        XCTAssertFalse(AIGenerationPolicy(enabled: true, promptImprover: true).offersGeneration,
                       "the improver alone offers no generation")
    }

    func testEachProviderHasItsOwnPreferenceKey() {
        XCTAssertEqual(Set(AIProviderKind.allCases.map(\.preferenceKey)).count, AIProviderKind.allCases.count)
        XCTAssertEqual(AIProviderKind.appleOnDevice.preferenceKey, .aiAppleOnDeviceEnabled)
    }
}
