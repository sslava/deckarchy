#!/bin/sh
# Shared helpers for deckarchy.sh.
#
# Deliberately minimal: this file only *detects* things. It never installs a
# package manager, an AUR helper, or a Flatpak remote as a side effect of being
# sourced. Anything that changes the system belongs in the calling script,
# where the user can see it.

# shellcheck disable=SC2034

RC='\033[0m'
RED='\033[31m'
YELLOW='\033[33m'
CYAN='\033[36m'
GREEN='\033[32m'

msg()  { printf "%b\n" "${CYAN}$1${RC}"; }
ok()   { printf "%b\n" "${GREEN}$1${RC}"; }
warn() { printf "%b\n" "${YELLOW}$1${RC}"; }
err()  { printf "%b\n" "${RED}$1${RC}" >&2; }

command_exists() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || return 1
    done
    return 0
}

checkArch() {
    case "$(uname -m)" in
        x86_64 | amd64) ARCH="x86_64" ;;
        *) err "Unsupported architecture: $(uname -m) (Steam Deck is x86_64)"; exit 1 ;;
    esac
    msg "Architecture: ${ARCH}"
}

checkEscalationTool() {
    if [ -n "${ESCALATION_TOOL:-}" ]; then return 0; fi

    if [ "$(id -u)" = "0" ]; then
        # Not "eval": that re-parses its arguments and mangles any word
        # containing spaces or shell metacharacters.
        ESCALATION_TOOL="command"
        msg "Running as root, no escalation needed"
        return 0
    fi

    for tool in sudo doas; do
        if command_exists "$tool"; then
            ESCALATION_TOOL="$tool"
            msg "Using ${tool} for privilege escalation"
            return 0
        fi
    done

    err "Can't find a supported escalation tool (sudo or doas)"
    exit 1
}

checkPackageManager() {
    if ! command_exists pacman; then
        err "pacman not found. These scripts are Arch/Omarchy only."
        exit 1
    fi
    PACKAGER="pacman"
    msg "Using pacman as package manager"
}

checkDistro() {
    # Sourced in a subshell so /etc/os-release does not clobber caller
    # variables such as NAME, VERSION or ID.
    DTYPE="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-unknown}")"
    DPRETTY="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}")"
    msg "Distro: ${DPRETTY} (${DTYPE})"
}

checkSuperUser() {
    if [ "$(id -u)" = "0" ]; then return 0; fi
    for sug in wheel sudo root; do
        if id -nG | tr ' ' '\n' | grep -qx "$sug"; then
            msg "Super user group: ${sug}"
            return 0
        fi
    done
    err "You need to be in the wheel/sudo group to run this."
    exit 1
}

# Install the package providing a required command, if that command is missing.
# Call checkEscalationTool and checkPackageManager first.
#
#   ensureCommand jq            # command and package share a name
#   ensureCommand awk gawk      # they don't
ensureCommand() {
    _cmd="$1"; _pkg="${2:-$1}"
    if command_exists "$_cmd"; then return 0; fi

    warn "Required command '$_cmd' is missing - installing package '$_pkg'"
    if [ "${DRY_RUN:-0}" = 1 ]; then
        printf '  \033[33m[dry-run]\033[0m pacman -S --needed --noconfirm %s\n' "$_pkg"
        return 0
    fi

    if [ "$ESCALATION_TOOL" = "command" ]; then
        pacman -S --needed --noconfirm "$_pkg"
    else
        "$ESCALATION_TOOL" pacman -S --needed --noconfirm "$_pkg"
    fi

    if command_exists "$_cmd"; then
        ok "Installed $_pkg"
    else
        err "Installing '$_pkg' did not provide '$_cmd'"
        exit 1
    fi
}

# ensureCommands awk:gawk jq:jq mkinitcpio:mkinitcpio
ensureCommands() {
    for _pair in "$@"; do
        ensureCommand "${_pair%%:*}" "${_pair#*:}"
    done
}
