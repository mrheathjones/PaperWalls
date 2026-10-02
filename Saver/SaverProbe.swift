#if DEBUG
import AppKit
import SystemConfiguration
import os

/// DEBUG BUILDS ONLY (spec §10) — never compiled into a release saver.
///
/// The saver's design rests on what the sandboxed host can read; this is
/// how that was established, and how to re-check it on another macOS
/// version: install a Debug build of the saver, preview it, then read the
/// report from the log (`log show --predicate 'category == "saverprobe"'`).
///
/// Records what the saver can actually see from inside the system's
/// legacyScreenSaver host: where "home" resolves, which PaperWalls folders
/// and files are readable, and which preference layers are visible. The
/// answers are logged (category "saverprobe") and written to
/// `saver-probe.json`; the log line names the file's real location.
///
/// Preference VALUES are never recorded — only whether a key is visible
/// and its type — so a probe report is safe to share.
enum SaverProbe {
    static let log = Logger(subsystem: ManagedPreferences.domain, category: "saverprobe")

    private static let lock = NSLock()
    private static var events: [String] = []
    private static var hasRun = false

    /// Lifecycle breadcrumb (init / startAnimation / stopAnimation / …).
    static func event(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        lock.lock()
        events.append("\(stamp) \(message)")
        lock.unlock()
        log.notice("event: \(message, privacy: .public)")
    }

