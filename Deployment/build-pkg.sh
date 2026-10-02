#!/bin/bash
#
# build-pkg.sh — build a PaperWalls distribution .pkg for a release channel.
#
# Designed to run straight from CodeRunner (or by double-click) — configure it
# with the CONFIG block below instead of command-line flags. Everything else
# (app name, bundle id, built paths, base version) is derived from the Xcode
# project via `xcodebuild -showBuildSettings -json`.
#
# Payload (installed relative to /):
#   /Applications/PaperWalls.app
#   /usr/local/bin/paperwallscli
#   /Library/LaunchAgents/com.herojoneslabs.paperwalls.manage.plist   (optional)
#   /Library/LaunchAgents/com.herojoneslabs.paperwalls.watch.plist    (optional, Tier-3 fleets)
# A postinstall script bootstraps the LaunchAgent(s) into the console user's
# gui domain so they start converging without a logout/login.
#
#   Version scheme (composed from the project's Version + Build):
#     0.1.0-d.x  Dev team machines   (CHANNEL="dev")
#     0.1.0-a.x  Alpha testers       (CHANNEL="alpha")
#     0.1.0-b.x  Beta group          (CHANNEL="beta")
#     0.1.0-u.x  UAT                 (CHANNEL="uat")
#     1.0.0      GA to all           (CHANNEL="ga")
#   where 0.1.0 = MARKETING_VERSION and x = CURRENT_PROJECT_VERSION (numeric build).
#   The channel version is injected into CFBundleShortVersionString (shown in the
#   app's About screen); CFBundleVersion stays the numeric build.

set -euo pipefail

# ======================= CONFIG — edit these ========================

# Release channel: dev | alpha | beta | uat | ga
CHANNEL="dev"

# Path to the .xcodeproj. Empty = auto-find the single .xcodeproj next to this
# script's parent folder.
PROJECT=""

# Scheme names. The project has two — the app and the CLI — so both are pinned
# here instead of auto-detected.
APP_SCHEME="PaperWalls"
CLI_SCHEME="paperwallscli"

# Output directory for the .pkg. Empty = "<project folder>/dist".
OUTPUT=""

# Include the LaunchAgent (+ postinstall bootstrap) in the pkg payload.
# Set false to ship just the app + CLI and manage the agent some other way.
INSTALL_LAUNCHAGENT=true

# Include the Tier-3 watch LaunchAgent (spec §7). Default false — deploy it
# only to fleets that use lockMode=enforcedRotation (the watcher idles in
# every other mode, but there's no reason to run it elsewhere). Never
# combine with the Tier-2 desktop-override profile.
INSTALL_WATCH_AGENT=false

# --- App signing ---------------------------------------------------
# Sign the APP + CLI with a Developer ID Application identity + hardened runtime.
# Empty = use the project's own signing settings (fine for dev-team machines).
APP_IDENTITY=""                     # e.g. "Developer ID Application: Your Name (TEAMID)"

# --- App notarization (NOT the pkg) --------------------------------
# true  = notarize + staple the .app itself (requires APP_IDENTITY).
# Only needed if the app may arrive via a quarantine channel (download/AirDrop).
# NOT required for plain Jamf policy installs.
NOTARIZE=false
NOTARY_PROFILE="PaperWalls-Notary"  # notarytool keychain profile name

# --- Pkg signing ---------------------------------------------------
# true  = sign the .pkg with a Developer ID Installer identity.
SIGN_PKG=false
PKG_IDENTITY=""                     # empty = auto-detect "Developer ID Installer: …"

# --- Versioning ----------------------------------------------------
# true = after a successful build, bump CURRENT_PROJECT_VERSION in the project.
# (The sed hits every occurrence, which keeps the app and CLI targets in sync.)
BUMP=true

# ===================================================================

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '==> %s\n' "$*"
}

