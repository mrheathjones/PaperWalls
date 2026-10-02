# PaperWalls — Administrator Guide

PaperWalls is a macOS wallpaper manager built for managed fleets: a SwiftUI
app, a `desktoppr`-style command-line tool, and a preference surface designed
for MDM (every setting is a key in one preference domain, forceable by a
configuration profile). It also works fully standalone on unmanaged Macs.

- App: `/Applications/PaperWalls.app` (bundle ID `com.herojoneslabs.paperwalls`)
- CLI: `/usr/local/bin/paperwallscli`
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

A postinstall script bootstraps the included LaunchAgent(s) into the console
user's session immediately, so settings converge without a logout/login.
Building your own pkg: `Deployment/build-pkg.sh` (configure the CONFIG block;
`INSTALL_WATCH_AGENT=true` adds the watcher agent to the payload).

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
is also in `Deployment/`.

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

---

## 4. Wallpaper sources

The library merges up to six sources, each independently gated:

| Source | Gate | Content |
| --- | --- | --- |
| Bundled | `showBundledWallpapers` | Curated set inside the app bundle |
| macOS | `showSystemWallpapers` | Apple's built-ins from `/System/Library/Desktop Pictures`. Flat images apply directly; the rest are offered as **on-demand downloads** from Apple's CDN (gated by `allowSystemWallpaperDownloads`). If the Mac's own Apple asset catalog is missing (common on freshly provisioned machines), the app fetches Apple's public catalog copy once |
| Curated feed | `appCuratedEnabled` | Remote feed published by the PaperWalls project (Ed25519-signed manifest, sha256-verified assets, cached locally) |
| Org feed | `orgCatalogEnabled` + URL + key | Your organization's own signed remote feed — §6 |
| Managed folder | `externalWallpaperFolderPath` | A folder you deploy (e.g. `/Library/CompanyWallpapers`), scanned non-recursively for `.jpg .jpeg .png .heic .tiff` |
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
| `/Library/Application Support/PaperWalls/managed.json` | Optional local admin config (admin-writable) |

Deleting any per-user cache is safe — the app rebuilds it.

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
| User settings "snap back" | The key is forced (MDM or local `forced`) — writes to forced keys are dropped by design |

### Locks and enforcement

| Symptom | Check |
| --- | --- |
| `paperwallscli set` exits 6 | Working as intended under soft/hard/enforcedRotation. `manage` is the sanctioned path |
| Watcher never reverts | It only enforces under `lockMode=enforcedRotation`. Verify: agent loaded (`launchctl print gui/$(id -u)/com.herojoneslabs.paperwalls.watch`), running as the console user (never root — exit 5), and the resolved rotation pool isn't empty (empty pool = nothing approved = watcher no-op) |
| Watcher/rotation fight the desktop | You deployed the Tier-2 OS override **and** `enforcedRotation` together. Don't — the app detects the OS restriction, treats the Mac as hard-locked, and the watcher stands down, but the OS profile should simply not be combined with rotation |
| App shows "App-only" instead of "Enforced by configuration profile" | The Tier-2 profile isn't on the device (or doesn't set `allowWallpaperModification=false` / a `com.apple.desktop` override). `enforcement` log category shows what was detected |

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