    /// Runs the probe once per host process, off the main thread.
    static func runOnce(bundle: Bundle, screen: NSScreen?) {
        lock.lock()
        let shouldRun = !hasRun
        hasRun = true
        lock.unlock()
        guard shouldRun else { return }

        // AppKit lookups happen here, on the main thread.
        let desktopURL = screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ManagedPreferences.domain)
        DispatchQueue.global(qos: .utility).async {
            let report = makeReport(bundle: bundle, desktopURL: desktopURL, appURL: appURL)
            write(report)
        }
    }

    // MARK: - Report

    private static var realHome: String {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return "" }
        return String(cString: directory)
    }

    private static func makeReport(bundle: Bundle, desktopURL: URL?, appURL: URL?) -> [String: Any] {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        let real = realHome
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? ""
        let appResources = "/Applications/\(guiAppName)/Contents/Resources/Wallpapers"

        var report: [String: Any] = [:]
        report["process"] = [
            "name": ProcessInfo.processInfo.processName,
            "mainBundleID": Bundle.main.bundleIdentifier ?? "",
            "mainBundlePath": Bundle.main.bundlePath,
            "saverBundlePath": bundle.bundlePath,
            "sandboxContainerID": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
        ]

        // Q1: does ~/Library/Application Support resolve to the container?
        report["paths"] = [
            "NSHomeDirectory": home,
            "realHome": real,
            "homeIsContainer": home != real,
            "applicationSupport": appSupport,
        ]

        // Q1: what can be read?
        var access: [String: Any] = [:]
        access["appBundleCatalog"] = probeFile("\(appResources)/catalog.json")
        access["appBundleWallpapers"] = probeDirectory(appResources)
        access["appBundleImageDecodes"] = firstImageDecodes(inDirectory: appResources)
        // The app wherever LaunchServices finds it (it may not live in
        // /Applications on a development Mac).
        if let appURL {
            let resources = appURL.appendingPathComponent("Contents/Resources/Wallpapers").path
            var result = probeFile("\(resources)/catalog.json")
            result["inApplications"] = appURL.path.hasPrefix("/Applications/")
            result["imageDecodes"] = firstImageDecodes(inDirectory: resources)["decodes"] ?? false
            access["appViaLaunchServices"] = result
        } else {
            access["appViaLaunchServices"] = ["exists": false, "error": "LaunchServices lookup returned nil"]
        }
        access["personalFolderRealHome"] = probeDirectory("\(real)/Library/Application Support/PaperWalls/Personal")
        access["paperWallsSupportRealHome"] = probeDirectory("\(real)/Library/Application Support/PaperWalls")
        access["paperWallsSupportContainer"] = probeDirectory("\(home)/Library/Application Support/PaperWalls")
        access["localConfigDirectory"] = probeDirectory(ManagedPreferences.localConfigDirectory)
        access["localConfigFile"] = probeFile("\(ManagedPreferences.localConfigDirectory)/managed.json")
        access["systemDesktopPictures"] = probeDirectory("/System/Library/Desktop Pictures")
        access["userPreferencesPlistRealHome"] = probeFile("\(real)/Library/Preferences/\(ManagedPreferences.domain).plist")
        access["managedPreferencesPlist"] = probeFile("/Library/Managed Preferences/\(ManagedPreferences.domain).plist")
        if let managedFolder = ManagedPreferences.string(.externalWallpaperFolderPath), !managedFolder.isEmpty {
            var result = probeDirectory((managedFolder as NSString).expandingTildeInPath)
            result["configured"] = true
            access["managedFolder"] = result
        } else {
            access["managedFolder"] = ["configured": false]
        }
        if let desktopURL {
            var result = probeFile(desktopURL.path)
            result["decodes"] = SceneImageLoader.downsampledImage(at: desktopURL, maxPixelSize: 256) != nil
            result["pathExtension"] = desktopURL.pathExtension
            access["currentDesktopPicture"] = result
        } else {
            access["currentDesktopPicture"] = ["exists": false, "error": "desktopImageURL returned nil"]
        }
        report["access"] = access

        // Q1: where can the saver write?
        report["write"] = [
            "containerSupport": probeWrite(directory: "\(home)/Library/Application Support/PaperWalls"),
            "realHomeSupport": probeWrite(directory: "\(real)/Library/Application Support/PaperWalls"),
        ]

        // Q2: which preference layers are visible for our domain?
        report["preferences"] = preferencesReport()

        // Local admin config as the shared resolver sees it (counts only).
        ManagedPreferences.invalidateLocalConfigCache()
        let localConfig = ManagedPreferences.localConfig
        report["localConfig"] = [
            "forcedKeyCount": localConfig.forced.count,
            "defaultsKeyCount": localConfig.defaults.count,
            "companyNameResolves": ManagedPreferences.string(.companyName) != nil,
            "companyNameForced": ManagedPreferences.isForced(.companyName),
        ]

        report["computerName"] = ["readable": (SCDynamicStoreCopyComputerName(nil, nil) as String?) != nil]

        lock.lock()
        report["events"] = events
        lock.unlock()
        return report
    }

    private static let guiAppName = "PaperWalls.app"

    private static func preferencesReport() -> [String: Any] {
        let domain = ManagedPreferences.domain as CFString
        var keys: [String: Any] = [:]
        var visibleViaAppValue = 0
        var visibleInUserLayer = 0
        var forced = 0
        for key in ManagedPreferenceKey.allCases {
            let name = key.rawValue as CFString
            let appValue = CFPreferencesCopyAppValue(name, domain)
            let userValue = CFPreferencesCopyValue(name, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            let isForced = CFPreferencesAppValueIsForced(name, domain)
            if appValue != nil { visibleViaAppValue += 1 }
            if userValue != nil { visibleInUserLayer += 1 }
            if isForced { forced += 1 }
            guard appValue != nil || userValue != nil || isForced else { continue }
            keys[key.rawValue] = [
                "appValueType": appValue.map { String(describing: type(of: $0)) } ?? "nil",
                "userLayerType": userValue.map { String(describing: type(of: $0)) } ?? "nil",
                "forced": isForced,
                "resolverSeesIt": ManagedPreferences.value(key) != nil,
            ]
        }
        let userLayerKeyList = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        return [
            "visibleViaAppValue": visibleViaAppValue,
            "visibleInUserLayer": visibleInUserLayer,
            "forcedCount": forced,
            "userLayerKeyCount": userLayerKeyList?.count ?? 0,
            "keys": keys,
        ]
    }

    // MARK: - Probes

    private static func probeDirectory(_ path: String) -> [String: Any] {
        var isDirectory: ObjCBool = false
        var result: [String: Any] = ["exists": FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)]
        do {
            result["entryCount"] = try FileManager.default.contentsOfDirectory(atPath: path).count
            result["listable"] = true
        } catch {
            result["listable"] = false
            result["error"] = describe(error)
        }
        return result
    }

    private static func probeFile(_ path: String) -> [String: Any] {
        var result: [String: Any] = ["exists": FileManager.default.fileExists(atPath: path)]
        do {
            result["bytes"] = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe).count
            result["readable"] = true
        } catch {
            result["readable"] = false
            result["error"] = describe(error)
        }
        return result
    }

    private static func probeWrite(directory: String) -> [String: Any] {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(".saver-probe-write-test")
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try Data("probe".utf8).write(to: url, options: .atomic)
            try? FileManager.default.removeItem(at: url)
            return ["writable": true]
        } catch {
            return ["writable": false, "error": describe(error)]
        }
    }

    private static func firstImageDecodes(inDirectory path: String) -> [String: Any] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        guard let name = names.sorted().first(where: { ["png", "jpg", "jpeg", "heic"].contains(($0 as NSString).pathExtension.lowercased()) }) else {
            return ["decodes": false, "error": "no image found"]
        }
        let url = URL(fileURLWithPath: path).appendingPathComponent(name)
        return ["decodes": SceneImageLoader.downsampledImage(at: url, maxPixelSize: 256) != nil]
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }

    // MARK: - Output

    private static func write(_ report: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: report,
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            log.error("probe report is not serializable")
            return
        }
        // The host's container is private to it, so the log carries the
        // full report too (one line per entry keeps under the log's size cap).
        if let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                log.notice("report: \(String(line), privacy: .public)")
            }
        }
        let directories = ["\(NSHomeDirectory())/Library/Application Support/PaperWalls", NSTemporaryDirectory()]
        for directory in directories {
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("saver-probe.json")
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                // The real (un-redirected) path, so it can be found from outside the sandbox.
                log.notice("probe report written: \(url.resolvingSymlinksInPath().path, privacy: .public)")
                return
            } catch {
                log.error("probe report not written to \(directory, privacy: .public): \(describe(error), privacy: .public)")
            }
        }
    }
}
#endif
