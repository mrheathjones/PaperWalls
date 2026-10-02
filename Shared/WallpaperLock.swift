import Foundation
import os

/// Lock tiers (migration spec §1). Raw values are the `lockMode` preference
/// values. Replaces the single legacy `lockSelection` bool, which still maps
/// in via `LockMode.resolveConfigured`.
enum LockMode: String, CaseIterable, Identifiable {
    case off
    case soft
    case hard
    case enforcedRotation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .soft: return "Soft Lock"
        case .hard: return "Hard Lock"
        case .enforcedRotation: return "Enforced Rotation"
        }
    }

    /// Pure, unit-testable mapping from configured keys to a tier.
    /// An explicit `lockMode` always wins; otherwise legacy keys map:
    /// `lockSelection == true` → at least `.soft`; the historical hard-lock
    /// signal (a *forced* `allowLockExit == false`) → `.hard`.
    static func resolveConfigured(lockModeRaw: String?,
                                  lockSelection: Bool,
                                  allowLockExit: Bool,
                                  allowLockExitForced: Bool) -> LockMode {
        if let raw = lockModeRaw, let mode = LockMode(rawValue: raw) {
            return mode
        }
        guard lockSelection else { return .off }
        if allowLockExitForced && !allowLockExit {
            return .hard
        }
        return .soft
    }
}

/// Detects OS-level wallpaper restrictions deployed by an admin profile.
/// The app never installs these — it only detects and defers to them.
enum WallpaperEnforcement {
    // FUTURE: route through PaperLog multi-sink (spec §9, deferred).
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "enforcement")

    /// True when the OS itself restricts desktop-picture changes: a forced
    /// `allowWallpaperModification == false` (com.apple.applicationaccess) or
    /// a managed `com.apple.desktop` `override-picture-path`. Whether the OS
    /// restriction blocks the setDesktopImageURL API or only System Settings
    /// is UNVERIFIED per macOS version — PaperWalls treats the restriction as
    /// authoritative either way and self-refuses.
    static func osRestrictsModification() -> Bool {
        let restrictionsDomain = "com.apple.applicationaccess" as CFString
        let key = "allowWallpaperModification" as CFString
        if CFPreferencesAppValueIsForced(key, restrictionsDomain),
           let number = CFPreferencesCopyAppValue(key, restrictionsDomain) as? NSNumber,
           number.boolValue == false {
            return true
        }

        // Managed desktop override: machine-level and per-user locations.
        let candidates = [
            "/Library/Managed Preferences/com.apple.desktop.plist",
            "/Library/Managed Preferences/\(NSUserName())/com.apple.desktop.plist",
        ]
        for path in candidates {
            if let dict = NSDictionary(contentsOfFile: path),
               dict["override-picture-path"] != nil {
                return true
            }
        }
        return false
    }
}

/// The effective lock right now: configured tier + detected OS state.
/// Both the GUI and the CLI derive behavior from this — never from raw keys.
struct LockState {
    let mode: LockMode
    /// True when the OS restriction is actually present (vs app-only).
    let osEnforced: Bool

    /// The full-screen locked view replaces the library for these tiers.
    var showsLockedView: Bool { mode == .soft || mode == .hard }

    /// Set/Next/Rotate controls grey out for these tiers.
    var blocksUserSelection: Bool { mode == .soft || mode == .hard }

    /// Rotation may continue only when unlocked or under enforced rotation.
    var allowsRotation: Bool { mode == .off || mode == .enforcedRotation }

    /// "Back to Library" from the locked view (soft honors allowLockExit;
    /// hard never exits).
    func allowsExit(allowLockExit: Bool) -> Bool {
        mode == .soft && allowLockExit
    }

    /// User-facing description of who enforces the lock.
    var enforcementDescription: String {
        osEnforced
            ? "Enforced by configuration profile"
            : "App-only — deploy the lock profile to enforce at the OS level"
    }

    static func current() -> LockState {
        let osEnforced = WallpaperEnforcement.osRestrictsModification()
        var mode = LockMode.resolveConfigured(
            lockModeRaw: ManagedPreferences.string(.lockMode),
            lockSelection: ManagedPreferences.bool(.lockSelection) ?? false,
            allowLockExit: ManagedPreferences.bool(.allowLockExit) ?? true,
            allowLockExitForced: ManagedPreferences.isForced(.allowLockExit))
        // An OS restriction is authoritative over any configured tier —
        // including .enforcedRotation, which must never fight the Dock over
        // a profile-forced picture (spec §7 mutual exclusion).
        if osEnforced {
            mode = .hard
        }
        return LockState(mode: mode, osEnforced: osEnforced)
    }
}

/// The single pre-apply guard. Both GUI and CLI call this before ANY apply —
/// the app is never a bypass (spec principle #1).
enum WallpaperApplyGuard {
    /// Pure, unit-testable rule set. nil = allowed; otherwise a user-facing
    /// refusal reason. `rotationPoolIDs` is the resolved rotation pool
    /// (spec §4): under enforced rotation with no explicit allow-list, the
    /// pool IS the approved set. Callers that can't resolve the pool (CLI
    /// `set` with an arbitrary path) pass nil, which only relaxes the
    /// identified-apply case — unidentified applies are always refused
    /// under enforced rotation.
    static func refusalReason(forApplying wallpaperID: String?,
                              mode: LockMode,
                              osEnforced: Bool,
                              managedSelectionID: String?,
                              allowedIDs: [String]?,
                              rotationPoolIDs: Set<String>? = nil) -> String? {
        switch mode {
        case .off:
            return nil
        case .soft:
            if let wallpaperID, let managedSelectionID, wallpaperID == managedSelectionID {
                return nil
            }
            return "Wallpaper selection is locked by your organization."
        case .hard:
            return osEnforced
                ? "The wallpaper is enforced by a configuration profile."
                : "Wallpaper selection is locked by your organization."
        case .enforcedRotation:
            let refusal = "Only approved wallpapers can be applied on this Mac."
            guard let wallpaperID else { return refusal }
            if let allowedIDs, !allowedIDs.isEmpty {
                return allowedIDs.contains(wallpaperID) ? nil : refusal
            }
            if let rotationPoolIDs {
                return rotationPoolIDs.contains(wallpaperID) ? nil : refusal
            }
            return nil
        }
    }

    /// Convenience reading live values through the resolver.
    static func refusalReason(forApplying wallpaperID: String?,
                              lockState: LockState,
                              rotationPoolIDs: Set<String>? = nil) -> String? {
        refusalReason(forApplying: wallpaperID,
                      mode: lockState.mode,
                      osEnforced: lockState.osEnforced,
                      managedSelectionID: ManagedPreferences.string(.selectedWallpaperID),
                      allowedIDs: ManagedPreferences.stringArray(.allowedWallpaperIDs),
                      rotationPoolIDs: rotationPoolIDs)
    }
}
