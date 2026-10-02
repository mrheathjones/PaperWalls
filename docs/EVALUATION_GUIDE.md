# PaperWalls — Setup & Evaluation Guide

A short path from "I have the .pkg" to "it's working as a managed app on my
test Mac." Aimed at an admin evaluating PaperWalls at their organization.

For the full key reference, lock tiers, feed hosting, logging, and
troubleshooting, see **`ADMIN_GUIDE.md`** — this guide only gets you running.

- **What it is:** a macOS wallpaper manager for managed fleets — a SwiftUI app,
  a `desktoppr`-style CLI, and one MDM preference domain.
- **You supply:** a test Mac (macOS 13+) and, ideally, your MDM (Jamf or any
  profile-delivery tool). It also runs fully standalone on an unmanaged Mac.
- **You do NOT rebuild or rebrand anything.** The app ships signed, with a fixed
  vendor bundle ID (`com.herojoneslabs.paperwalls`) — exactly like Nudge
  (`com.github.macadmins.Nudge`) or Root3's SupportApp (`nl.root3.support`). You
  consume it and target that domain from a config profile. Nothing gets forked.

---

## 1. Install (2 min)

Install the pkg with your MDM, or by hand on a test Mac:

```bash
sudo installer -pkg PaperWalls-1.0-d.16.pkg -target /
```

What lands:

| Path | What |
| --- | --- |
| `/Applications/PaperWalls.app` | The app (Developer ID signed, hardened runtime — runs on any Mac) |
| `/usr/local/bin/paperwallscli` | CLI, same rules and preferences as the app |
| `/Library/LaunchAgents/com.herojoneslabs.paperwalls.manage.plist` | Optional agent that converges managed selections without the app open |

A postinstall bootstraps the agent into the logged-in session, so it starts
converging without a logout. Note: the app is **not sandboxed** (it must set the
desktop picture and scan folders) — expect that in a security review.

**Smoke test — no config yet:**

```bash
open -a PaperWalls          # launches; browse/set bundled wallpapers
paperwallscli version
paperwallscli get           # prints the current desktop picture path
```

If that works, the binary is healthy. Now make it *managed*.

---

## 2. Deploy a config profile (5 min)

Every setting lives in the `com.herojoneslabs.paperwalls` domain. A profile that
**forces** a key makes it read-only in the app (greyed, "Managed by your
organization" badge); the app live-reloads within ~1 s of the profile landing —
no relaunch.

### Jamf Pro (recommended)

1. **Configuration Profiles → Application & Custom Settings → External
   Applications → Custom Schema.**
2. Preference domain: `com.herojoneslabs.paperwalls`
3. Upload the schema: **`Deployment/com.herojoneslabs.paperwalls.schema.json`**.
   Jamf renders every key as a labeled form control — toggle on only the keys
   you want to force.
4. Scope to your test Mac and push.

### Any MDM (raw profile)

Start from **`Deployment/com.herojoneslabs.paperwalls.mobileconfig`** — it's a
ready-to-edit template. Delete the keys you don't want to force (unforced keys
stay user-editable), set `PayloadOrganization`, and upload it. A minimal
"prove it's managed" profile forces just two keys:

```xml
<key>com.herojoneslabs.paperwalls</key>
<dict>
  <key>Forced</key>
  <array><dict>
    <key>mcx_preference_settings</key>
    <dict>
      <key>companyName</key>            <string>Acme Corp</string>
      <key>selectedWallpaperID</key>    <string>bundled-aurora-veil</string>
    </dict>
  </dict></array>
</dict>
```

(Deliver it **Forced**, `PayloadScope` = `System`. Jamf's Custom Settings does
this for you.)

### No MDM handy? Local admin file

For a quick test with no MDM at all, drop a file at
`/Library/Application Support/PaperWalls/managed.json` (admin-writable):

```json
{
  "forced":   { "companyName": "Acme Corp", "lockMode": "soft" },
  "defaults": { "autoRotateIntervalMinutes": 60 }
}
```

`forced` behaves like an MDM-forced key; `defaults` seeds values the user can
still change. Sample: `Deployment/managed.json.example`.

---

## 3. Verify it took (2 min)

Open PaperWalls and confirm:

- The sidebar/labels show **your `companyName`** (e.g. "Acme Corp"), and the
  forced keys render **disabled with the managed badge**.
- A forced `selectedWallpaperID` was applied to the desktop.

On-device checks:

```bash
# The managed plist actually landed (managed values do NOT show in `defaults read`):
sudo ls "/Library/Managed Preferences/"

# What the app decided and why:
log show --last 10m --predicate 'subsystem == "com.herojoneslabs.paperwalls"' --style compact
```

If the app shows no badge, the payload almost certainly isn't **Forced** or
isn't targeting the exact domain string — see `ADMIN_GUIDE.md` §11.

---

## 4. Try the pieces worth evaluating

Pick what's relevant to your org. Each is one or two keys — full details and
defaults in `ADMIN_GUIDE.md` §3.

| Want to test… | Set | Notes |
| --- | --- | --- |
| **Company wallpapers** | `externalWallpaperFolderPath` = `/Library/CompanyWallpapers` | Deploy the images separately; scanned as the "Managed" source |
| **Locking the choice** | `lockMode` = `soft` / `hard` / `enforcedRotation` | `soft` = only the managed pick applies; `hard` = fully pinned. See §5 for the three enforcement tiers |
| **Auto-rotation** | `autoRotateEnabled` = true, `rotationPool` = e.g. `["bundled","favorites"]` | `autoRotateIntervalMinutes` sets cadence |
| **Air-gap / no network** | `appCuratedEnabled`=false, `orgCatalogEnabled`=false, `allowSystemWallpaperDownloads`=false | With these off + no folders, the app and CLI make **zero** network requests |
| **Your own remote feed** | `orgCatalogEnabled` + `orgCatalogURL` + `orgCatalogPublicKey` | Host your own signed catalog — see `ADMIN_GUIDE.md` §6 |

Two defaults to know going in: the app's own **curated feed is off by default**
(`appCuratedEnabled=false`), so you never touch the vendor's feed unless you opt
in; and Apple built-in wallpaper **downloads** hit `mesu.apple.com` /
`updates.cdn-apple.com` — allow-list those or set
`allowSystemWallpaperDownloads=false` on restricted networks.

---

## 5. Uninstall / reset

```bash
sudo rm -rf /Applications/PaperWalls.app
sudo rm -f  /usr/local/bin/paperwallscli
sudo rm -f  /Library/LaunchAgents/com.herojoneslabs.paperwalls.*.plist
# per-user caches/library (safe to remove; the app rebuilds caches):
rm -rf ~/Library/Application\ Support/PaperWalls
# and remove the config profile via your MDM (or delete /Library/Application Support/PaperWalls/managed.json)
```

---

## Where to go next

- **`ADMIN_GUIDE.md`** — every preference key, the three lock tiers, feed
  hosting, unified-logging predicates, proxy allow-list, and a full
  troubleshooting matrix.
- **`Deployment/`** — the schema, profile templates, `managed.json.example`,
  the lock (`.lock.mobileconfig`) reference profile, and `build-pkg.sh`.
- Questions or something behaving oddly: grab
  `log show --last 30m --predicate 'subsystem == "com.herojoneslabs.paperwalls"' --style compact`
  and send it over — it says exactly what the app resolved and why.
