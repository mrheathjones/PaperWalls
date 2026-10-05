#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: uninstall.sh
# Author: herojoneslabs
# Date: 08-29-2026
# Modified: 10-02-2026
# Purpose: Remove everything the PaperWalls install .pkg deployed —
#          /Applications/PaperWalls.app, /usr/local/bin/paperwallscli,
#          the manage/watch LaunchAgents (booted out for every user),
#          /Library/Screen Savers/PaperWalls.saver, the pkg receipt, and
#          (optionally) per-user runtime data.
#          Runs standalone (sudo ./uninstall.sh), as a Jamf policy
#          script, or as the postinstall of PaperWalls-Uninstall.pkg —
#          it ignores its arguments and always performs the removal.
# Version: 1.0 - Initial Script
#          1.1 - Remove the screen saver and its per-user data
#          1.2 - Optionally remove savers built with Studio › Package
#
#
#
######################################################################
############## End Script Information Block ##########################
######################################################################

####################################################################
############## Begin Define Variables Block ########################
####################################################################
##############################
### Core Defined Variables ###
### MODIFY AT YOUR OWN RISK ##
##############################

set -euo pipefail

# Ensure PATH is set so `which` resolves reliably in any execution context
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Binary paths (add task-specific binaries to User Defined Variables)
# shellcheck disable=SC2230 — `which` preferred over `command -v` per style guide
readonly AWK=$(which awk)
readonly BASENAME=$(which basename)
readonly DATE=$(which date)
readonly ID=$(which id)
readonly LOGGER=$(which logger)
readonly MKTEMP=$(which mktemp)
readonly RM=$(which rm)
readonly RMDIR=$(which rmdir)
readonly DSCL=$(which dscl)
readonly FIND=$(which find)
readonly PKGUTIL=$(which pkgutil)
readonly PLISTBUDDY="/usr/libexec/PlistBuddy"
readonly PKILL=$(which pkill)
readonly PGREP=$(which pgrep)
readonly LAUNCHCTL=$(which launchctl)

# Org identity — REQUIRED, set per deployment.
readonly ORG_NAME_FRIENDLY="Hero Jones Labs"
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly ORG_PLIST_DOMAIN="com.herojoneslabs"

# Script metadata
readonly SCRIPT_NAME=$("${BASENAME}" "$0")
readonly SCRIPT_VERSION="1.2"
readonly LOG_LABEL="${ORG_PLIST_DOMAIN}.paperwalls.uninstall"
readonly TIMESTAMP=$("${DATE}" +%Y%m%d_%H%M%S)
readonly JAMF_LOG="/var/log/jamf.log"

declare -a TEMP_FILES=()

##################################
### End Core Defined Variables ###
##################################

########################################
######## User Defined Variables ########
### Place your script variables here ###
########################################

# --- What the install .pkg deployed (always removed) ----------------
readonly APP_BUNDLE_ID="com.herojoneslabs.paperwalls"
readonly PKG_RECEIPT_ID="com.herojoneslabs.paperwalls"          # pkgbuild --identifier
readonly APP_PATH="/Applications/PaperWalls.app"
readonly CLI_PATH="/usr/local/bin/paperwallscli"
readonly SAVER_PATH="/Library/Screen Savers/PaperWalls.saver"
readonly SAVER_HOST_PROCESS="legacyScreenSaver"
readonly MANAGE_LABEL="com.herojoneslabs.paperwalls.manage"
readonly WATCH_LABEL="com.herojoneslabs.paperwalls.watch"
readonly MANAGE_PLIST="/Library/LaunchAgents/${MANAGE_LABEL}.plist"
readonly WATCH_PLIST="/Library/LaunchAgents/${WATCH_LABEL}.plist"
readonly MANAGE_TMP_LOG="/tmp/com.herojoneslabs.paperwalls.manage.log"

# --- Per-user runtime data (created by the app, NOT by the pkg) -----
# Path relative to each user's home directory.
readonly APP_SUPPORT_SUBPATH="Library/Application Support/PaperWalls"
readonly SYSTEM_MANAGED_DIR="/Library/Application Support/PaperWalls"   # admin managed.json lives here

