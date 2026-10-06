import AppKit
import Foundation

// paperwallscli — desktoppr-style CLI for the PaperWalls wallpaper manager.
//
// Exit codes (script-friendly):
//   0  success
//   1  usage error / unknown command
//   2  invalid or missing image file
//   3  no such screen / no displays available
//   4  setting the wallpaper failed
//   5  refused to run as root
//   6  wallpaper selection is locked (lockSelection)

let toolName = "paperwallscli"
/// The version stamped into the binary's embedded Info.plist at build
/// time — the same MARKETING_VERSION as the app and the pkg.
let toolVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

enum ExitCode {
    static let ok: Int32 = 0
    static let usage: Int32 = 1
    static let invalidFile: Int32 = 2
    static let noSuchScreen: Int32 = 3
    static let applyFailed: Int32 = 4
    static let refusedRoot: Int32 = 5
    static let selectionLocked: Int32 = 6
}

func stderrPrint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String, code: Int32) -> Never {
    stderrPrint("\(toolName): \(message)")
    exit(code)
}

func printUsage(toStandardError: Bool) {
    let usage = """
    \(toolName) \(toolVersion) — manage the desktop picture (desktoppr-compatible verbs)

    USAGE:
      \(toolName) get [screen-index]
          Print the current desktop picture path for every screen, or for
          the given zero-based screen index.

      \(toolName) set <path> [screen-index] [--scale fill|fit|stretch|center] [--color RRGGBB] [--all-screens]
          Set the desktop picture. Applies to all screens unless a
          screen index is given. --all-screens forces all screens.

      \(toolName) manage
          Read managed/user preferences from the \(ManagedPreferences.domain)
          domain and apply them. Intended to be run by a LaunchAgent.

      \(toolName) watch [--interval seconds]
          Long-running desktop watcher (Tier 3). Under
          lockMode=enforcedRotation, reverts any out-of-pool desktop picture
          to an approved wallpaper. Idles in every other mode. Intended to be
          run by the watch LaunchAgent; default interval 15s.

      \(toolName) screensaver
          Print what the PaperWalls screen saver is set to show, which
          saver macOS has selected, and whether macOS's own clock is shown
          over it (read-only).

      \(toolName) screensaver enforce
          Select the saver in enforcedScreenSaverPath for every Space and
          display now, and apply hideSystemSaverClock (manage also does
          both). Run as the logged-in user. Run as root (sudo, a Jamf
          policy, the pkg postinstall) it applies only the lock screen half
          of the clock policy, which is system-level, for the console user.

      \(toolName) version
      \(toolName) help

    EXIT CODES:
      0 success, 1 usage, 2 bad file, 3 bad screen, 4 set failed,
      5 ran as root, 6 selection locked by policy

    NOTE: run as the logged-in user. The desktop picture is a per-user,
    per-session setting; running as root will not work.
    """
    if toStandardError {
        stderrPrint(usage)
    } else {
        print(usage)
    }
}

func parseScreenList(indexArgument: String?) -> [NSScreen] {
    let screens = NSScreen.screens
    guard !screens.isEmpty else {
        fail(WallpaperError.noScreens.localizedDescription, code: ExitCode.noSuchScreen)
    }
    guard let indexArgument else { return screens }
    guard let index = Int(indexArgument) else {
        fail("screen index must be a number, got '\(indexArgument)'", code: ExitCode.usage)
    }
    guard screens.indices.contains(index) else {
        fail("no display at index \(index) (\(screens.count) display(s) attached)", code: ExitCode.noSuchScreen)
    }
    return [screens[index]]
}

func runGet(_ arguments: [String]) -> Never {
    guard arguments.count <= 1 else {
        fail("get takes at most one argument (a screen index)", code: ExitCode.usage)
    }
    let screens = parseScreenList(indexArgument: arguments.first)
    for screen in screens {
        print(WallpaperEngine.currentWallpaperURL(for: screen)?.path ?? "")
    }
    exit(ExitCode.ok)
}

