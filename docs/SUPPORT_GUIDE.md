# PaperWalls — Support / Troubleshooting Guide

For help desk and support engineers triaging user reports. The
[Administrator Guide](ADMIN_GUIDE.md) is the deep reference; this is the
quick-hits version.

## What "working correctly" looks like

- The app shows a sidebar: **Library** (Browse, Collections, macOS, Managed,
  Personal, ScreenSavers), **Tools** (Studio), then Settings — some entries
  hide when their source or feature is disabled by policy.
- With "PaperWalls" chosen in System Settings → Screen Saver, the screen
  saver shows the scene marked **ACTIVE** on the ScreenSavers page.
- Clicking **Set** on any wallpaper changes the desktop within a second or
  two, and the card gains an **ACTIVE** badge shortly after.
- A menu bar icon offers rotate controls and "Up next" previews.
- On managed Macs, settings controlled by the organization appear greyed
  with a *"Managed by your organization"* badge — that is by design, not a
  defect.

## Quick triage

| Symptom | Likely cause | Fix / check |
| --- | --- | --- |
| Set buttons greyed; full-screen "locked" panel | A lock policy is active (`lockMode` soft/hard) | Expected under policy. `defaults read com.herojoneslabs.paperwalls lockMode` (also check managed layer — see diagnostics). Only an admin can lift it |
| Wallpaper reverts by itself seconds after changing | Enforced-rotation watcher is running (by design), or the org pins a selection via the hourly agent | Expected on managed Macs. `launchctl print gui/$(id -u) \| grep paperwalls` shows the agents |
| CLI `set` exits 6 | Selection locked by policy | Same as above — the CLI is never a bypass |
| CLI `set`/`manage`/`watch` exits 5 | Ran as root | Run as the logged-in user; the desktop is a per-user setting |
| macOS page: Download buttons greyed | (a) Downloads disabled by policy (`allowSystemWallpaperDownloads=false`) — the section is normally hidden entirely then; (b) Apple's catalog unreachable (no network to `mesu.apple.com`) | Hover the button — the tooltip states the reason. With network present, reopening the app retries the catalog fetch once per launch |
| Download fails with an error alert | No network to `updates.cdn-apple.com`, or disk full | Check connectivity/proxy allow-list for Apple CDN hosts |
| Curated/org feed shows nothing | Feed disabled (default), never synced, or its signature failed verification (the app refuses unsigned/tampered manifests silently and keeps the last good state) | Check gates: `appCuratedEnabled` / `orgCatalogEnabled`+URL+key. Then check the log (below) for `remotecatalog` errors |
| Personal page won't import dropped images | Only image files import (`.jpg .jpeg .png .heic .tiff`); dropped *folders* are ignored in app-managed mode | Try a single JPEG. In user-defined mode, dropping a folder switches the source instead |
| A sidebar item is missing (Collections / macOS) | Its source is disabled (`showBundledWallpapers` / `showSystemWallpapers` false) | By design; check policy |
| ScreenSavers or Studio missing from the sidebar | Hidden by policy (`showScreenSaversPage` / `showStudio`), or creation is disabled (`allowScreenSaverCreation=false` hides Studio's ScreenSaver tab) | By design; check policy |
| Screen saver shows a plain color | Screen savers turned off (`screenSaverEnabled=false`) or a hard lock | `paperwallscli screensaver` prints `state: disabled` or `hardLock` — expected under policy |
| Screen saver shows a simple clock, not the user's scene | Nothing is ACTIVE, or the chosen scene isn't allowed/doesn't exist on this Mac | Have the user click **Set Active** on a card. `paperwallscli screensaver` shows `noneSelected` |
| Two clocks on the screen saver | macOS draws its own large clock over every saver (System Settings › Wallpaper › Clock Appearance › **Show large clock**) and the scene has a clock layer too | Settings › Screen Saver › **macOS clock over the saver** → *Hide when the scene has a clock*, or set **Show large clock** to *Never*. Admins: `hideSystemSaverClock` or a profile (Admin Guide §12). `paperwallscli screensaver` prints the clock state |
| Two clocks when the lock screen comes up over the saver | The lock screen half of **Show large clock** (`UsesLargeDateTime`, system-level) is still on; it needs an administrator | Settings › Screen Saver › **Lock screen clock** → **Apply as Admin…** (admin password), or run `sudo paperwallscli screensaver enforce`, or deploy the Hide System Clock profile. The PaperWalls pkg postinstall also applies it on install |
| Screen saver shows an out-of-date scene | The saver reads a published snapshot when it starts | Open PaperWalls once, or run `paperwallscli manage` as the user; `paperwallscli screensaver` should then say `published: up to date` |
| A different screen saver runs | "PaperWalls" isn't selected in macOS | System Settings → Screen Saver → Other → PaperWalls (a macOS setting, not a PaperWalls one) |
| A scene's own tile ("PaperWalls – <name>") is missing | Not opted in, or blocked by policy (feature off, hard lock, allow-list); tiles are generated when the app runs | Card's **…** menu → "Show in System Settings"; open PaperWalls once; quit and reopen System Settings |
| "Set Active" is greyed | Active scene forced by the organization, a soft/hard lock, or the scene isn't on the allow-list | Hover the button — the tooltip states the reason |
| App asks for access to Downloads/Desktop etc. at launch | macOS privacy (TCC) prompt: the current desktop picture lives in that folder and the app checks what's on screen | Either answer is safe; "Don't Allow" only hides the ACTIVE badge for wallpapers stored there |
| Theme looks wrong after switching to System | Fixed in current versions (applies instantly and tracks macOS) | Update the app if older than 1.0 build 14 |
| Wallpaper didn't survive logout/restart | macOS re-applies per-space pictures; the manage agent converges it | Confirm the manage LaunchAgent is installed and loaded |

## Diagnostics

**Easiest first: have the user click Settings → Support → "Collect Logs…"**
in the app. It saves a single zip (user picks where) containing the last 4
hours of app/CLI logs, every resolved setting with its forced/managed flag,
lock and rotation state, current desktop paths, LaunchAgent status, the
managed-config layer, and a cache listing — i.e. everything below, pre-
gathered. Nothing is transmitted; the user sends you the file.

The manual equivalents, when the app can't be opened:

**Effective settings** (user layer only — managed values won't show here):

```sh
defaults read com.herojoneslabs.paperwalls
```

Managed layer: check `/Library/Managed Preferences/*/com.herojoneslabs.paperwalls.plist`
and `/Library/Application Support/PaperWalls/managed.json`.

**Current desktop picture(s):**

```sh
/usr/local/bin/paperwallscli get
```

**App logs** (unified log; all components share the subsystem):

```sh
log show --last 30m --predicate 'subsystem == "com.herojoneslabs.paperwalls"' --style compact
```

Categories: `preferences` (config resolution), `catalog` (folder scans),
`engine` (setting the wallpaper), `enforcement` (lock detection),
`remotecatalog` (feed sync/signature), `systemwallpapers` (Apple downloads),
`scenestore` (screen saver library), `screensaver` (publishing to the
saver), `saver` (the screen saver itself), `scenebundles` (per-scene tiles).

**Screen saver state:**

```sh
/usr/local/bin/paperwallscli screensaver
```

**Caches** (safe to delete; the app rebuilds them):
`~/Library/Application Support/PaperWalls/` — `RemoteCache/` (feeds),
`SystemWallpapers/` (Apple downloads), `content-id-cache.json` (hash cache).
Do **not** delete `Personal/` (the user's own wallpaper library) or
`Studio/ScreenSavers/` (the screen savers they made).

## Escalation

Collect before escalating to whoever owns the deployment:

1. App version (PaperWalls → About, or `defaults read /Applications/PaperWalls.app/Contents/Info.plist CFBundleVersion`) and `paperwallscli version`
2. Output of the `log show` command above around the failure time
3. `defaults read com.herojoneslabs.paperwalls` + whether a config profile for the domain is installed (System Settings → General → Device Management)
4. Exact symptom + the wallpaper/source involved
