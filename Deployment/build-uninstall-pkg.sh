#!/bin/bash
#
# build-uninstall-pkg.sh — build PaperWalls-Uninstall.pkg.
#
# A payload-free (nopayload) package: it installs no files. Its postinstall
# script IS Deployment/uninstall.sh, which removes everything the PaperWalls
# install .pkg deployed (app, CLI, LaunchAgents, receipt) and, per the toggles
# at the top of that script, per-user runtime data. Deploy it with Jamf (or any
# MDM) exactly like the installer, or run it by hand:
#
#     sudo installer -pkg PaperWalls-Uninstall-<version>.pkg -target /
#
# Configure the CONFIG block below and run from CodeRunner or Terminal — no
# command-line flags. Mirrors build-pkg.sh's conventions (signing, output dir).

set -euo pipefail

# ======================= CONFIG — edit these ========================

# Version stamped into the pkg (and its filename). Bump when uninstall.sh changes.
UNINSTALL_VERSION="1.0"

# Output directory for the .pkg. Empty = "<project folder>/dist".
OUTPUT=""

# --- Pkg signing ---------------------------------------------------
# true = sign the .pkg with a Developer ID Installer identity (so it installs
# without Gatekeeper friction outside MDM). Unsigned is fine for MDM/Jamf pushes
# and for `installer` with sudo.
SIGN_PKG=false
PKG_IDENTITY=""                     # empty = auto-detect "Developer ID Installer: …"

# ===================================================================

readonly PKG_IDENTIFIER="com.herojoneslabs.paperwalls.uninstall"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '==> %s\n' "$*"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
UNINSTALL_SRC="$SCRIPT_DIR/uninstall.sh"

[[ -f "$UNINSTALL_SRC" ]] || die "uninstall.sh not found next to this script: $UNINSTALL_SRC"

command -v pkgbuild >/dev/null 2>&1 || die "pkgbuild not found (install Xcode command line tools)"

# uninstall.sh must be valid bash before we bake it into a pkg.
bash -n "$UNINSTALL_SRC" || die "uninstall.sh failed 'bash -n'"

[[ -n "$OUTPUT" ]] || OUTPUT="$PROJECT_ROOT/dist"
mkdir -p "$OUTPUT"
PKG_PATH="$OUTPUT/PaperWalls-Uninstall-${UNINSTALL_VERSION}.pkg"

# Stage a scripts dir: the pkg runs the file literally named 'postinstall'.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SCRIPTS_DIR="$WORK/scripts"
mkdir -p "$SCRIPTS_DIR"
cp "$UNINSTALL_SRC" "$SCRIPTS_DIR/postinstall"
chmod 755 "$SCRIPTS_DIR/postinstall"

cat <<EOF
------------------------------------------------------------
  Building : PaperWalls-Uninstall.pkg (nopayload)
  Identifier: $PKG_IDENTIFIER
  Version  : $UNINSTALL_VERSION
  Runs     : uninstall.sh as postinstall
  Output   : $PKG_PATH
  Pkg sign : $SIGN_PKG
------------------------------------------------------------
EOF

pkg_args=(
    --nopayload
    --identifier "$PKG_IDENTIFIER"
    --version "$UNINSTALL_VERSION"
    --scripts "$SCRIPTS_DIR"
)

if [[ "$SIGN_PKG" == "true" ]]
then
    if [[ -z "$PKG_IDENTITY" ]]
    then
        PKG_IDENTITY="$(security find-identity -v 2>/dev/null | sed -n 's/.*"\(Developer ID Installer:[^"]*\)".*/\1/p' | head -1)"
    fi
    [[ -n "$PKG_IDENTITY" ]] || die "SIGN_PKG=true but no Developer ID Installer identity found"
    info "Signing with: $PKG_IDENTITY"
    pkg_args+=( --sign "$PKG_IDENTITY" )
fi

info "Building uninstall package…"
pkgbuild "${pkg_args[@]}" "$PKG_PATH"

info "Done: $PKG_PATH"