func runSet(_ arguments: [String]) -> Never {
    var scale = WallpaperScale.fill
    var fillColor: NSColor?
    var allScreens = false
    var positional: [String] = []

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--scale":
            index += 1
            guard index < arguments.count, let parsed = WallpaperScale(rawValue: arguments[index]) else {
                fail("--scale requires one of: fill, fit, stretch, center", code: ExitCode.usage)
            }
            scale = parsed
        case "--color":
            index += 1
            guard index < arguments.count, let parsed = NSColor(hexString: arguments[index]) else {
                fail("--color requires a 6-digit hex value, e.g. 1D2E3F", code: ExitCode.usage)
            }
            fillColor = parsed
        case "--all-screens":
            allScreens = true
        default:
            guard !argument.hasPrefix("--") else {
                fail("unknown option '\(argument)'", code: ExitCode.usage)
            }
            positional.append(argument)
        }
        index += 1
    }

    guard let pathArgument = positional.first, positional.count <= 2 else {
        fail("usage: \(toolName) set <path> [screen-index] [--scale ...] [--color ...] [--all-screens]",
             code: ExitCode.usage)
    }

    // Shared pre-apply guard (spec §1) — the CLI is never a bypass. Arbitrary
    // paths have no wallpaper ID, so any restrictive tier refuses them.
    if let refusal = WallpaperApplyGuard.refusalReason(forApplying: nil,
                                                       lockState: LockState.current()) {
        fail("\(refusal) Use '\(toolName) manage'.", code: ExitCode.selectionLocked)
    }

    let url = URL(fileURLWithPath: (pathArgument as NSString).expandingTildeInPath).standardizedFileURL
    let screenIndexArgument = allScreens ? nil : (positional.count == 2 ? positional[1] : nil)
    let screens = parseScreenList(indexArgument: screenIndexArgument)

    applyOrExit(url: url, screens: screens, scale: scale, fillColor: fillColor)
    print("set \(url.path) on \(screens.count) display(s)")
    exit(ExitCode.ok)
}

/// Everything the CLI can see: bundled + folders + the app's last-good
/// verified feed caches. The CLI NEVER syncs feeds — network stays in the
/// app (spec §4).
func loadFullLibrary() -> WallpaperLibrary {
    var library = WallpaperCatalog.load(
        managedFolderPath: ManagedPreferences.string(.externalWallpaperFolderPath),
        personalFolderPath: PersonalFolder.effectivePathFromPreferences(),
        includeSystemWallpapers: ManagedPreferences.bool(.showSystemWallpapers) ?? true)
    if ManagedPreferences.bool(.appCuratedEnabled) == true {
        let cached = RemoteCatalog.loadCached(feed: .appCurated)
        library.appCurated = cached.wallpapers
        library.appCuratedFolderURL = cached.folderURL
    }
    if ManagedPreferences.bool(.orgCatalogEnabled) == true,
       let orgFeed = RemoteFeed.org(urlString: ManagedPreferences.string(.orgCatalogURL),
                                    publicKeyBase64: ManagedPreferences.string(.orgCatalogPublicKey)) {
        let cached = RemoteCatalog.loadCached(feed: orgFeed)
        library.orgRemote = cached.wallpapers
        library.orgRemoteFolderURL = cached.folderURL
    }
    return library
}

// MARK: - screen saver (spec §10)

/// Resolves the screen saver policy and publishes the outcome for the
/// saver to read. The saver's sandbox hides this domain's preferences from
/// it, so `manage` keeps the snapshot current on Macs where the app is
/// never opened (MDM-only deployments).
func publishScreenSaverSnapshot(library: WallpaperLibrary, lockMode: LockMode) {
    let snapshot = ScreenSaverSnapshot.makeFromPreferences(library: library, lockMode: lockMode)
    do {
        if try snapshot.write() {
            print("\(toolName): screen saver → \(describe(snapshot))")
        }
    } catch {
        stderrPrint("\(toolName): could not publish the screen saver snapshot: \(error.localizedDescription)")
    }
}