require() {
    if ! command -v "$1" >/dev/null 2>&1
    then
        die "required tool not found: $1"
    fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

require xcodebuild
require jq
require pkgbuild
require productbuild

# xcodebuild must be backed by a full Xcode, not just Command Line Tools.
if ! xcodebuild -version >/dev/null 2>&1
then
    die "xcodebuild can't run (active developer dir: $(xcode-select -p 2>/dev/null)). Point the CLI at Xcode in Terminal:  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi

# ---------------------------------------------------------------------------
# Channel → suffix letter
# ---------------------------------------------------------------------------
case "$CHANNEL" in
    dev)
        CH="d"
        ;;
    alpha)
        CH="a"
        ;;
    beta)
        CH="b"
        ;;
    uat)
        CH="u"
        ;;
    ga)
        CH="ga"
        ;;
    *)
        die "invalid CHANNEL: '$CHANNEL' (use dev|alpha|beta|uat|ga)"
        ;;
esac

# ---------------------------------------------------------------------------
# Resolve the project
# ---------------------------------------------------------------------------
if [[ -z "$PROJECT" ]]
then
    shopt -s nullglob
    candidates=( "$SCRIPT_DIR"/../*.xcodeproj )
    shopt -u nullglob
    if [[ ${#candidates[@]} -ne 1 ]]
    then
        die "could not auto-find a single .xcodeproj in $SCRIPT_DIR/.. — set PROJECT in the config block"
    fi
    PROJECT="${candidates[0]}"
fi
[[ -d "$PROJECT" ]] || die "project not found: $PROJECT"
PROJECT="$(cd "$(dirname "$PROJECT")" && pwd)/$(basename "$PROJECT")"
PROJECT_ROOT="$(dirname "$PROJECT")"
[[ -n "$OUTPUT" ]] || OUTPUT="$PROJECT_ROOT/dist"

AGENT_PLIST_SRC="$PROJECT_ROOT/Deployment/com.herojoneslabs.paperwalls.manage.plist"
if [[ "$INSTALL_LAUNCHAGENT" == "true" && ! -f "$AGENT_PLIST_SRC" ]]
then
    die "LaunchAgent plist not found: $AGENT_PLIST_SRC (set INSTALL_LAUNCHAGENT=false to skip)"
fi

WATCH_PLIST_SRC="$PROJECT_ROOT/Deployment/com.herojoneslabs.paperwalls.watch.plist"
if [[ "$INSTALL_WATCH_AGENT" == "true" && ! -f "$WATCH_PLIST_SRC" ]]
then
    die "watch LaunchAgent plist not found: $WATCH_PLIST_SRC (set INSTALL_WATCH_AGENT=false to skip)"
fi

# ---------------------------------------------------------------------------
# Validate signing/notarization config early
# ---------------------------------------------------------------------------
if [[ "$NOTARIZE" == "true" && -z "$APP_IDENTITY" ]]
then
    die "NOTARIZE=true requires APP_IDENTITY (Developer ID Application + hardened runtime)"
fi

# ---------------------------------------------------------------------------
# Derive metadata from the project (resolved build settings)
# ---------------------------------------------------------------------------
# Build OUTSIDE iCloud. Putting DerivedData inside an iCloud-synced folder makes
# codesign fail with "resource fork, Finder information, or similar detritus not
# allowed" (iCloud stamps xattrs on the build output), and needlessly syncs GBs
# of intermediates. Use a local, non-synced location instead.
DERIVED="$HOME/Library/Developer/PaperWalls-build"
info "Reading build settings (scheme: $APP_SCHEME)…"
SETTINGS="$(xcodebuild -showBuildSettings -json \
    -project "$PROJECT" -scheme "$APP_SCHEME" -configuration Release \
    -derivedDataPath "$DERIVED" 2>/dev/null)"

read_setting() {
    jq -r --arg k "$1" '.[0].buildSettings[$k] // empty' <<<"$SETTINGS"
}

BASE_MARKETING="$(read_setting MARKETING_VERSION)"
BASE_BUILD="$(read_setting CURRENT_PROJECT_VERSION)"
BUNDLE_ID="$(read_setting PRODUCT_BUNDLE_IDENTIFIER)"
PRODUCT_NAME="$(read_setting PRODUCT_NAME)"
FULL_PRODUCT_NAME="$(read_setting FULL_PRODUCT_NAME)"
BUILT_PRODUCTS_DIR="$(read_setting BUILT_PRODUCTS_DIR)"

[[ -n "$BASE_MARKETING" ]] || die "MARKETING_VERSION is empty — set the target's Version in Xcode (e.g. 0.1.0)"
[[ -n "$BASE_BUILD" ]]     || die "CURRENT_PROJECT_VERSION is empty — set the target's Build in Xcode (e.g. 1)"
[[ "$BASE_BUILD" =~ ^[0-9]+$ ]] || die "CURRENT_PROJECT_VERSION must be a plain integer (got: $BASE_BUILD)"
[[ -n "$FULL_PRODUCT_NAME" && -n "$BUILT_PRODUCTS_DIR" ]] || die "could not resolve product name/path from build settings"

info "Reading build settings (scheme: $CLI_SCHEME)…"
CLI_SETTINGS="$(xcodebuild -showBuildSettings -json \
    -project "$PROJECT" -scheme "$CLI_SCHEME" -configuration Release \
    -derivedDataPath "$DERIVED" 2>/dev/null)"
CLI_PRODUCT_NAME="$(jq -r '.[0].buildSettings.FULL_PRODUCT_NAME // empty' <<<"$CLI_SETTINGS")"
CLI_PRODUCTS_DIR="$(jq -r '.[0].buildSettings.BUILT_PRODUCTS_DIR // empty' <<<"$CLI_SETTINGS")"
[[ -n "$CLI_PRODUCT_NAME" && -n "$CLI_PRODUCTS_DIR" ]] || die "could not resolve CLI product name/path from build settings"

# ---------------------------------------------------------------------------
# Compose the channel version
# ---------------------------------------------------------------------------
if [[ "$CH" == "ga" ]]
then
    FULL_VERSION="$BASE_MARKETING"
else
    FULL_VERSION="${BASE_MARKETING}-${CH}.${BASE_BUILD}"
fi

APP_PATH="$BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME"
CLI_PATH="$CLI_PRODUCTS_DIR/$CLI_PRODUCT_NAME"
PKG_PATH="$OUTPUT/${PRODUCT_NAME}-${FULL_VERSION}.pkg"

cat <<EOF
------------------------------------------------------------
  Project : $PROJECT
  Schemes : $APP_SCHEME + $CLI_SCHEME
  App     : $FULL_PRODUCT_NAME ($BUNDLE_ID)
  CLI     : $CLI_PRODUCT_NAME → /usr/local/bin
  Agent   : $([[ "$INSTALL_LAUNCHAGENT" == "true" ]] && echo "yes → /Library/LaunchAgents" || echo "no")
  Watcher : $([[ "$INSTALL_WATCH_AGENT" == "true" ]] && echo "yes → /Library/LaunchAgents (Tier 3)" || echo "no")
  Channel : $CHANNEL  →  version $FULL_VERSION  (build $BASE_BUILD)
  Output  : $PKG_PATH
  App sign: ${APP_IDENTITY:-<project default>}
  Notarize: $NOTARIZE    Pkg sign: $SIGN_PKG    Bump: $BUMP
------------------------------------------------------------
EOF

# ---------------------------------------------------------------------------
# Build both schemes (inject the channel version; CFBundleVersion stays numeric)
# ---------------------------------------------------------------------------
common_args=(
    -project "$PROJECT"
    -configuration Release
    -derivedDataPath "$DERIVED"
    -arch arm64 -arch x86_64
    ONLY_ACTIVE_ARCH=NO
    MARKETING_VERSION="$FULL_VERSION"
    CURRENT_PROJECT_VERSION="$BASE_BUILD"
)
if [[ -n "$APP_IDENTITY" ]]
then
    TEAM_ID="$(sed -n 's/.*(\([A-Z0-9]\{6,\}\)).*/\1/p' <<<"$APP_IDENTITY")"
    common_args+=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY="$APP_IDENTITY"
        ENABLE_HARDENED_RUNTIME=YES
        OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime"
    )
    if [[ -n "$TEAM_ID" ]]
    then
        common_args+=( DEVELOPMENT_TEAM="$TEAM_ID" )
    fi
