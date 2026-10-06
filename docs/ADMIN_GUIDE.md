# PaperWalls — Administrator Guide

PaperWalls is a macOS wallpaper manager built for managed fleets: a SwiftUI
app, a `desktoppr`-style command-line tool, and a preference surface designed
for MDM (every setting is a key in one preference domain, forceable by a
configuration profile). It also works fully standalone on unmanaged Macs.

- App: `/Applications/PaperWalls.app` (bundle ID `com.herojoneslabs.paperwalls`)
- CLI: `/usr/local/bin/paperwallscli`
- Screen saver: `/Library/Screen Savers/PaperWalls.saver` (optional — see §12)
- Preference domain: `com.herojoneslabs.paperwalls` (equals the bundle ID)
- Requires: macOS 13+ (some wallpaper sources offer more content on newer macOS)

---

## 1. Installation

Build or download the distribution package and install with any MDM, or:

```sh
sudo installer -pkg PaperWalls-<version>.pkg -target /
```

Package payload:

| Path | Purpose |
| --- | --- |
| `/Applications/PaperWalls.app` | The app (signed, hardened runtime) |
| `/usr/local/bin/paperwallscli` | CLI (same rules and preferences as the app) |
| `/Library/LaunchAgents/com.herojoneslabs.paperwalls.manage.plist` | Optional: runs `paperwallscli manage` at login + hourly so managed selections converge without the app running |
| `/Library/LaunchAgents/com.herojoneslabs.paperwalls.watch.plist` | Optional (off by default): the Tier-3 enforcement watcher — see §5 |
| `/Library/LaunchAgents/com.herojoneslabs.paperwalls.saverclock.plist` | Optional (on by default): the clock watcher for the screen saver half of `hideSystemSaverClock` — see §12 |
| `/Library/LaunchDaemons/com.herojoneslabs.paperwalls.lockscreenclock.plist` | Optional (on by default): the root clock watcher for the lock screen half — see §12 |
| `/Library/Screen Savers/PaperWalls.saver` | Optional (on by default): the screen saver — see §12 |

A postinstall script bootstraps the included LaunchAgent(s) into the console
user's session immediately, so settings converge without a logout/login, and
restarts the screen saver host so an updated saver is the one that runs.
Building your own pkg: `Deployment/build-pkg.sh` (configure the CONFIG block;
`INSTALL_WATCH_AGENT=true` adds the watcher agent to the payload,
`INSTALL_CLOCK_WATCHERS=false` leaves the clock watchers out,
`INSTALL_SAVER=false` leaves the screen saver out).

### Background activity (Login Items)

On macOS 13 and later, the first time the pkg's LaunchAgents and LaunchDaemon
load, macOS tells the user **"App Background Activity — Software from
“<developer>” can run in the background"** (the developer is whoever signed
`paperwallscli`), and lists them under System Settings › General › **Login
Items & Extensions**, where the user can switch them off. For a managed fleet,
approve them up front with a **Managed Login Items** payload
(`com.apple.servicemanagement`): no notification, and the items can't be
disabled. `Deployment/com.herojoneslabs.paperwalls.backgroundactivity.mobileconfig`
is a reference with a `LabelPrefix` rule for `com.herojoneslabs.paperwalls`
(covers `manage`, `watch`, `saverclock`, `lockscreenclock`); a
`TeamIdentifier` rule with your own team ID is the broader alternative when
you sign the pkg yourself. In Jamf Pro it's the **Managed Login Items**
payload of a computer configuration profile. Deploy it **before** the pkg so
the first load is already approved; deployed afterwards it still approves the
items and removes the user's ability to disable them.

The app is deliberately **not sandboxed** (it must set the desktop picture,
read `/Library/Managed Preferences`, and scan arbitrary folders) and is
intended for pkg distribution, not the App Store.

---

## 2. Configuration model

Every setting lives in the `com.herojoneslabs.paperwalls` domain and resolves
through a layered lookup. **Precedence, highest wins:**

1. **MDM-forced** — a configuration profile (Application & Custom Settings)
2. **Local forced** — `/Library/Application Support/PaperWalls/managed.json` (or `.plist`), `"forced"` section
3. **User value** — whatever the user set in the app/CLI
4. **Local defaults** — `managed.json`, `"defaults"` section
5. Built-in default

Forced keys (layers 1–2) render disabled in the app with a
*"Managed by your organization"* badge, and user writes to them are ignored.
The app **live-reloads** when the profile store or the local config file
changes — no relaunch needed.

### Local admin config (no MDM / air-gapped)

`/Library/Application Support/PaperWalls/managed.json`:

```json
{
  "forced":   { "lockMode": "soft", "companyName": "Acme" },
  "defaults": { "autoRotateIntervalMinutes": 60 }
}
```

`"forced"` behaves exactly like an MDM-forced key; `"defaults"` seeds values
the user may still override. A sample ships in `Deployment/managed.json.example`.

### Jamf Pro

`Deployment/com.herojoneslabs.paperwalls.schema.json` is a custom schema for
Application & Custom Settings (External Applications → Custom Schema, domain
`com.herojoneslabs.paperwalls`). It renders every key as a friendly form
control — add only the keys you want to force. A raw `.mobileconfig` example
is also in `Deployment/`, alongside the Managed Login Items profile that
approves PaperWalls' background items (§1) and the screen saver references
(§12).

---

## 3. Preference key reference

### Core

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `selectedWallpaperID` | string | — | Wallpaper to pin/apply: any wallpaper ID (see §7) or an absolute file path |
| `scale` | string | `fill` | `fill` \| `fit` \| `stretch` \| `center` |
| `fillColor` | string | — | 6-digit hex letterbox color for fit/center |
| `applyToAllScreens` | bool | `true` | All displays vs. primary only |
| `companyName` | string | — | Org branding: sidebar shows "\<Name\> (Managed)", filters show "\<Name\>", org feed shows "\<Name\> Feed" |

### Lock / restrictions

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `lockMode` | string | `off` | `off` \| `soft` \| `hard` \| `enforcedRotation` — see §5 |
| `lockSelection` | bool | `false` | **Legacy** — maps to `soft` (or `hard` with a forced `allowLockExit=false`) |
| `allowLockExit` | bool | `true` | Soft lock only: user may leave the locked view and browse read-only |
| `allowedWallpaperIDs` | array | — | Allow-list; restricts the picker and rotation to these IDs |

### Sources

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `showBundledWallpapers` | bool | `true` | The wallpapers shipped inside the app |
| `showSystemWallpapers` | bool | `true` | Apple's built-in macOS wallpapers as a source |
| `allowSystemWallpaperDownloads` | bool | `true` | Permit on-demand fetches of Apple wallpapers from Apple's CDN; force `false` on network-restricted fleets |
| `showFeaturedWallpaper` | bool | `true` | The daily "Featured today" hero on Browse |
| `appCuratedEnabled` | bool | `false` | The PaperWalls curated feed (signed, cached) |
| `orgCatalogEnabled` | bool | `false` | Your organization's own remote feed — see §6 |
| `orgCatalogURL` | string | — | HTTPS URL of your org feed's `catalog.json` |
| `orgCatalogPublicKey` | string | — | Base64 raw-32-byte Ed25519 public key for the org feed |
| `externalWallpaperFolderPath` | string | — | Local/managed folder scanned as the "Managed" source (deploy images separately) |
| `personalFolderSource` | string | `appManaged`\* | `appManaged` (fixed app-owned folder, drag-and-drop import) \| `userDefined` (user-chosen folder). \*Macs with `personalWallpaperFolderPath` already set stay `userDefined` |
| `personalWallpaperFolderPath` | string | — | The user's folder in `userDefined` mode |