func describe(_ snapshot: ScreenSaverSnapshot) -> String {
    switch snapshot.state {
    case .active: return "'\(snapshot.sceneName ?? "")' (\(snapshot.sceneID ?? ""))"
    case .noneSelected: return "none selected (built-in default)"
    case .disabled: return "disabled (solid color)"
    case .hardLock: return "hard lock (solid color)"
    }
}

/// `screensaver enforce`: apply enforcedScreenSaverPath now, with an exit
/// code a Jamf policy can act on.
func runScreenSaverEnforce() -> Never {
    // The store and the saver clock are per user; as root this would edit
    // root's. Root is what the lock screen half needs, though — so as root
    // do only that, judging the scene by the console user's.
    if getuid() == 0 {
        let console = consoleUser()
        let applied = SystemSaverClock.applyFromPreferences(saverStore: nil, home: console.home, user: console.name)
        print("running as root: the screen saver selection and the saver clock are per user — run as the user for those")
        if let name = console.name {
            print("lock screen clock policy read for console user \(name): \(applied.policy.rawValue)")
        } else {
            print("no console user found; only MDM / managed.json policy applies")
        }
        reportClock(applied.lockScreen, half: "on the lock screen",
                    policy: SystemSaverClock.lockScreenPolicy(applied.policy,
                                                              coversLockScreen: SystemSaverClock.coversLockScreen(forUser: console.name)))
        exit(ExitCode.ok)
    }
    let path = (ManagedPreferences.string(.enforcedScreenSaverPath) ?? "").trimmingCharacters(in: .whitespaces)
    guard !path.isEmpty else {
        fail("enforcedScreenSaverPath isn't set in \(ManagedPreferences.domain)", code: ExitCode.usage)
    }
    guard FileManager.default.fileExists(atPath: path) else {
        fail("enforcedScreenSaverPath '\(path)' isn't installed", code: ExitCode.invalidFile)
    }
    do {
        switch try ScreenSaverSelection.enforce(path) {
        case .alreadyEnforced:
            print("\(path) is already selected everywhere")
        case .enforced(let changed):
            print("selected \(path) (\(changed) Space/display entr\(changed == 1 ? "y" : "ies") updated)")
        }
    } catch {
        fail("could not enforce the screen saver selection: \(error.localizedDescription)", code: ExitCode.applyFailed)
    }
    applySystemSaverClockPolicy()
    exit(ExitCode.ok)
}

/// `hideSystemSaverClock`: hide (or restore) macOS's large clock over the
/// saver and on the lock screen — see `SystemSaverClock`. Quiet unless
/// something changed or is owed.
func applySystemSaverClockPolicy() {
    let applied = SystemSaverClock.applyFromPreferences()
    if let saver = applied.saver {
        reportClock(saver, half: "over the screen saver", policy: applied.policy)
    }
    reportLockScreenClock(applied)
}

func reportLockScreenClock(_ applied: SystemSaverClock.Applied) {
    reportClock(applied.lockScreen, half: "on the lock screen",
                policy: SystemSaverClock.lockScreenPolicy(applied.policy, coversLockScreen: SystemSaverClock.coversLockScreen))
}

func reportClock(_ outcome: SystemSaverClock.Outcome, half: String, policy: SystemSaverClockPolicy) {
    switch outcome {
    case .hidden:
        print("\(toolName): macOS clock \(half) → hidden (hideSystemSaverClock = \(policy.rawValue))")
    case .restored(let previous):
        print("\(toolName): macOS clock \(half) → restored to \(SystemSaverClock.restoreToken(for: previous))")
    case .managedByProfile where policy != .never:
        print("\(toolName): macOS clock \(half) is forced by a configuration profile; hideSystemSaverClock not applied")
    case .needsAdmin:
        print("\(toolName): macOS clock \(half) needs an administrator: run 'sudo \(toolName) screensaver enforce'")
    case .managedByProfile, .alreadyHidden, .leftAlone:
        break
    }
}