fi

info "Building $APP_SCHEME (Release, universal)…"
xcodebuild build -scheme "$APP_SCHEME" "${common_args[@]}"

info "Building $CLI_SCHEME (Release, universal)…"
xcodebuild build -scheme "$CLI_SCHEME" "${common_args[@]}"

[[ -d "$APP_PATH" ]] || die "built app not found at: $APP_PATH"
[[ -f "$CLI_PATH" ]] || die "built CLI not found at: $CLI_PATH"

BUILT_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo '?')"
BUILT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo '?')"
info "Built bundle version: $BUILT_SHORT ($BUILT_BUILD)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Notarize the APP (optional) — staples the .app itself, NOT the pkg.
# ---------------------------------------------------------------------------
if [[ "$NOTARIZE" == "true" ]]
then
    info "Notarizing the app (profile: $NOTARY_PROFILE)…"
    APP_ZIP="$WORK/app-notarize.zip"
    /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
    xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    info "Stapling the app…"
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
fi

# ---------------------------------------------------------------------------
# Package: stage full filesystem layout → component pkg → distribution pkg
# ---------------------------------------------------------------------------
mkdir -p "$OUTPUT"
STAGING="$WORK/staging"
mkdir -p "$STAGING/Applications" "$STAGING/usr/local/bin"