### Rotation

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `autoRotateEnabled` | bool | `false` | Rotate automatically |
| `autoRotateIntervalMinutes` | int | `30` | Minutes between rotations |
| `rotationPool` | array | all real sources | What rotation draws from: any of `favorites`, `bundled`, `system`, `appCurated`, `orgRemote`, `orgFolder`, `personal`. `favorites` narrows to hearted wallpapers; empty array = rotate nothing |
| `autoRotateShuffle` | bool | `true` | Random vs. in-order |
| `autoRotateOnWake` | bool | `false` | New wallpaper on wake |
| `autoRotateSource`, `rotateIncludeBundled/Personal/Managed` | — | — | **Legacy** — automatically migrated into `rotationPool`; profiles still forcing them are translated live |

### Appearance

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `appearanceTheme` | string | `light` | `light` \| `dark` \| `system` (tracks macOS live) |
| `gridColumns` | int | `2` | Wallpaper grid density, 2–4 columns |
| `favoriteWallpaperIDs` | array | — | The user's hearted wallpapers (usually left to the user) |

### Screen savers and Studio

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `screenSaverEnabled` | bool | `true` | Master switch for the PaperWalls screen saver; `false` makes the saver show a solid color and nothing else |
| `activeScreenSaverSceneID` | string | — | The scene the saver runs: a scene's UUID from the user's library, or `managed` for the scene provisioned by `managedScreenSaverScene`. Forcing it disables **Set Active** |
| `managedScreenSaverScene` | string (JSON) | — | An organization-provided scene, shown as a read-only **Managed** entry (ID `managed`). Build it in Studio and use the card's **Copy Scene for MDM** action (shown in Admin mode). In `managed.json` it may be an inline object instead of a string |
| `allowedScreenSaverSceneIDs` | array of strings | — | Optional allow-list of scene IDs that may be active; other scenes stay visible but can't be set active |
| `enforcedScreenSaverPath` | string | — | Full path of a saver to keep selected for every Space and display, e.g. `/Library/Screen Savers/PaperWalls.saver`. Applied by `paperwallscli manage` (login + hourly) or `paperwallscli screensaver enforce`; users' own picks are switched back. On macOS 14+ Apple's `moduleName` only *locks* the choice, it doesn't select a third-party saver: pair the two for a selected, locked saver (Admin Guide §12) |
| `hideSystemSaverClock` | string | `never` | What to do about the large clock macOS draws over every screen saver and on the lock screen (System Settings › Wallpaper › Clock Appearance › **Show large clock**) — two clocks, when the scene has one. `never` leaves it to macOS; `whenSceneHasClock` turns it off while the selected saver is a PaperWalls saver whose scene draws a clock, and puts the user's value back otherwise; `always` keeps it off. The screen saver half (the user's `com.apple.screensaver` `showClock`, per host) is applied by the app, `paperwallscli manage`, and `paperwallscli screensaver enforce`. The lock screen half (`/Library/Preferences/com.apple.loginwindow` `UsesLargeDateTime`) is system-level and needs root: the pkg postinstall, `paperwallscli screensaver enforce` run as root, or Settings › **Apply as Admin…**. A profile that forces either key wins (Admin Guide §12) |
| `hideSystemSaverClockOnLockScreen` | bool | `true` | With `hideSystemSaverClock`: also cover the lock screen half. `false` leaves the lock screen clock alone (and restores it if PaperWalls had hidden it) |
| `allowScreenSaverCreation` | bool | `true` | `false` = users can't create, edit, rename, or delete scenes (Studio's ScreenSaver tab is unavailable); they can still browse, preview, and Set Active |
| `showScreenSaversPage` | bool | `true` | Shows/hides the ScreenSavers page in the sidebar's Library section |
| `showStudio` | bool | `true` | Shows/hides Studio (the sidebar's Tools section) |
| `showStudioWallpapersTab` | bool | `true` | Shows/hides Studio's Wallpapers tab (the wallpaper composer) |
| `showStudioScreenSaverTab` | bool | `true` | Shows/hides Studio's ScreenSaver tab (the Scene Composer). With both tabs hidden, Studio is hidden |
| `adminModeEnabled` | bool | `false` | Admin tools: Studio's **Package** tab (build a deployable pkg of screen savers or wallpapers), **Package for Deployment…** on cards, and the **Copy Scene for MDM** card action. Force `false` to keep them off a fleet; the Package tab ignores `showStudio` so an admin's own Mac keeps it |
| `brandAssetsFolderPath` | string | — | Folder of the organization's logos and icons (e.g. `/Library/CompanyBrand`), scanned non-recursively for `.png .jpg .jpeg .heic .tiff .gif`. Offered as read-only **Brand Assets** in Studio's composer on every Mac. Deploy the images separately — see §12 |
| `jamfPublishEnabled` | bool | `false` | Admin mode only: adds a **Publish to Jamf Pro** step after a Studio › Package build that uploads the result through the Jamf Pro API. Nothing is sent until the admin presses Publish. The server URL and API client live on the admin's Mac (Settings › Admin; user layer + Keychain), never in this domain — see §12 |
| `jamfPublishPackages` | bool | `true` | With publishing on: allow uploading the built installer package (API role: Create, Read, Update Packages; Jamf Pro 11.5+ with a cloud distribution point) |
| `jamfPublishProfiles` | bool | `true` | With publishing on: allow creating the `Enforce/` and `Configure/` profiles as unscoped macOS configuration profiles (API role: Create, Read, Update macOS Configuration Profiles) |
| `aiGenerationEnabled` | bool | `false` | Master switch for AI-generated wallpaper backgrounds in Studio › Wallpapers. `false` hides every AI control regardless of the provider toggles |
| `aiAppleOnDeviceEnabled` | bool | `false` | Offers **Apple On-Device** generation (Image Playground via Apple Intelligence; runs entirely on the Mac). Needs Apple silicon with Apple Intelligence on |
| `aiLocalModelEnabled` | bool | `false` | Offers **Local Model** generation: an image server on the Mac or the network (Draw Things, Automatic1111, Forge, SD.Next, or any OpenAI-compatible endpoint). Prompts go only to `aiLocalModelEndpoint`, and only when the user presses Generate |
| `aiLocalModelEndpoint` | string | — | Base URL of the local image server, e.g. `http://127.0.0.1:7860`. No scheme means `http://` |
| `aiLocalModelFlavor` | string | `automatic1111` | The server's API: `automatic1111` (`/sdapi/v1/txt2img`; also Draw Things, Forge, SD.Next) or `openAICompatible` (`/v1/images/generations`) |
| `aiLocalModelName` | string | — | Optional model/checkpoint name sent with each request; empty uses the server's default |
| `aiLocalModelImageSize` | string | `match` | Width × height asked of the server: `match` (wide, tall, or square to suit the wallpaper's shape), `1024x1024`, `1344x768`, `768x1344`, or any `WxH` between 64 and 4096 |
| `aiExternalModelEnabled` | bool | `false` | Offers **External Model** generation: a cloud image service (Google Gemini image models, OpenAI, or any OpenAI-compatible endpoint). Prompts go only to the chosen service, and only when the user presses Generate. API keys live in the user's Keychain, never in this domain |
| `aiExternalProvider` | string | `google` | Which service: `google` (`generativelanguage.googleapis.com`), `openAI` (`api.openai.com`), or `openAICompatible` (`aiExternalEndpoint`) |
| `aiExternalEndpoint` | string | — | OpenAI-compatible only: base URL of the service, e.g. `https://images.example.com`. No scheme means `https://` |
| `aiExternalModelName` | string | — | Optional model name; empty sends the service default (`gemini-2.5-flash-image`, `gpt-image-1`) |
| `aiExternalImageShape` | string | `matchWallpaper` | `matchWallpaper` (follows the wallpaper's shape), `square`, `landscape`, or `portrait`, mapped to each service's size vocabulary |
| `aiPromptImproverEnabled` | bool | `false` | Adds an **Improve** button beside the description in Studio: Claude (Anthropic Messages API, `api.anthropic.com`) rewrites the idea into a detailed image prompt. Claude doesn't make images. Needs the user's Anthropic API key in their Keychain |
| `aiPromptImproverModel` | string | `claude-opus-5-5` | The Claude model used by Improve |

See §12 for how these interact with lock tiers and how the saver is deployed.

---

## 4. Wallpaper sources

The library merges up to six sources, each independently gated:

| Source | Gate | Content |
| --- | --- | --- |
| Bundled | `showBundledWallpapers` | Curated set inside the app bundle |
| macOS | `showSystemWallpapers` | Apple's built-ins from `/System/Library/Desktop Pictures`. Flat images apply directly; the rest are offered as **on-demand downloads** from Apple's CDN (gated by `allowSystemWallpaperDownloads`). If the Mac's own Apple asset catalog is missing (common on freshly provisioned machines), the app fetches Apple's public catalog copy once |
| Curated feed | `appCuratedEnabled` | Remote feed published by the PaperWalls project (Ed25519-signed manifest, sha256-verified assets, cached locally) |
| Org feed | `orgCatalogEnabled` + URL + key | Your organization's own signed remote feed — §6 |
| Managed folder | `externalWallpaperFolderPath` | A folder you deploy (e.g. `/Library/CompanyWallpapers`), scanned non-recursively for `.jpg .jpeg .png .heic .tiff`. **Studio › Package › Wallpapers** builds the pkg and the profile for you — §12 |
| Personal | `personalFolderSource` | The user's own wallpapers |

**Network guarantee:** with both feed gates false, `allowSystemWallpaperDownloads`
false, and no folders configured, the app and CLI make **zero network
requests** — fully air-gap capable. The CLI never syncs feeds at all; it only
reads what the app has already cached.

---

## 5. Lock tiers and enforcement

| Tier | How | Strength |
| --- | --- | --- |
| **App-only (`lockMode`)** | `soft`: only the managed selection can be applied; controls grey out; CLI `set` refuses (exit 6). `hard`: nothing can be applied, locked view cannot be exited. `enforcedRotation`: rotation continues within `allowedWallpaperIDs` (or, with no allow-list, within the resolved `rotationPool`) | Cooperative — the app and CLI self-enforce, but other tools could still change the desktop |
| **OS profile (Tier 2)** | Deploy `Deployment/com.herojoneslabs.paperwalls.lock.mobileconfig` (a `com.apple.desktop` override / wallpaper-modification restriction). The app *detects* it and reports "Enforced by configuration profile" | OS-level; strongest |
| **Watcher (Tier 3)** | `paperwallscli watch` via the optional LaunchAgent: under `enforcedRotation`, any out-of-pool desktop is reverted to the last-approved wallpaper within the poll interval (default 15 s). Reversion, not prevention | Between the two — rotation keeps working |

**Never combine Tier 2 with `enforcedRotation`** — the OS override wins and
the two fight. The app enforces this automatically (an OS restriction forces
hard-lock behavior and the watcher stands down), but don't deploy them
together. The watcher idles cheaply in every other lock mode, so shipping the
agent fleet-wide is safe; it's simply pointless outside enforced rotation.

---

## 6. Running your own wallpaper feed

Any HTTPS host works (a CDN bucket is ideal — assets are content-addressed
and immutable).

1. **Generate an Ed25519 keypair** (CryptoKit/`openssl genpkey -algorithm ed25519`).
   Keep the private key secret; put the base64 raw-32-byte public key in
   `orgCatalogPublicKey`.
2. **Author `catalog.json`** (manifest v2 — see `Deployment/catalog.json.example`):
   `version: 2` plus a `wallpapers` array of `{id, displayName, collection,
   image, thumbnail, sha256, size, minAppVersion}`. Image/thumbnail URLs may
   be relative to the manifest. Name assets by their sha256.
3. **Sign it:** the signature over the exact manifest bytes, base64, published
   at `<manifest URL>.sig`. `Deployment/sign-manifest.swift` does this
   (private key via the `PAPERWALLS_SIGNING_KEY` env var), and
   `Deployment/publish-feed.sh` wraps the whole author→sign→upload flow.
4. **Cache headers:** short TTL on `catalog.json`/`.sig` (e.g. `max-age=300`;
   the app revalidates with ETags), long immutable TTL on assets.
5. Set `orgCatalogEnabled=true`, `orgCatalogURL`, `orgCatalogPublicKey`.

The app syncs at launch, every 6 hours, and when the feed keys change. An
unsigned, tampered, or unreachable manifest never lands — devices keep their
last verified state. Removed entries are evicted from device caches on the
next sync.

## 7. Wallpaper IDs

`selectedWallpaperID` and `allowedWallpaperIDs` accept, from any source:

| Prefix | Source | Notes |
| --- | --- | --- |
| `bundled-…` | Bundled | Author-assigned, stable |
| `file:<hash>` | Managed folder / personal | **Content-derived** (byte fingerprint) — identical on every Mac that has the same image file, and stable across renames/moves. Legacy `external-…` path-derived IDs still resolve |
| `macos:<name>` | macOS built-ins | e.g. `macos:Sonoma` — identical on every Mac |
| `app:…` / `org:…` | Curated / org feed | Namespaced feed IDs |
| absolute path | — | `selectedWallpaperID` also accepts a plain file path |

To discover an ID, click the wallpaper in the app and read "Selected
Wallpaper ID" in Settings, or check the detail sheet.

## 8. Command-line tool

```
paperwallscli get [screen-index]        current desktop picture path(s)
paperwallscli set <path> [screen-index] [--scale fill|fit|stretch|center] [--color RRGGBB] [--all-screens]
paperwallscli manage                    apply the managed/user preferences (LaunchAgent entry point)
paperwallscli watch [--interval s]      Tier-3 enforcement watcher (min 5s, default 15s)
paperwallscli screensaver               print what the screen saver will show + macOS's clock state (read-only)
paperwallscli screensaver enforce       select enforcedScreenSaverPath for every Space/display + apply hideSystemSaverClock now
                                        (as the user; as root — sudo, a Jamf policy — only the lock screen half of the clock policy)
paperwallscli screensaver clock [--watch]  apply hideSystemSaverClock now (user: saver half; root: lock screen half);
                                        --watch stays resident and re-applies on every System Settings change
paperwallscli version | help
```

Exit codes: `0` ok · `1` usage · `2` bad file · `3` bad screen · `4` set
failed · `5` ran as root (refused — the desktop is a per-user setting) ·
`6` selection locked by policy.

## 9. Files on disk (per user)

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/PaperWalls/Personal/` | App-managed personal library |
| `~/Library/Application Support/PaperWalls/RemoteCache/` | Feed caches (verified manifests + assets) |
| `~/Library/Application Support/PaperWalls/SystemWallpapers/` | Downloaded Apple wallpapers + catalog copy |
| `~/Library/Application Support/PaperWalls/content-id-cache.json` | Folder-wallpaper hash cache |
| `~/Library/Application Support/PaperWalls/Studio/ScreenSavers/` | The user's screen savers: one `<uuid>.json` per scene, `Thumbnails/` (cache), `Assets/` (images imported into scenes, including every brand asset's image). **User data, not a cache** |
| `~/Library/Application Support/PaperWalls/Studio/BrandAssets/` | Studio › Assets library: one `<uuid>.json` per asset (name, kind, which `Assets/` file it is). **User data** |
| `~/Library/Application Support/PaperWalls/Studio/ActiveScreenSaver.json` | The resolved scene published for the saver (cache; rewritten by the app and `manage`) |
| `~/Library/Screen Savers/PaperWalls – <Scene>.saver` | Generated per-scene copies of the saver for scenes shown as their own tile (derived; the app regenerates them) |
| `~/Library/Screen Savers/PaperWalls.saver` | Only when installed from the app's Settings ("Install for Me") on a Mac without the pkg |
| `/Library/Application Support/PaperWalls/managed.json` | Optional local admin config (admin-writable) |
| `~/Library/Preferences/com.herojoneslabs.paperwalls.plist` → `jamfServerURL`, `jamfClientID` | Admin's own Jamf Pro connection (Settings › Admin). Raw user-layer keys, not managed preferences; the client secret is a Keychain item (service `com.herojoneslabs.paperwalls.jamf`) |

Deleting any per-user cache is safe — the app rebuilds it. `Personal/`,
`Studio/ScreenSavers/*.json` (+ `Assets/`), `Studio/Wallpapers/`, and
`Studio/BrandAssets/` are the user's own content.

---

## 10. Logging

The app **and** the CLI log to the macOS unified log under one subsystem:
`com.herojoneslabs.paperwalls`.

| Category | Covers |
| --- | --- |
| `preferences` | Config resolution, ignored writes to forced keys, unparseable `managed.json` |
| `catalog` | Folder scans, bundled catalog, missing folders, personal-library imports |
| `engine` | Actually setting the desktop picture (per-screen errors surface here) |
| `enforcement` | Lock-tier resolution and OS-restriction detection |
| `remotecatalog` | Feed sync: HTTP results, **signature failures**, sha256 mismatches, evictions |
| `systemwallpapers` | Apple built-in downloads and the MobileAsset catalog fallback |
| `scenestore` | Screen saver library: skipped/corrupt scene files, managed-scene parse failures |
| `screensaver` | Publishing the saver snapshot; scene image decoding |
| `saver` | The screen saver itself (logged by the system's `legacyScreenSaver` process) |
| `scenebundles` | Generating/removing per-scene saver copies in `~/Library/Screen Savers` |

Useful invocations:

```sh
# everything from the last 30 minutes
log show --last 30m --predicate 'subsystem == "com.herojoneslabs.paperwalls"' --style compact

# live-follow while reproducing an issue
log stream --predicate 'subsystem == "com.herojoneslabs.paperwalls"' --style compact

# one component only (e.g. feed sync), errors only
log show --last 2h --predicate 'subsystem == "com.herojoneslabs.paperwalls" AND category == "remotecatalog"' --style compact
log show --last 2h --predicate 'subsystem == "com.herojoneslabs.paperwalls" AND messageType == error' --style compact
```

The CLI also prints human-readable messages to stdout/stderr. The `manage`
LaunchAgent as shipped writes them to
`/tmp/com.herojoneslabs.paperwalls.manage.log` (a sample path — point it
somewhere per-user on multi-user Macs, or remove the keys and rely on the
unified log). The `watch` agent's revert events (`reverted N display(s) to …`)
go to its stdout and the unified log.

## 11. Troubleshooting

### Configuration

| Symptom | Check |
| --- | --- |
| Profile keys don't apply / no "Managed" badge | The payload must target domain `com.herojoneslabs.paperwalls` and install as **Forced** (Jamf Application & Custom Settings does this). Verify on-device: `sudo ls "/Library/Managed Preferences/"` (and the per-user subfolder) for the plist, then check the `preferences` log category. Note `defaults read com.herojoneslabs.paperwalls` shows **only the user layer** — managed values won't appear there |
| `managed.json` ignored | Must be valid JSON/plist shaped `{"forced":{…},"defaults":{…}}` at `/Library/Application Support/PaperWalls/managed.json`; parse failures log to `preferences`. World-readable, admin-writable |
| Changes need an app relaunch | They shouldn't: the app watches the profile store and `managed.json` and reloads within ~1 s. If a change genuinely doesn't land, check the file actually changed on disk and see the `preferences` log |
| "App Background Activity" notification on install, or the LaunchAgents/LaunchDaemon show as switchable in Login Items | macOS's Background Task Management saw PaperWalls' launchd jobs load without a Managed Login Items payload | Deploy `Deployment/com.herojoneslabs.paperwalls.backgroundactivity.mobileconfig` (§1); `sfltool dumpbtm` lists what BTM has approved |
| User settings "snap back" | The key is forced (MDM or local `forced`) — writes to forced keys are dropped by design |

### Locks and enforcement

| Symptom | Check |
| --- | --- |
| `paperwallscli set` exits 6 | Working as intended under soft/hard/enforcedRotation. `manage` is the sanctioned path |
| Watcher never reverts | It only enforces under `lockMode=enforcedRotation`. Verify: agent loaded (`launchctl print gui/$(id -u)/com.herojoneslabs.paperwalls.watch`), running as the console user (never root — exit 5), and the resolved rotation pool isn't empty (empty pool = nothing approved = watcher no-op) |
| Watcher/rotation fight the desktop | You deployed the Tier-2 OS override **and** `enforcedRotation` together. Don't — the app detects the OS restriction, treats the Mac as hard-locked, and the watcher stands down, but the OS profile should simply not be combined with rotation |
| App shows "App-only" instead of "Enforced by configuration profile" | The Tier-2 profile isn't on the device (or doesn't set `allowWallpaperModification=false` / a `com.apple.desktop` override). `enforcement` log category shows what was detected |

### Screen savers

| Symptom | Check |
| --- | --- |
| Saver shows a plain color | `paperwallscli screensaver` prints the state: `disabled` (`screenSaverEnabled=false`) or `hardLock` (`lockMode=hard`) — both are by design |
| Saver shows a Minimal Clock instead of the chosen scene | State is `noneSelected` (nothing active, the active ID doesn't exist on this Mac, or the allow-list excludes it), or nothing has been published yet — open PaperWalls once or run `paperwallscli manage` as the user |
| Saver shows an old scene | The saver reads the published snapshot when it starts. `paperwallscli screensaver` reports `published: stale` if it's behind; `manage` (hourly agent) or opening the app refreshes it |
| The intended saver isn't the selected one | Set `enforcedScreenSaverPath` (§12, Selecting the saver); a forced `moduleName` alone only locks, it doesn't select. `paperwallscli screensaver` shows what macOS has selected and whether it matches; `paperwallscli screensaver enforce` applies it now. Errors are logged in the `saverselection` category |
| Managed scene missing from the ScreenSavers page | `managedScreenSaverScene` isn't valid scene JSON — `scenestore` log says "Ignoring managedScreenSaverScene" |
| A chosen font doesn't appear in the saver | The font family isn't installed on that Mac; the scene falls back to the system font |
| Updated saver doesn't take effect | The host process caches the loaded bundle: `killall legacyScreenSaver` (the pkg postinstall does this) |
| A scene's own tile doesn't appear / disappears | Tiles exist only for scenes with "Show in System Settings" on, while `screenSaverEnabled` is true, `lockMode` isn't `hard`, and the allow-list permits the scene. The app generates them when it runs — check the `scenebundles` log. Quit and reopen System Settings to rescan |

### Feeds

| Symptom | Check |
| --- | --- |
| Feed enabled but no wallpapers appear | 1) `curl -sI <catalog URL>` and `<catalog URL>.sig` — both must be 200. 2) `remotecatalog` log: "signature missing or invalid" means the manifest bytes don't match the signature or the wrong public key is configured — re-sign and re-upload both files together. 3) Wrong manifest `version` (must be 2) also logs there |
| Feed is stale on devices | Manifest served with a long cache TTL? Keep `catalog.json`/`.sig` at a short TTL; the app revalidates by ETag at launch/6 h/key-change. Devices keep last-good state on any failure — that's by design |
| Some feed images missing on a device | Per-asset sha256 mismatch (re-upload the asset; the manifest `sha256` must match the bytes) or the download failed — both log to `remotecatalog`. Entries whose image isn't cached simply don't show |

### macOS wallpaper downloads

| Symptom | Check |
| --- | --- |
| Download buttons greyed | Tooltip states the cause. Usually the Apple asset catalog is unavailable: the app falls back to fetching `mesu.apple.com` once per launch (requires `allowSystemWallpaperDownloads=true` and network). `systemwallpapers` log shows the attempt |
| Downloads fail | The asset zips come from `updates.cdn-apple.com`. Both Apple hosts must be reachable through your proxy/filter |
| "Available to download" section absent | `allowSystemWallpaperDownloads=false` (intended), or every wallpaper is already downloaded |

### Network endpoints (proxy allow-list)

| Host | Used for | Gated by |
| --- | --- | --- |
| `mesu.apple.com` | Apple wallpaper catalog (fallback, once per launch at most) | `allowSystemWallpaperDownloads` |
| `updates.cdn-apple.com` | Apple wallpaper images (user-initiated) | `allowSystemWallpaperDownloads` |
| Curated feed host | Manifest + assets (launch/6 h) | `appCuratedEnabled` |
| Your org feed host | Manifest + assets (launch/6 h) | `orgCatalogEnabled` |

Everything else is local. With all four gates off, the app and CLI are
network-silent.

### Reset matrix

| Problem | Reset (per user; the app rebuilds all of these) |
| --- | --- |
| Corrupt/stale feed cache | Delete `~/Library/Application Support/PaperWalls/RemoteCache/` |
| Re-download Apple wallpapers | Delete `…/PaperWalls/SystemWallpapers/` |
| Folder wallpapers re-hash | Delete `…/PaperWalls/content-id-cache.json` |
| Re-show the download-before-set prompt | `defaults delete com.herojoneslabs.paperwalls suppressSystemDownloadSetPrompt` |

Avoid `defaults delete com.herojoneslabs.paperwalls` (the whole domain) —
it wipes the user's favorites and rotation state; delete individual keys
instead. And never delete `…/PaperWalls/Personal/` — that's the user's own
wallpaper library, not a cache.

---

## 12. Screen savers and Studio

PaperWalls includes a real macOS screen saver (`PaperWalls.saver`) that plays
a *scene* — a background plus clock, text, and icon layers — composed in the
app's **Studio** and kept on the **ScreenSavers** page.

### How the pieces fit

1. Users (or you) compose scenes in Studio; they are saved per user under
   `~/Library/Application Support/PaperWalls/Studio/ScreenSavers/`.
2. One scene is **active** (`activeScreenSaverSceneID`).
3. The app and `paperwallscli manage` resolve policy — master switch, lock
   tier, allow-list, active scene — and publish the result to
   `…/PaperWalls/Studio/ActiveScreenSaver.json`.
4. The saver reads that file each time it starts.

Step 3 exists because macOS runs third-party savers in a sandboxed host
(`legacyScreenSaver`) that **cannot read this preference domain**; it can read
files in the user's home folder. The saver therefore never evaluates policy
itself. On Macs where nobody opens the app, the `manage` LaunchAgent keeps the
snapshot current (login + hourly), so deploy that agent if you manage the
screen saver by profile.

### Provisioning a company screen saver

1. On any Mac, build the scene in Studio and save it.
2. Turn on **Settings › Admin › Admin mode**, then on the scene's card in
   ScreenSavers choose **Copy Scene for MDM**.
3. Paste the JSON as the value of `managedScreenSaverScene` (a string in a
   profile; `managed.json` also accepts it as an inline object).
4. Force `activeScreenSaverSceneID` = `managed` to make it the one that runs.

It appears on every user's ScreenSavers page as a read-only **Managed** entry.
Users can duplicate it into a personal copy unless `allowScreenSaverCreation`
is `false`. Notes for managed scenes:

- A scene that uses a specific wallpaper stores the wallpaper's ID — use a
  bundled or content-ID wallpaper present on every Mac (§7).
- Scenes that use an imported image or a non-system font only render fully
  where that image/font exists; elsewhere the icon is omitted and the font
  falls back to the system font. Prefer SF Symbols and system fonts for
  fleet-wide scenes.

### Lock tiers

| `lockMode` | Saver shows | In the app |
| --- | --- | --- |
| `off`, `enforcedRotation` | The active scene (if it exists and the allow-list permits it) | Full use, subject to the keys above |
| `soft` | The forced active scene if `activeScreenSaverSceneID` is forced, else the managed scene if provisioned, else the user's current scene | **Set Active** is greyed out; editing is still allowed |
| `hard` | A solid color only | **Set Active** greyed out; Studio's composer unavailable |

A scene with a *rotating* background draws from the same resolved rotation
pool as wallpaper rotation (§5), so `allowedWallpaperIDs` and the pool rules
apply to it.

### Per-scene tiles

A scene can appear as its own entry under System Settings › Screen Saver ›
Other — "PaperWalls – <Scene name>" with a thumbnail rendered from the scene
— so users can pick it the way they pick any other saver. Users opt a scene
in with **Show in System Settings** on its card; the managed scene is always
listed ("PaperWalls – <name> (Managed)").

How it works: the app keeps a copy of the saver embedded in its bundle and,
for each listed scene, writes a renamed, re-identified copy to
`~/Library/Screen Savers` carrying that scene's resolved snapshot and
thumbnail, re-signed ad hoc. Copies are refreshed when the scene or the
app's saver version changes, and removed when a scene is unlisted, deleted,
or no longer allowed (`screenSaverEnabled=false`, `lockMode=hard`, or an
allow-list that excludes it). Points to know:

- Copies are generated by the **app**, when it runs; `paperwallscli manage`
  does not generate them. On Macs where nobody opens the app, only the plain
  "PaperWalls" entry exists.
- Which tile is *selected* is still a macOS setting (next section).
- The plain "PaperWalls" entry keeps playing the Active scene; **Set Active**
  is unaffected.
- The uninstaller removes every generated copy.

### Selecting the saver and the idle time

Installing the pkg puts the saver in `/Library/Screen Savers`; it then appears
under **System Settings › Screen Saver › Other** as "PaperWalls". On a Mac
without the pkg, Settings › Screen Saver offers **Install for Me**,
which copies the app's embedded saver to `~/Library/Screen Savers`.

**Selecting a saver for users: `enforcedScreenSaverPath`.** Set it to a
saver's full path, e.g. `/Library/Screen Savers/PaperWalls.saver` or a saver
built with Studio › Package. The manage LaunchAgent then keeps that saver
selected for every Space and display, at login and hourly. Users can still
pick another saver in System Settings; the next run switches it back. To apply
it at once (for example from a Jamf policy run as the user), run
`paperwallscli screensaver enforce`. `paperwallscli screensaver` shows what
macOS has selected and whether it matches.

How it works: since macOS 14 the selection lives in each user's wallpaper
store, `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`,
with one entry for the system default and one for each Space, display, and
Space + display. PaperWalls rewrites every one of those entries to the
enforced saver, backs up the previous store to
`~/Library/Application Support/PaperWalls/WallpaperStore-backup.plist`, reads
the result back to verify it (restoring the backup if that fails), and
restarts `WallpaperAgent`. The store's format is undocumented: PaperWalls
leaves the file alone and logs an error (category `saverselection`) if it
finds a layout it doesn't recognize. Verified on macOS 27.

**Locking it: Apple's `moduleName`.** A `com.apple.screensaver` profile (or a
DDM declaration carrying one) that forces `moduleName` to the saver's name
stops users choosing another saver: System Settings snaps straight back. On
macOS 14 and later it does **not** select a third-party saver by itself; it
only locks one that's already selected. Deploy both for a saver that is
selected and can't be changed:

| Part | Setting | Does |
|---|---|---|
| Select | `enforcedScreenSaverPath` = `/Library/Screen Savers/Acme – Lobby.saver` | PaperWalls writes the selection for every Space and display |
| Lock | `com.apple.screensaver` `moduleName` = `Acme – Lobby` | macOS stops users changing it |

`moduleName` is the saver's name without `.saver` (its bundle name). Studio ›
Package's **Enforce a saver** option generates both profiles. Verified on
macOS 27.

`Deployment/com.herojoneslabs.paperwalls.screensaver.mobileconfig` is a
reference `com.apple.screensaver.user` payload with `moduleName`,
`modulePath`, and `idleTime`. Its `moduleName` locks as described above; it
doesn't select the saver on macOS 14+. It's also the supported way to set
the idle time, which PaperWalls deliberately has no key for.

### macOS's own clock over the saver

Since macOS 14, System Settings › Wallpaper › **Clock Appearance…** (also
under Lock Screen) has **Show large clock**: *On Screen Saver and Lock
Screen*, *On Lock Screen*, or *Never*. With either of the first two,
loginwindow draws a large clock over whatever screen saver is running — so a
PaperWalls scene with a clock layer shows two clocks. That popup is two
settings:

| Half of the popup | Key | Where | Who reads it |
|---|---|---|---|
| On Screen Saver | `showClock` (bool) | `com.apple.screensaver`, per user and per host (`~/Library/Preferences/ByHost/com.apple.screensaver.<hardware-UUID>.plist`) | the saver host and loginwindow |
| On Lock Screen | `UsesLargeDateTime` (bool) | `/Library/Preferences/com.apple.loginwindow.plist`, system level, admin-authenticated | loginwindow's lock UI |

Both halves matter: the saver keeps playing behind the lock screen (a mouse
shake or key press brings the lock screen up over the running saver), so a
clock scene shows two clocks there too. The screen saver half is a user-level
key; the lock screen half is system-level and needs root — System Settings
asks for an administrator to change it, and so does PaperWalls. Two ways to
turn them off; pick the one that fits how you manage the fleet:

| Delivery | Setting | Does | Needs PaperWalls on the Mac |
|---|---|---|---|
| Profile | `com.apple.screensaver` `showClock` = `false` and `com.apple.loginwindow` `UsesLargeDateTime` = `false` (two payloads in one profile) | Always off, locked; users can't turn either back on | No |
| PaperWalls | `hideSystemSaverClock` = `whenSceneHasClock` (or `always`); `hideSystemSaverClockOnLockScreen` = `false` to leave the lock screen alone | The app and the manage agent turn the screen saver clock off while the selected saver is a PaperWalls saver whose scene draws a clock, and put the user's value back when it isn't; `always` keeps it off. The lock screen half is applied whenever the CLI runs as root: the PaperWalls pkg postinstall, `paperwallscli screensaver enforce` from a Jamf policy, or the **Apply as Admin…** button in Settings › Screen Saver. Users can change the saver half until the next run (login, hourly) | Yes (0.8+) |

PaperWalls remembers the values it replaced (the saver half per host in the
user's layer, the lock screen half in `/Library/Preferences`) and restores
them when the policy stops applying — it never touches a value the user had
already turned off, never one a profile forces (the profile wins;
`paperwallscli screensaver` says so), and never pretends to write what it
can't: when the lock screen half is owed and nothing with root has run yet,
the CLI and Settings say so. The "selected saver" is `enforcedScreenSaverPath`
when set, else what macOS has selected. Run as root, the CLI reads the
policy and the scene for the console user (their own Settings choice counts,
under any forced MDM or `managed.json` value), not for root. Deployed scene bundles carry their scene; for `PaperWalls.saver`
itself the published snapshot is used (the built-in Minimal Clock counts as a
clock). Users see the same choice in Settings › Screen Saver › **macOS clock
over the saver**, with **Also on the lock screen** and a **Lock screen clock**
status row; forcing the keys manages them. The screen saver half takes effect
the next time the saver starts (verified on macOS 27); the lock screen half
and the profile delivery are unverified as of 0.8. Studio › Package's **macOS
clock over the saver** option generates either delivery (see Packaging
below); on the reference `com.herojoneslabs.paperwalls.screensaver.mobileconfig`
the keys are shown commented out.

**Keeping it off.** With the PaperWalls delivery, a user can turn a clock
back on in System Settings › Wallpaper (or Lock Screen) › Clock Appearance.
Three ways to stop that, usable together:

| Option | How | Notes |
|---|---|---|
| Lock the keys | Deploy the *Profile: always off* delivery (forced `showClock` / `UsesLargeDateTime`) | The real lock: System Settings snaps back. Needs no PaperWalls on the Mac |
| Clock watchers | The PaperWalls pkg installs `com.herojoneslabs.paperwalls.saverclock` (LaunchAgent, user) and `com.herojoneslabs.paperwalls.lockscreenclock` (LaunchDaemon, root), both running `paperwallscli screensaver clock --watch` | Reversion, not prevention: cfprefsd replaces the plist files atomically, so a directory watch on `~/Library/Preferences/ByHost`, the wallpaper store and `/Library/Preferences` re-applies the policy within about a second of a change (plus a 5-minute safety sweep). Both idle when the policy is `never`. Set `INSTALL_CLOCK_WATCHERS=false` in `build-pkg.sh` to leave them out |
| Hide the panes | A System Settings restrictions payload (`com.apple.systempreferences` `DisabledPreferencePanes`) listing `com.apple.Wallpaper-Settings.extension` and `com.apple.Lock-Screen-Settings.extension` | Removes the Clock Appearance popover from both panes, and the rest of those panes with it — fine when PaperWalls is the only sanctioned way to pick wallpapers and savers |

The saver's tile in System Settings is a fixed image shipped inside the
bundle (a clock on a coral gradient), not a live view of the active scene.
macOS caches a saver's tile by bundle: after replacing the saver with a
build whose thumbnail changed, the old tile can persist until the bundle is
renamed or the Mac restarts.

### Brand assets (Admin mode)

Scenes often need the organization's artwork — a logo for the lobby saver,
a white variant for dark backgrounds, an app icon for a help-desk
wallpaper. Rather than choosing the file every time, keep them in Studio:
turn on **Settings › Admin › Admin mode** and open **Studio › Assets**.

- **Add Images…** (or drop files or a folder on the tab) copies each image
  into the Studio asset store and lists it with a name taken from the file
  name (`acme-logo-white.png` → "Acme Logo White") and a kind guessed from
  it (Logo, Icon, or Image). Rename or change the kind from the card's
  menu. Add as many variations as you need; the same bytes are stored once.
- In the composer, every **Icon** layer and the **Background › Image**
  source show a **Brand Assets** strip. One click uses the asset; the
  scene refers to the image file, exactly as if it had been chosen with
  **Choose Image…**, so savers, wallpapers, deployed bundles, and `managed`
  scenes all render it without any extra step. Packaging embeds the image
  files a scene uses (`Resources/Media/Assets/`).
- **Delete…** removes the library entry. The image file is deleted too,
  unless a saved screen saver, wallpaper design, or open draft still uses
  it — those keep working and the dialog says what uses it.

The library is per user (`~/Library/Application Support/PaperWalls/Studio/BrandAssets/`).
What reaches other Macs — the rendered wallpaper, the packaged saver, the
`managedScreenSaverScene` JSON — never depends on it, so for an admin who
composes everything centrally that is all you need. Keep `adminModeEnabled`
forced `false` on end-user Macs.

**Fleet-wide assets (`brandAssetsFolderPath`).** To give every user the
organization's artwork in their own composer, deploy a folder of images
(e.g. `/Library/CompanyBrand`, readable by everyone; a pkg or your MDM's
file distribution both work) and set `brandAssetsFolderPath` to it in the
profile or `managed.json`. Then:

- The folder is scanned one level deep for `.png .jpg .jpeg .heic .tiff .gif`
  (hidden files skipped). Each image is named from its file name
  (`acme-logo-white.png` → "Acme Logo White") and sorted into Logo / Icon /
  Image by words like `logo`, `wordmark`, `icon`, `glyph` in the name, so
  name the files the way you want them listed.
- Every user sees them in the composer's **Brand Assets** strip (no Admin
  mode needed). In Admin mode they also appear under **Studio › Assets ›
  Organization assets**, read-only, with **Add to My Library** to
  take a copy into the editable library.
- Using one copies the image into the user's Studio asset store (content-
  addressed), so scenes, deployed bundles, and the `managed` scene keep
  working if the folder is later changed or removed. Byte-identical files
  are listed once, and a managed image already in the user's library is
  shown once, from the library.
- The folder is rescanned with every managed-config reload (profile or
  `managed.json` change, app activation), so a folder deployed after launch
  appears when the user next switches to the app. An empty, missing, or
  unreadable folder shows a note on the Assets tab and no strip in the
  composer.

### Packaging screen savers for deployment (Admin mode)

The managed scene above runs *inside* PaperWalls. To ship scenes as ordinary
screen savers that don't need the app, turn on **Settings › Admin › Admin
mode** and open **Studio › Package** (or choose **Package for Deployment…** on
a card):

1. Tick one or more screen savers. Each becomes its own saver; edit the name
   it shows in System Settings (default "*Company* – *Scene*").
2. Set the package name and version. The pkg identifier is
   `com.herojoneslabs.paperwalls.savers.<name>`. Raise the version for each
   change you ship.
3. Optionally pick signing identities from your keychain: a Developer ID
   Application certificate for the savers (hardened runtime + timestamp) and a
   Developer ID Installer certificate for the pkg. Without them the savers are
   signed ad hoc and the pkg is unsigned. Jamf Pro installs that as-is; MDM
   `InstallEnterpriseApplication` needs a signed pkg.
4. **Build Package…** and choose a folder. You get:

   | Item | What it is |
   |---|---|
   | `<Name>-<version>.pkg` | Installs every saver to `/Library/Screen Savers` (not relocatable) |
   | `Savers/` | The same bundles, for tools that copy files |
   | `MDM/` | Optional `managedScreenSaverScene` JSON per scene |
   | `Enforce/` | Optional: a PaperWalls profile and `managed.json` setting `enforcedScreenSaverPath` (selects the saver; needs PaperWalls 0.3.3+ with the manage agent) and a `com.apple.screensaver` profile forcing `moduleName` (locks it). Deploy both. Also optional, from **macOS clock over the saver**: either a profile forcing `com.apple.screensaver` `showClock = false` and, with **Also on the lock screen**, `com.apple.loginwindow` `UsesLargeDateTime = false` (*Profile: always off*), or `hideSystemSaverClock = whenSceneHasClock` (plus `hideSystemSaverClockOnLockScreen = false` when the lock screen is left alone) added to the PaperWalls profile and `managed.json` — or in their own pair when no saver is enforced (*PaperWalls: off when the scene has a clock*; needs PaperWalls 0.8+) |
   | `DEPLOY.txt` | Contents, signing state, notarization commands, removal steps |

Each saver carries its own copy of the images its scene uses (a chosen
wallpaper, the current rotation pool, imported icons), so it looks the same on
every Mac. "Current desktop" scenes follow each Mac's own wallpaper. The
company name is baked in at build time. Deployed savers use the identifier
prefix `com.herojoneslabs.paperwalls.saver.deployed.`, so they never clash
with a user's own per-scene tiles. Installing a newer version doesn't remove
savers you dropped from the package. Remove them with the commands in
`DEPLOY.txt`, or set `REMOVE_DEPLOYED_SAVERS=true` in `uninstall.sh`.

Notarize by signing both parts, then running the `notarytool` commands from
`DEPLOY.txt`. The app doesn't notarize for you.

### Packaging wallpapers for deployment (Admin mode)

The same tab has a **Wallpapers** side: pick wallpapers from any source in
your library (bundled, macOS, feeds, the managed folder, personal) and ship
them as the **Managed folder** source (§4) on other Macs. Open **Studio ›
Package › Wallpapers**, or choose **Package for Deployment…** in a
wallpaper's detail sheet:

1. Tick the wallpapers. Filter by source or search; edit the file name each
   one gets on the target Macs (that name is what the app shows).
2. Set the package name, version, and the **install folder**. If your
   organization already deploys a wallpaper folder (this Mac's
   `externalWallpaperFolderPath`, e.g. `/Library/CompanyWallpapers`), the field
   starts out pointing there and the pkg adds the images to it; otherwise the
   default is `/Library/Application Support/PaperWalls/Wallpapers`. Type any
   absolute path outside a user's home folder, or **Choose…** one. The pkg
   identifier is `com.herojoneslabs.paperwalls.wallpapers.<name>`.
3. Optionally pick a Developer ID Installer certificate for the pkg. Images
   aren't code, so nothing else is signed.
4. Under **Also include**, keep **Configuration profile** on to get the
   settings that make the folder appear in PaperWalls, and optionally choose a
   **Default wallpaper** (`selectedWallpaperID`), a **Lock** tier (`lockMode`;
   soft and hard need a default), and **Only these wallpapers**
   (`allowedWallpaperIDs`, which hides every other source).
5. **Build Package…** and choose a folder. You get:

   | Item | What it is |
   |---|---|
   | `<Name>-<version>.pkg` | Installs the images to the install folder (root:wheel, world-readable) |
   | `Wallpapers/` | The same files, for tools that copy files |
   | `Configure/` | Optional: a `com.herojoneslabs.paperwalls` profile and `managed.json` forcing `externalWallpaperFolderPath` plus whatever you chose in step 4 |
   | `DEPLOY.txt` | Contents, every wallpaper's content ID, signing state, notarization commands, removal steps |

The pkg only puts files on disk; nothing changes on the desktop until
PaperWalls is pointed at the folder. Deploy the `Configure/` profile (or copy
`managed.json` to `/Library/Application Support/PaperWalls/` on Macs without
MDM), or set `externalWallpaperFolderPath` in the PaperWalls profile you
already manage — don't force the same key from two profiles. A default
wallpaper is applied by the `manage` LaunchAgent at login and hourly, or at
once with `paperwallscli manage`.

Wallpaper IDs are content-derived (§7), and the pkg copies the files byte for
byte, so the IDs listed in `DEPLOY.txt` are the IDs every target Mac resolves —
use them in your own profiles too. Installing a newer version doesn't remove
wallpapers you dropped from the package; remove the folder with the commands
in `DEPLOY.txt`.

### Publishing to Jamf Pro (Admin mode)

Both Package flavors can hand their output straight to Jamf Pro instead of
(or as well as) leaving it in a folder. It is off by default and gated three
ways: Admin mode, the `jamfPublishEnabled` switch, and one toggle per kind of
upload — all of them managed keys, so a fleet profile can force the feature
off (or allow packages but not profiles) on every Mac.

**Set it up once, on the admin's Mac.** In Jamf Pro create an API Role with
the privileges below and an API Client that uses it; copy the client ID and
generate the client secret. Then in PaperWalls, **Settings › Admin**:

1. Turn on **Admin mode** and **Publish to Jamf Pro**.
2. Leave **Packages** and **Configuration profiles** on, or turn off the kind
   you don't want this Mac to upload.
3. Enter the **Jamf Pro server** (`https://yourorg.jamfcloud.com`; the field
   suggests this Mac's own enrollment URL) and the **API client ID**, paste
   the **client secret**, and press **Test Connection**. The test obtains a
   token, reads the Jamf Pro version, and invalidates the token.

The server and client ID are stored in the user layer of the preference
domain (`jamfServerURL`, `jamfClientID`), the secret in the login Keychain.
None of the three is a `ManagedPreferenceKey`: they can't be set by a
profile or `managed.json`, so a managed Mac can never be pointed — together
with its stored secret — at a server the admin didn't type.

| Upload | API | Privileges the API Role needs |
|---|---|---|
| Installer package | `POST /api/v1/packages` (record), `POST /api/v1/packages/{id}/upload` (file); `GET`/`PUT /api/v1/packages/{id}` when changing an existing record's category | Read Packages, Create Packages, Update Packages |
| Configuration profile | `GET/POST/PUT /JSSResource/osxconfigurationprofiles` | Read, Create, Update macOS Configuration Profiles |
| Category picker | `GET /api/v1/categories` | Read Categories (optional; without it the picker offers only "None") |
| Scope picker | `GET /api/v1/computer-groups` | Read Smart Computer Groups, Read Static Computer Groups (optional; without them the picker offers "Leave as is" and "All computers") |
| Test Connection | `GET /api/v1/jamf-pro-version` | none beyond a valid client |

Package uploads need Jamf Pro 11.5 or later and a cloud distribution point
(Jamf Cloud, or a cloud DP as the primary); Jamf Pro copies the file there
after the upload.

**Publishing.** After **Build Package…** finishes, a **Publish to Jamf Pro**
card lists what the build left on disk: the pkg, and each `.mobileconfig` in
`Enforce/` (screen savers: select + lock) or `Configure/` (wallpapers).
The card also reads your categories and computer groups (one token, released
right after) and offers:

- **Category** — applied to the package record and every published profile.
  "None / leave as is" gives new objects no category and leaves existing
  ones alone.
- **Profile scope** (shown when a profile is ticked) — **Leave as is** (new
  profiles unscoped, updated profiles keep their scope), **All computers**,
  or **Computer groups** with a searchable checklist of smart and static
  groups. A chosen scope replaces an updated profile's *targets*; its
  exclusions and limitations are untouched. Packages have no scope in Jamf
  Pro — a policy carries it — so the picker never affects the pkg.

Untick what you don't want, press **Publish**, and the app:

- signs in with the client credentials (one token per publish, invalidated
  when done, success or failure);
- for the package, looks up a record with the pkg's name
  (`<Name>-<version>`), creates one if there isn't (no category, priority
  10, build notes), and uploads the file. Each version is its own record;
  publishing the same version again replaces its file;
- for each profile, looks it up by its display name and creates it, or
  updates it if it exists. New profiles are **computer level, install
  automatically, and not user-removable**, with the category and scope you
  chose (unscoped by default — scope them in Jamf Pro). Updating with
  "Leave as is" keeps the existing category and scope;
- shows each object's Jamf Pro ID with an **Open in Jamf Pro** button.

Nothing else changes in Jamf Pro: no policy is created or scoped. Errors
name the step and the HTTP status (401 bad credentials, 403 a missing
privilege, 404 an endpoint this Jamf Pro version lacks). Keep
`jamfPublishEnabled` forced `false` on end-user Macs along with
`adminModeEnabled`.

### Verifying a new macOS version

The design depends on the saver host being able to read the user's home
folder. That was verified on macOS 27; before deploying to another major
version, install a **Debug** build of the saver, preview it once, and read the
access report it logs:

```sh
log show --last 10m --predicate 'subsystem == "com.herojoneslabs.paperwalls" AND category == "saverprobe"' --style compact
```

Release builds contain no probe.