/// The console user, for root runs: their preferences hold the policy and
/// their wallpaper store and published snapshot say which scene is on screen.
func consoleUser() -> (name: String?, home: URL) {
    if let name = (try? FileManager.default.attributesOfItem(atPath: "/dev/console"))?[.ownerAccountName] as? String,
       !["root", "loginwindow", "_mbsetupuser"].contains(name),
       let entry = getpwnam(name), let directory = entry.pointee.pw_dir {
        return (name, URL(fileURLWithPath: String(cString: directory), isDirectory: true))
    }
    return (nil, ScreenSaverSnapshot.realHomeDirectory)
}

/// Which saver macOS has selected (macOS 14+ wallpaper store), and whether
/// it matches `enforcedScreenSaverPath`.
func printScreenSaverSelection() {
    let enforced = (ManagedPreferences.string(.enforcedScreenSaverPath) ?? "").trimmingCharacters(in: .whitespaces)
    do {
        let store = try ScreenSaverSelection.readStore()
        let entries = try ScreenSaverSelection.idleEntries(in: store)
        var counts: [String: Int] = [:]
        for entry in entries {
            counts[entry.saverPath ?? entry.provider ?? "none", default: 0] += 1
        }
        for (selection, count) in counts.sorted(by: { $0.value > $1.value }) {
            print("selected: \(selection) (\(count) of \(entries.count) Space/display entries)")
        }
        if !enforced.isEmpty {
            let inEffect = try ScreenSaverSelection.isEnforced(enforced, in: store)
            print("enforced: \(enforced) — \(inEffect ? "in effect" : "not yet; run '\(toolName) manage'")")
        }
    } catch {
        print("selected: unknown (\(error.localizedDescription))")
        if !enforced.isEmpty {
            print("enforced: \(enforced)")
        }
    }
}

/// `enforcedScreenSaverPath`: keep that saver selected for every Space and
/// display (see `ScreenSaverSelection`). Users can pick another saver in
/// System Settings; the next run (login, hourly) switches it back.
func enforceScreenSaverSelection() {
    let path = (ManagedPreferences.string(.enforcedScreenSaverPath) ?? "").trimmingCharacters(in: .whitespaces)
    guard !path.isEmpty else { return }
    guard FileManager.default.fileExists(atPath: path) else {
        stderrPrint("\(toolName): enforcedScreenSaverPath '\(path)' isn't installed; screen saver selection left unchanged")
        return
    }
    do {
        if case .enforced(let changed) = try ScreenSaverSelection.enforce(path) {
            print("\(toolName): screen saver selection → \(path) (\(changed) Space/display entr\(changed == 1 ? "y" : "ies") updated)")
        }
    } catch {
        stderrPrint("\(toolName): could not enforce the screen saver selection: \(error.localizedDescription)")
    }
}

/// Read-only: what the saver would show for the current preferences, and
/// whether the published snapshot matches.
func runScreenSaver() -> Never {
    let resolved = ScreenSaverSnapshot.makeFromPreferences(library: loadFullLibrary(),
                                                           lockMode: LockState.current().mode)
    print("state: \(resolved.state.rawValue)")
    print("active: \(describe(resolved))")
    if let published = ScreenSaverSnapshot.read() {
        print("published: \(published.hasSameContent(as: resolved) ? "up to date" : "stale — run '\(toolName) manage' or open PaperWalls")")
    } else {
        print("published: not yet — run '\(toolName) manage' or open PaperWalls")
    }
    printScreenSaverSelection()
    print(SystemSaverClock.statusDescription())
    print(SystemSaverClock.lockScreenStatusDescription())
    exit(ExitCode.ok)
}