cp -R "$APP_PATH" "$STAGING/Applications/"
cp "$CLI_PATH" "$STAGING/usr/local/bin/"
chmod 755 "$STAGING/usr/local/bin/$CLI_PRODUCT_NAME"

if [[ "$INSTALL_LAUNCHAGENT" == "true" ]]
then
    mkdir -p "$STAGING/Library/LaunchAgents"
    cp "$AGENT_PLIST_SRC" "$STAGING/Library/LaunchAgents/"
    chmod 644 "$STAGING/Library/LaunchAgents/$(basename "$AGENT_PLIST_SRC")"
    plutil -lint "$STAGING/Library/LaunchAgents/$(basename "$AGENT_PLIST_SRC")" >/dev/null \
        || die "LaunchAgent plist failed plutil -lint"
fi

if [[ "$INSTALL_WATCH_AGENT" == "true" ]]
then
    mkdir -p "$STAGING/Library/LaunchAgents"
    cp "$WATCH_PLIST_SRC" "$STAGING/Library/LaunchAgents/"
    chmod 644 "$STAGING/Library/LaunchAgents/$(basename "$WATCH_PLIST_SRC")"
    plutil -lint "$STAGING/Library/LaunchAgents/$(basename "$WATCH_PLIST_SRC")" >/dev/null \
        || die "watch LaunchAgent plist failed plutil -lint"
fi

/usr/bin/xattr -cr "$STAGING" 2>/dev/null || true   # strip detritus so pkg/notarization don't choke

# Postinstall: bootstrap the LaunchAgent for the console user (if present) so
# managed preferences converge immediately instead of at next login.
SCRIPTS_DIR="$WORK/scripts"
mkdir -p "$SCRIPTS_DIR"
if [[ "$INSTALL_LAUNCHAGENT" == "true" || "$INSTALL_WATCH_AGENT" == "true" ]]
then
    AGENT_NAMES=()
    [[ "$INSTALL_LAUNCHAGENT" == "true" ]] && AGENT_NAMES+=("$(basename "$AGENT_PLIST_SRC")")
    [[ "$INSTALL_WATCH_AGENT" == "true" ]] && AGENT_NAMES+=("$(basename "$WATCH_PLIST_SRC")")
    AGENT_NAME_LIST="${AGENT_NAMES[*]}"
    cat > "$SCRIPTS_DIR/postinstall" <<POSTINSTALL_EOF
#!/bin/bash
# postinstall — load the PaperWalls LaunchAgent(s) for the console user.
# Agents are per-user; when nobody (or only loginwindow/_mbsetupuser) is at
# the console, skip quietly — RunAtLoad picks them up at next login.

