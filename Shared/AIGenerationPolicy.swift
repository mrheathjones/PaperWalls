import Foundation

/// The ways a wallpaper background can be generated. Each has its own
/// sub-toggle under the master `aiGenerationEnabled` switch.
enum AIProviderKind: String, CaseIterable, Identifiable {
    case appleOnDevice
    case localModel
    case externalModel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleOnDevice: return "Apple On-Device"
        case .localModel: return "Local Model"
        case .externalModel: return "External Model"
        }
    }

    var preferenceKey: ManagedPreferenceKey {
        switch self {
        case .appleOnDevice: return .aiAppleOnDeviceEnabled
        case .localModel: return .aiLocalModelEnabled
        case .externalModel: return .aiExternalModelEnabled
        }
    }
}

/// Which generation providers may be offered (pure, so the app and tests
/// agree). Everything defaults OFF: with the master switch off, no AI
/// control appears anywhere, whatever the sub-toggles say.
struct AIGenerationPolicy: Equatable {
    /// `aiGenerationEnabled` — the master switch.
    var enabled: Bool = false
    var appleOnDevice: Bool = false
    var localModel: Bool = false
    var externalModel: Bool = false

    static let off = AIGenerationPolicy()

    /// Reads the live preference layers.
    static func current() -> AIGenerationPolicy {
        AIGenerationPolicy(enabled: ManagedPreferences.bool(.aiGenerationEnabled) ?? false,
                           appleOnDevice: ManagedPreferences.bool(.aiAppleOnDeviceEnabled) ?? false,
                           localModel: ManagedPreferences.bool(.aiLocalModelEnabled) ?? false,
                           externalModel: ManagedPreferences.bool(.aiExternalModelEnabled) ?? false)
    }

    func isEnabled(_ kind: AIProviderKind) -> Bool {
        guard enabled else { return false }
        switch kind {
        case .appleOnDevice: return appleOnDevice
        case .localModel: return localModel
        case .externalModel: return externalModel
        }
    }

    /// Providers that may be offered, in display order.
    var enabledProviders: [AIProviderKind] {
        AIProviderKind.allCases.filter(isEnabled)
    }

    /// True when at least one provider can be offered.
    var offersGeneration: Bool {
        !enabledProviders.isEmpty
    }
}