func runManage() -> Never {
    // Under a hard lock the OS profile (or configured hard tier) owns the
    // desktop — manage must not fight it.
    let lockState = LockState.current()
    // The screen saver snapshot is independent of the wallpaper outcome,
    // so publish it before any of the early exits below.
    publishScreenSaverSnapshot(library: loadFullLibrary(), lockMode: lockState.mode)
    // Independent of the wallpaper too (a deployed saver doesn't read the
    // lock tier), so it also runs before the early exits.
    enforceScreenSaverSelection()
    applySystemSaverClockPolicy()
    if lockState.mode == .hard {
        fail("the wallpaper is locked (\(lockState.osEnforced ? "enforced by configuration profile" : "hard lock configured")); manage will not modify it",
             code: ExitCode.selectionLocked)
    }

    // One-time upgrades (also done by the app; whichever runs first wins):
    // path-derived folder IDs → content IDs (spec §6) and legacy rotation
    // keys → rotationPool (spec §4).
    ContentIDMigration.migrateIfNeeded()
    RotationPoolMigration.migrateIfNeeded()

    guard let selectedID = ManagedPreferences.string(.selectedWallpaperID), !selectedID.isEmpty else {
        print("\(toolName): no selectedWallpaperID configured in \(ManagedPreferences.domain); nothing to do")
        exit(ExitCode.ok)
    }

    let library = loadFullLibrary()

    let url: URL
    var resolvedName = selectedID
    if let wallpaper = library.wallpaper(withID: selectedID),
       let resolved = library.fileURL(for: wallpaper) {
        url = resolved
        resolvedName = wallpaper.displayName
    } else if selectedID.hasPrefix("/") || selectedID.hasPrefix("~") {
        // Convenience: allow a plain filesystem path in selectedWallpaperID.
        url = URL(fileURLWithPath: (selectedID as NSString).expandingTildeInPath).standardizedFileURL
    } else {
        fail("selectedWallpaperID '\(selectedID)' not found in the bundled catalog or external folder",
             code: ExitCode.invalidFile)
    }

    let scale = ManagedPreferences.string(.scale).flatMap(WallpaperScale.init(rawValue:)) ?? .fill
    let fillColor = ManagedPreferences.string(.fillColor).flatMap(NSColor.init(hexString:))
    let applyToAll = ManagedPreferences.bool(.applyToAllScreens) ?? true

    let allScreens = NSScreen.screens
    guard !allScreens.isEmpty else {
        fail(WallpaperError.noScreens.localizedDescription, code: ExitCode.noSuchScreen)
    }
    let screens = applyToAll ? allScreens : [allScreens[0]]

    applyOrExit(url: url, screens: screens, scale: scale, fillColor: fillColor)
    print("applied '\(resolvedName)' (\(selectedID)) to \(screens.count) display(s) [scale: \(scale.rawValue)]")
    exit(ExitCode.ok)
}

// MARK: - watch (spec §7 — Tier 3)

/// Long-running desktop watcher: when `lockMode == enforcedRotation` and the
/// current desktop picture is outside the approved rotation pool, re-apply
/// the last-approved (or first pool) wallpaper. Reversion, not prevention —
/// there is no OS hook to block a change, only to observe and restore.
/// Idles cheaply in every other lock mode so the LaunchAgent can stay
/// resident fleet-wide. Under a hard/OS lock (Tier 2) it deliberately does
/// nothing: the profile owns the desktop (mutual exclusion, spec §7).
final class DesktopWatcher {
    private let interval: TimeInterval
    private var timer: Timer?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.check()
        }
        // Space switches and display changes are the moments a drifted
        // desktop becomes visible — check immediately instead of waiting
        // out the poll interval.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.check() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.check() }
        check()
    }

    private func check() {
        // Admin config can change under a long-lived process — re-read the
        // local config file layer every evaluation.
        ManagedPreferences.invalidateLocalConfigCache()
        let lockState = LockState.current()
        guard lockState.mode == .enforcedRotation else { return }

        let library = loadFullLibrary()
        let pool = RotationPool.resolveFromPreferences(library: library, lockMode: lockState.mode)
        guard !pool.isEmpty else { return }   // defined no-op: nothing approved

        let approvedPaths = Set(pool.compactMap { library.fileURL(for: $0)?.standardizedFileURL.path })
        let screens = NSScreen.screens
        let offenders = screens.filter { screen in
            !WatchPolicy.isCompliant(
                currentPath: WallpaperEngine.currentWallpaperURL(for: screen)?.standardizedFileURL.path,
                approvedPaths: approvedPaths)
        }
        guard !offenders.isEmpty else { return }

        guard let target = WatchPolicy.revertTarget(pool: pool,
                                                    selectedID: ManagedPreferences.string(.selectedWallpaperID)),
              let url = library.fileURL(for: target) else {
            return
        }
        let scale = ManagedPreferences.string(.scale).flatMap(WallpaperScale.init(rawValue:)) ?? .fill
        let fillColor = ManagedPreferences.string(.fillColor).flatMap(NSColor.init(hexString:))
        do {
            try WallpaperEngine.setWallpaper(url: url, on: offenders, scale: scale, fillColor: fillColor)
            print("\(toolName): reverted \(offenders.count) display(s) to '\(target.displayName)' (\(target.id))")
        } catch {
            stderrPrint("\(toolName): revert failed: \(error.localizedDescription)")
        }
    }
}