console_user="\$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)"

if [[ -n "\${console_user}" && "\${console_user}" != "root" && "\${console_user}" != "_mbsetupuser" && "\${console_user}" != "loginwindow" ]]
then
    uid="\$(/usr/bin/id -u "\${console_user}")"
    for agent_plist_name in ${AGENT_NAME_LIST}
    do
        agent_plist="/Library/LaunchAgents/\${agent_plist_name}"
        /bin/launchctl bootout "gui/\${uid}" "\${agent_plist}" 2>/dev/null || true
        /bin/launchctl bootstrap "gui/\${uid}" "\${agent_plist}" 2>/dev/null || true
    done
fi

exit 0
POSTINSTALL_EOF
    chmod 755 "$SCRIPTS_DIR/postinstall"
    bash -n "$SCRIPTS_DIR/postinstall" || die "generated postinstall failed bash -n"
fi

# Component plist: mark the app non-relocatable so the installer always puts it
# in /Applications instead of "upgrading" a stray copy (e.g. a dev build)
# that LaunchServices knows about elsewhere on the disk.
COMPONENTS="$WORK/components.plist"
pkgbuild --analyze --root "$STAGING" "$COMPONENTS" >/dev/null
# Newer pkgbuild versions omit the key from the analysis, so add it when
# there is nothing to set.
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$COMPONENTS" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Add :0:BundleIsRelocatable bool false' "$COMPONENTS" \
    || die "could not set BundleIsRelocatable in $COMPONENTS"

COMPONENT="$WORK/component.pkg"
info "Building component package…"
pkg_args=(
    --root "$STAGING"
    --component-plist "$COMPONENTS"
    --install-location /
    --identifier "$BUNDLE_ID"
    --version "$FULL_VERSION"
    --ownership recommended
)
if [[ "$INSTALL_LAUNCHAGENT" == "true" ]]
then
    pkg_args+=( --scripts "$SCRIPTS_DIR" )
fi
pkgbuild "${pkg_args[@]}" "$COMPONENT"

# Resolve pkg signing identity
if [[ "$SIGN_PKG" == "true" && -z "$PKG_IDENTITY" ]]
then
    PKG_IDENTITY="$(security find-identity -v 2>/dev/null | sed -n 's/.*"\(Developer ID Installer:[^"]*\)".*/\1/p' | head -1)"
fi

info "Building distribution package…"
prod_args=( --package "$COMPONENT" )
if [[ "$SIGN_PKG" == "true" ]]
then
    if [[ -z "$PKG_IDENTITY" ]]
    then
        die "SIGN_PKG=true but no 'Developer ID Installer' identity found — set PKG_IDENTITY or set SIGN_PKG=false"
    fi
    info "Signing pkg with: $PKG_IDENTITY"
    prod_args+=( --sign "$PKG_IDENTITY" )
else
    info "Building UNSIGNED pkg (fine for Jamf policy installs)"
fi
productbuild "${prod_args[@]}" "$PKG_PATH"

# ---------------------------------------------------------------------------
# Bump build counter in the project (optional)
# ---------------------------------------------------------------------------
if [[ "$BUMP" == "true" ]]
then
    NEXT_BUILD=$(( BASE_BUILD + 1 ))
    info "Bumping CURRENT_PROJECT_VERSION → $NEXT_BUILD in project.pbxproj"
    /usr/bin/sed -i '' -E "s/(CURRENT_PROJECT_VERSION = )[0-9]+;/\1${NEXT_BUILD};/g" "$PROJECT/project.pbxproj"
fi

printf '\n✅ Created: %s\n' "$PKG_PATH"
if [[ "$SIGN_PKG" == "true" && -n "$PKG_IDENTITY" ]]
then
    printf '   pkg signed: %s\n' "$PKG_IDENTITY"
fi
if [[ "$NOTARIZE" == "true" ]]
then
    printf '   app notarized + stapled (pkg not notarized)\n'
fi