# ==================== REMOVAL TOGGLES — edit these ==================
# The app/CLI/agents/screen saver/receipt are ALWAYS removed. These control
# the per-user data the app created at runtime.
#
#   REMOVE_USER_CACHES       Feed cache, downloaded Apple wallpapers, the
#                            folder-hash cache, screen saver thumbnails, and
#                            the published screen saver snapshot. Safe — the
#                            app rebuilds them.
#   REMOVE_SCREEN_SAVERS     The user's OWN screen savers made in Studio
#                            (…/PaperWalls/Studio). Off by default — this is
#                            user data, not a cache. Turn on for a full wipe.
#   REMOVE_PERSONAL_LIBRARY  The user's OWN imported wallpapers
#                            (…/PaperWalls/Personal). Off by default — this is
#                            user data, not a cache. Turn on for a full wipe.
#   REMOVE_USER_PREFERENCES  Favorites, current selection, rotation state
#                            (the com.herojoneslabs.paperwalls[.cli] plists).
#                            Off by default so a reinstall keeps the user's setup.
#   REMOVE_MANAGED_CONFIG    The admin's local /Library/Application Support/
#                            PaperWalls/managed.json. Off by default — you
#                            likely manage that separately (or via a profile).
#   REMOVE_DEPLOYED_SAVERS   Savers built with Studio › Package and installed
#                            to /Library/Screen Savers (matched by bundle
#                            identifier, never by name), plus their pkg
#                            receipts. Off by default — they run without the
#                            app and are usually deployed and removed on
#                            their own.
# ===================================================================
readonly REMOVE_USER_CACHES="true"
readonly REMOVE_SCREEN_SAVERS="false"
readonly REMOVE_PERSONAL_LIBRARY="false"
readonly REMOVE_USER_PREFERENCES="false"
readonly REMOVE_MANAGED_CONFIG="false"
readonly REMOVE_DEPLOYED_SAVERS="false"

##################################
### End User Defined Variables ###
##################################
####################################################################
############## End Define Variables Block ##########################
####################################################################

###################################################################################
############## Begin Function Block ###############################################
###################################################################################
##############################
### Core Defined Functions ###
### MODIFY AT YOUR OWN RISK ##
##############################

# ── Logging ──────────────────────────────────────────────────────────────────
log_info() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [INFO] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.info "[INFO] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
}

log_warn() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [WARN] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.warning "[WARN] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
}

log_error() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [ERROR] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.err "[ERROR] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
}

# ── Cleanup (trapped on EXIT/INT/TERM) ───────────────────────────────────────
cleanup() {
    local exit_code=$?
    local f
    for f in "${TEMP_FILES[@]:-}"
    do
        if [[ -f "${f}" ]]
        then
            "${RM}" -f "${f}"
        fi
    done
    log_info "${SCRIPT_NAME} exiting with code ${exit_code}"
    exit "${exit_code}"
}
trap cleanup EXIT INT TERM

# ── Preflight ────────────────────────────────────────────────────────────────
require_root() {
    if [[ "$("${ID}" -u)" -ne 0 ]]
    then
        log_error "Must run as root (try: sudo ${SCRIPT_NAME})"
        exit 1
    fi
}

##################################
### End Core Defined Functions ###
##################################

########################################
######## User Defined Functions ########
### Place your script functions here ###
########################################