func runWatch(_ arguments: [String]) -> Never {
    var interval: TimeInterval = 15
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--interval":
            index += 1
            guard index < arguments.count, let seconds = TimeInterval(arguments[index]), seconds >= 5 else {
                fail("--interval requires a number of seconds (minimum 5)", code: ExitCode.usage)
            }
            interval = seconds
        default:
            fail("unknown option '\(arguments[index])' — usage: \(toolName) watch [--interval seconds]",
                 code: ExitCode.usage)
        }
        index += 1
    }

    // Line-buffer stdout: under a LaunchAgent it's a file, and block
    // buffering would hold revert log lines back indefinitely.
    setvbuf(stdout, nil, _IOLBF, 0)
    print("\(toolName): watching the desktop every \(Int(interval))s (enforces only under lockMode=enforcedRotation; Ctrl-C to stop)")
    let watcher = DesktopWatcher(interval: interval)
    watcher.start()
    RunLoop.main.run()
    exit(ExitCode.ok)
}

func applyOrExit(url: URL, screens: [NSScreen], scale: WallpaperScale, fillColor: NSColor?) {
    do {
        try WallpaperEngine.setWallpaper(url: url, on: screens, scale: scale, fillColor: fillColor)
    } catch let error as WallpaperError {
        switch error {
        case .invalidFile:
            fail(error.localizedDescription, code: ExitCode.invalidFile)
        case .noScreens, .noSuchScreen:
            fail(error.localizedDescription, code: ExitCode.noSuchScreen)
        case .setFailed:
            fail(error.localizedDescription, code: ExitCode.applyFailed)
        }
    } catch {
        fail(error.localizedDescription, code: ExitCode.applyFailed)
    }
}

// MARK: - Entry point

let argumentList = Array(CommandLine.arguments.dropFirst())

guard let command = argumentList.first else {
    printUsage(toStandardError: true)
    exit(ExitCode.usage)
}

if getuid() == 0 && (command == "set" || command == "manage" || command == "watch") {
    fail("refusing to run as root — the desktop picture is a per-user session setting",
         code: ExitCode.refusedRoot)
}

switch command {
case "get":
    runGet(Array(argumentList.dropFirst()))
case "set":
    runSet(Array(argumentList.dropFirst()))
case "manage":
    guard argumentList.count == 1 else {
        fail("manage takes no arguments", code: ExitCode.usage)
    }
    runManage()
case "watch":
    runWatch(Array(argumentList.dropFirst()))
case "screensaver":
    if argumentList.count == 2, argumentList[1] == "enforce" {
        runScreenSaverEnforce()
    }
    guard argumentList.count == 1 else {
        fail("usage: screensaver [enforce]", code: ExitCode.usage)
    }
    runScreenSaver()
case "version", "--version", "-v":
    print(toolVersion)
    exit(ExitCode.ok)
case "help", "--help", "-h":
    printUsage(toStandardError: false)
    exit(ExitCode.ok)
default:
    fail("unknown command '\(command)' — run '\(toolName) help'", code: ExitCode.usage)
}
