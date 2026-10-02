import AppKit
import Foundation

/// Settings → Support → "Collect Logs…": bundles everything a support tech
/// would otherwise gather by hand (see docs/ADMIN_GUIDE.md §10–11) into one
/// zip. Contents are plain text; nothing is sent anywhere — the user picks
/// where the file goes.
enum DiagnosticsCollector {
    /// Snapshot of app-side state, taken on the main actor before the
    /// (slow) command collection runs in the background.
    struct AppSnapshot {
        let libraryInfo: String
        let preferencesDump: String
    }

    @MainActor
    static func makeSnapshot(model: AppModel, prefs: PreferencesStore) -> AppSnapshot {
        var lines: [String] = []
        lines.append("== Library ==")
        lines.append("bundled: \(model.library.bundled.count)")
        lines.append("system (ready): \(model.library.system.count)  pending download: \(model.library.systemPending.count)")
        lines.append("appCurated: \(model.library.appCurated.count)")
        lines.append("orgRemote: \(model.library.orgRemote.count)")
        lines.append("managed folder: \(model.library.managed.count)  (path: \(prefs.externalWallpaperFolderPath.isEmpty ? "—" : prefs.externalWallpaperFolderPath))")
        lines.append("personal: \(model.library.personal.count)  (mode: \(prefs.personalFolderSource.rawValue), path: \(prefs.effectivePersonalFolderPath ?? "—"))")
        lines.append("")
        lines.append("== Lock / enforcement ==")
        lines.append("lock mode: \(model.lockState.mode.rawValue)  osEnforced: \(model.lockState.osEnforced)")
        lines.append(model.lockState.enforcementDescription)
        lines.append("")
        lines.append("== Rotation ==")
        lines.append("enabled: \(prefs.autoRotateEnabled)  interval: \(prefs.autoRotateIntervalMinutes)m  shuffle: \(prefs.autoRotateShuffle)  onWake: \(prefs.autoRotateOnWake)")
        lines.append("configured pool: \(prefs.rotationPool.joined(separator: ", "))  (forced: \(prefs.rotationPoolForced))")
        lines.append("resolved pool: \(model.rotationPool.count) wallpaper(s)")
        lines.append("")
        lines.append("== Current desktop picture(s) ==")
        lines.append(contentsOf: model.currentWallpaperPaths.sorted())

        var prefLines: [String] = ["== Resolved preferences (all layers; F = forced by MDM/local config) =="]
        for key in ManagedPreferenceKey.allCases {
            let value = ManagedPreferences.value(key).map { String(describing: $0) } ?? "—"
            let forced = ManagedPreferences.isForced(key) ? "  [F]" : ""
            prefLines.append("\(key.rawValue) = \(value)\(forced)")
        }

        return AppSnapshot(libraryInfo: lines.joined(separator: "\n"),
                           preferencesDump: prefLines.joined(separator: "\n"))
    }

    /// Collects everything and writes the zip. Runs off the main thread —
    /// the unified-log export alone can take ~10s.
    static func collect(snapshot: AppSnapshot, to destination: URL) throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("paperwalls-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        func write(_ name: String, _ contents: String) {
            try? contents.write(to: staging.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        // 1. Environment
        let bundleInfo = Bundle.main.infoDictionary ?? [:]
        write("info.txt", """
        PaperWalls diagnostics — \(Date())
        app version: \(bundleInfo["CFBundleShortVersionString"] ?? "?") (build \(bundleInfo["CFBundleVersion"] ?? "?"))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        cli present: \(FileManager.default.fileExists(atPath: "/usr/local/bin/paperwallscli"))
        cli version: \(run("/usr/local/bin/paperwallscli", ["version"]))
        Note: this bundle contains wallpaper file paths and app settings from
        this Mac. Review before sharing if that concerns you.
        """)

        // 2. App state + resolved settings (from the main-actor snapshot)
        write("library-state.txt", snapshot.libraryInfo)
        write("preferences.txt", snapshot.preferencesDump)

        // 3. Managed layers
        var managed = "== /Library/Managed Preferences (paperwalls plists) ==\n"
        managed += run("/bin/sh", ["-c", "ls -la '/Library/Managed Preferences/' '/Library/Managed Preferences/'*/ 2>/dev/null | grep -i paperwalls || echo none"])
        managed += "\n\n== /Library/Application Support/PaperWalls/managed.json ==\n"
        if let data = FileManager.default.contents(atPath: "\(ManagedPreferences.localConfigDirectory)/managed.json"),
           let text = String(data: data, encoding: .utf8) {
            managed += text
        } else {
            managed += "not present"
        }
        write("managed-config.txt", managed)

        // 4. LaunchAgents
        let uid = getuid()
        var agents = ""
        for label in ["com.herojoneslabs.paperwalls.manage", "com.herojoneslabs.paperwalls.watch"] {
            agents += "== launchctl print gui/\(uid)/\(label) ==\n"
            agents += run("/bin/launchctl", ["print", "gui/\(uid)/\(label)"])
            agents += "\n\n"
        }
        write("launchagents.txt", agents)

        // 5. Caches on disk
        write("caches.txt", run("/bin/sh", ["-c",
            "ls -laR \"$HOME/Library/Application Support/PaperWalls\" 2>&1"]))

        // 6. Unified log (the slow part)
        write("unified-log.txt", run("/usr/bin/log", [
            "show", "--last", "4h", "--style", "compact", "--info",
            "--predicate", "subsystem == \"\(ManagedPreferences.domain)\"",
        ]))

        // 7. Zip it up
        try? FileManager.default.removeItem(at: destination)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, destination.path]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            throw NSError(domain: "PaperWalls.Diagnostics", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't create the diagnostics archive."])
        }
    }

    /// Runs a command, returning stdout+stderr (never throws — failures
    /// become part of the diagnostics text).
    private static func run(_ launchPath: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return "(failed to run \(launchPath): \(error.localizedDescription))"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.isEmpty ? "(no output; exit \(process.terminationStatus))" : output
    }
}

extension AppModel {
    /// Settings → "Collect Logs…": pick a destination, gather, reveal.
    func collectDiagnostics() {
        guard !isCollectingDiagnostics else { return }
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        panel.nameFieldStringValue = "PaperWalls-Diagnostics-\(stamp).zip"
        panel.title = "Save Diagnostics"
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isCollectingDiagnostics = true
        let snapshot = DiagnosticsCollector.makeSnapshot(model: self, prefs: prefs)
        Task.detached(priority: .userInitiated) {
            var failure: String?
            do {
                try DiagnosticsCollector.collect(snapshot: snapshot, to: destination)
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                self?.isCollectingDiagnostics = false
                if let failure {
                    self?.errorMessage = "Couldn't collect diagnostics: \(failure)"
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            }
        }
    }
}