# Emit every human user's "uid home" pair (uid >= 500, real home under /Users),
# one per line. Used to boot out agents and to reach per-user app data.
list_user_records() {
    local name uid home
    while IFS= read -r name
    do
        [[ -n "${name}" ]] || continue
        uid="$("${DSCL}" . -read "/Users/${name}" UniqueID 2>/dev/null | "${AWK}" '{print $2}')"
        home="$("${DSCL}" . -read "/Users/${name}" NFSHomeDirectory 2>/dev/null | "${AWK}" '{print $2}')"
        if [[ -z "${uid}" || -z "${home}" ]]
        then
            continue
        fi
        if [[ "${uid}" -lt 500 ]]
        then
            continue
        fi
        if [[ "${home}" != /Users/* ]]
        then
            continue
        fi
        printf '%s %s\n' "${uid}" "${home}"
    done < <("${DSCL}" . -list /Users 2>/dev/null)
}

# Boot out both LaunchAgents from every user's GUI domain. bootout is a no-op
# (nonzero) when the label isn't loaded — swallow that so set -e doesn't trip.
stop_and_unload_agents() {
    local uid home label

    while read -r uid home
    do
        [[ -n "${uid}" ]] || continue
        for label in "${MANAGE_LABEL}" "${WATCH_LABEL}"
        do
            if "${LAUNCHCTL}" print "gui/${uid}/${label}" >/dev/null 2>&1
            then
                log_info "Booting out ${label} from gui/${uid} (${home})"
                "${LAUNCHCTL}" bootout "gui/${uid}/${label}" 2>/dev/null || true
            fi
        done
    done < <(list_user_records)
}

# Stop any still-running processes (the app, and a detached watcher).
kill_running_processes() {
    if "${PGREP}" -x "PaperWalls" >/dev/null 2>&1
    then
        log_info "Quitting running PaperWalls app"
        "${PKILL}" -x "PaperWalls" 2>/dev/null || true
    fi

    if "${PGREP}" -f "paperwallscli watch" >/dev/null 2>&1
    then
        log_info "Stopping running paperwallscli watch"
        "${PKILL}" -f "paperwallscli watch" 2>/dev/null || true
    fi
}

# Remove the files the install .pkg placed on disk.
remove_payload() {
    local target

    for target in "${MANAGE_PLIST}" "${WATCH_PLIST}"
    do
        if [[ -f "${target}" ]]
        then
            log_info "Removing LaunchAgent: ${target}"
            "${RM}" -f "${target}"
        fi
    done

    if [[ -d "${APP_PATH}" ]]
    then
        log_info "Removing app: ${APP_PATH}"
        "${RM}" -rf "${APP_PATH}"
    else
        log_warn "App not found at ${APP_PATH} (already removed?)"
    fi

    if [[ -e "${CLI_PATH}" ]]
    then
        log_info "Removing CLI: ${CLI_PATH}"
        "${RM}" -f "${CLI_PATH}"
    else
        log_warn "CLI not found at ${CLI_PATH} (already removed?)"
    fi

    if [[ -d "${SAVER_PATH}" ]]
    then
        log_info "Removing screen saver: ${SAVER_PATH}"
        "${RM}" -rf "${SAVER_PATH}"
        # The host keeps the bundle loaded; restart it so the removed saver
        # stops running (the system relaunches the host on demand).
        "${PKILL}" -x "${SAVER_HOST_PROCESS}" 2>/dev/null || true
    fi

    if [[ -f "${MANAGE_TMP_LOG}" ]]
    then
        log_info "Removing agent log: ${MANAGE_TMP_LOG}"
        "${RM}" -f "${MANAGE_TMP_LOG}"
    fi
}

# Drop the installer receipt so the Mac no longer reports PaperWalls installed.
forget_receipt() {
    if "${PKGUTIL}" --pkg-info "${PKG_RECEIPT_ID}" >/dev/null 2>&1
    then
        log_info "Forgetting pkg receipt: ${PKG_RECEIPT_ID}"
        "${PKGUTIL}" --forget "${PKG_RECEIPT_ID}" >/dev/null 2>&1 || true
    else
        log_info "No pkg receipt for ${PKG_RECEIPT_ID} (installed by hand or already forgotten)"
    fi
}

# Studio › Package savers: bundle identifier prefix and pkg receipt prefix.
readonly DEPLOYED_SAVER_ID_PREFIX="${APP_BUNDLE_ID}.saver.deployed."
readonly DEPLOYED_PKG_ID_PREFIX="${APP_BUNDLE_ID}.savers."

# Remove savers built with Studio › Package (when REMOVE_DEPLOYED_SAVERS=true).
remove_deployed_savers() {
    [[ "${REMOVE_DEPLOYED_SAVERS}" == "true" ]] || return 0
    local saver identifier receipt removed=false
    for saver in "/Library/Screen Savers/"*.saver
    do
        [[ -d "${saver}" ]] || continue
        identifier=$("${PLISTBUDDY}" -c "Print :CFBundleIdentifier" "${saver}/Contents/Info.plist" 2>/dev/null) || continue
        if [[ "${identifier}" == "${DEPLOYED_SAVER_ID_PREFIX}"* ]]
        then
            log_info "Removing deployed screen saver: ${saver}"
            "${RM}" -rf "${saver}"
            removed=true
        fi
    done
    while IFS= read -r receipt
    do
        [[ -n "${receipt}" ]] || continue
        log_info "Forgetting pkg receipt: ${receipt}"
        "${PKGUTIL}" --forget "${receipt}" >/dev/null 2>&1 || true
    done < <("${PKGUTIL}" --pkgs="${DEPLOYED_PKG_ID_PREFIX//./\\.}.*" 2>/dev/null)
    if [[ "${removed}" == "true" ]]
    then
        "${PKILL}" -x "${SAVER_HOST_PROCESS}" 2>/dev/null || true
    fi
}

# If the per-user PaperWalls dir has nothing left in it, remove the empty shell.
remove_dir_if_empty() {
    local dir="$1"
    if [[ -d "${dir}" ]]
    then
        if [[ -z "$(ls -A "${dir}" 2>/dev/null)" ]]
        then
            "${RMDIR}" "${dir}" 2>/dev/null || true
        fi
    fi
}

# Remove per-user runtime data according to the REMOVE_* toggles.
remove_user_data() {
    local uid home base pref

    while read -r uid home
    do
        [[ -n "${home}" ]] || continue
        base="${home}/${APP_SUPPORT_SUBPATH}"

        # Generated per-scene saver bundles and a user-installed copy of the
        # saver are derived from the app — always removed.
        if [[ -d "${home}/Library/Screen Savers" ]]
        then
            "${FIND}" "${home}/Library/Screen Savers" -maxdepth 1 -name 'PaperWalls – *.saver' -exec "${RM}" -rf {} + 2>/dev/null || true
            "${RM}" -rf "${home}/Library/Screen Savers/PaperWalls.saver"
        fi

        if [[ "${REMOVE_USER_CACHES}" == "true" && -d "${base}" ]]
        then
            log_info "Removing caches for ${home}"
            "${RM}" -rf "${base}/RemoteCache" "${base}/SystemWallpapers" "${base}/content-id-cache.json"
            "${RM}" -rf "${base}/Studio/ScreenSavers/Thumbnails" "${base}/Studio/ActiveScreenSaver.json"
        fi

        if [[ "${REMOVE_SCREEN_SAVERS}" == "true" && -d "${base}/Studio" ]]
        then
            log_warn "Removing the user's Studio screen savers for ${home}"
            "${RM}" -rf "${base}/Studio"
        fi

        if [[ "${REMOVE_PERSONAL_LIBRARY}" == "true" && -d "${base}/Personal" ]]
        then
            log_warn "Removing PERSONAL library (user's own wallpapers) for ${home}"
            "${RM}" -rf "${base}/Personal"
        fi

        if [[ "${REMOVE_USER_PREFERENCES}" == "true" ]]
        then
            for pref in "${APP_BUNDLE_ID}" "${APP_BUNDLE_ID}.cli"
            do
                if [[ -f "${home}/Library/Preferences/${pref}.plist" ]]
                then
                    log_info "Removing preferences ${pref} for ${home}"
                    "${RM}" -f "${home}/Library/Preferences/${pref}.plist"
                fi
            done
            # cfprefsd caches the values in memory for the live user — nudge it.
            "${LAUNCHCTL}" asuser "${uid}" "${LAUNCHCTL}" kill SIGTERM "gui/${uid}/com.apple.cfprefsd.xpc.agent" 2>/dev/null || true
        fi

        remove_dir_if_empty "${base}"
    done < <(list_user_records)
}

# Optionally remove the admin's local managed config, then the shared dir.
remove_managed_config() {
    if [[ "${REMOVE_MANAGED_CONFIG}" == "true" ]]
    then
        for ext in json plist
        do
            if [[ -f "${SYSTEM_MANAGED_DIR}/managed.${ext}" ]]
            then
                log_info "Removing local managed config: ${SYSTEM_MANAGED_DIR}/managed.${ext}"
                "${RM}" -f "${SYSTEM_MANAGED_DIR}/managed.${ext}"
            fi
        done
    fi
    remove_dir_if_empty "${SYSTEM_MANAGED_DIR}"
}

##################################
### End User Defined Functions ###
##################################
###################################################################################
############## End Function Block #################################################
###################################################################################

#####################################################
################## Run Script Block #################
#####################################################

log_info "${SCRIPT_NAME} v${SCRIPT_VERSION} starting — uninstalling PaperWalls (${APP_BUNDLE_ID})"

require_root

stop_and_unload_agents
kill_running_processes
remove_payload
forget_receipt
remove_user_data
remove_managed_config
remove_deployed_savers

log_info "PaperWalls uninstall complete"
log_info "  Removed: app, CLI, LaunchAgents, screen saver, pkg receipt${REMOVE_USER_CACHES:+, user caches}"
log_info "  Kept:    $([[ "${REMOVE_PERSONAL_LIBRARY}" == "true" ]] && echo -n "" || echo -n "personal library, ")$([[ "${REMOVE_SCREEN_SAVERS}" == "true" ]] && echo -n "" || echo -n "Studio screen savers, ")$([[ "${REMOVE_USER_PREFERENCES}" == "true" ]] && echo -n "" || echo -n "user preferences ")(toggle REMOVE_* in the script for a full wipe)"

log_info "${SCRIPT_NAME} completed successfully"

###########################################################
################## End Script Block #######################
###########################################################
