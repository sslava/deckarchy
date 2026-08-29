#!/bin/sh
# deckarchy - Steam Deck post-install support for Omarchy 4 (Quattro).
#
# Omarchy 4 installs from its own ISO and mainline linux drives almost the
# whole Deck. Stock linux-firmware ships the Wi-Fi (ath11k/QCA2066), Bluetooth
# (qca/hpbtfw21) and GPU (amdgpu/vangogh) blobs; stock alsa-ucm-conf ships the
# LCD Deck's acp5x UCM. So this script does exactly two things:
#
#   1. installs "steamdeck-dsp" from Valve's SteamOS repo - the only source of
#      the SOF vangogh DSP firmware/topology and the OLED's sof-nau8821-max
#      UCM. Without it the OLED has no speakers and no microphone.
#   2. writes a "transform" rule for the internal panel, which is mounted 90
#      degrees rotated and which Omarchy cannot guess.
#
# It also offers a migration back to stock for machines left over from the old
# Neptune-kernel scripts. No kernel and no firmware set is installed anymore.
#
# Design rules, learned the hard way:
#   * The SteamOS repos are added TEMPORARILY and removed again on exit, so no
#     third-party staging repo is left permanently wired into pacman.
#   * Signature checking is never disabled outright (no "SigLevel = Never").
#   * No forced package removal (-Rdd). Package swaps go through pacman's
#     normal Replaces/Conflicts resolution.
#   * /etc/pacman.conf and monitors.lua are backed up before they are touched.
#   * Only ~/.config/hypr/monitors.lua is written in $HOME, and only inside a
#     clearly marked block.
#
# Usage:
#   ./deckarchy.sh              full run: report, install, rotate, migrate
#   ./deckarchy.sh --check      hardware report only, change nothing
#   ./deckarchy.sh --dry-run    print every command, change nothing
#   ./deckarchy.sh --yes        pass --noconfirm to pacman (unattended)
#   ./deckarchy.sh --rotate N   set panel transform to N (0-3); rotation only
#   ./deckarchy.sh --keep-repos leave the Valve repo in pacman.conf afterwards
#   ./deckarchy.sh --force      run on non-Deck hardware anyway

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=common-script.sh
. "$SCRIPT_DIR/common-script.sh"

DRY_RUN=0
ASSUME_YES=0
KEEP_REPOS=0
CHECK_ONLY=0
FORCE=0
ROTATE=""
REPOS_ADDED=0

PACMAN_CONF=/etc/pacman.conf
BACKUP_SUFFIX="bak.deckarchy.$(date +%Y%m%d-%H%M%S)"
STEAMOS_MIRROR='https://steamdeck-packages.steamos.cloud/archlinux-mirror/$repo/os/$arch'
# Signatures are checked when present. Valve's mirror is not covered by the
# Arch keyring, so keys cannot be "Required", but "Never" -- which accepts an
# unsigned package from anyone who can answer for that hostname, forever, for
# every repo -- is not the alternative. TrustAll matches how Omarchy
# configures its own repo.
STEAMOS_SIGLEVEL='SigLevel = Optional TrustAll'

MONITORS_LUA="$HOME/.config/hypr/monitors.lua"
INTERNAL="eDP-1"
MARK_BEGIN='-- >>> deckarchy'
MARK_END='-- <<< deckarchy'

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)    DRY_RUN=1 ;;
        --yes|-y)     ASSUME_YES=1 ;;
        --keep-repos) KEEP_REPOS=1 ;;
        --check)      CHECK_ONLY=1 ;;
        --force)      FORCE=1 ;;
        --rotate)     ROTATE="${2:-}"; shift ;;
        -h|--help)    sed -n '2,35p' "$0"; exit 0 ;;
        *)            err "Unknown option: $1 (try --help)"; exit 1 ;;
    esac
    shift
done

case "${ROTATE:-0}" in
    0|1|2|3) ;;
    *) err "--rotate takes 0, 1, 2 or 3 (got '$ROTATE')"; exit 1 ;;
esac

run_root() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '  \033[33m[dry-run]\033[0m %s\n' "$*"
        return 0
    fi
    if [ "$ESCALATION_TOOL" = "command" ]; then
        "$@"
    else
        "$ESCALATION_TOOL" "$@"
    fi
}

dry() { printf '  \033[33m[dry-run]\033[0m %s\n' "$*"; }

pacman_confirm_flag() {
    if [ "$ASSUME_YES" = 1 ]; then printf '%s' '--noconfirm'; fi
    return 0
}

# Every system change is behind this. --yes answers yes; --dry-run still asks,
# because the point of a dry run is to see the commands each answer produces.
confirm() {
    if [ "$ASSUME_YES" = 1 ]; then
        msg "$1 [--yes]"
        return 0
    fi
    printf '%s [y/N] ' "$1"
    read -r reply
    case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

installed() { pacman -Qq "$1" >/dev/null 2>&1; }

# The jupiter build of alsa-ucm-conf carries Valve's Packager line; the version
# string alone does not distinguish it from Arch's.
ucmFromValve() { pacman -Qi alsa-ucm-conf 2>/dev/null | grep -q 'steamos\.cloud'; }

# ---------------------------------------------------------------- detection --

detectSteamDeck() {
    DECK_MODEL=""
    if [ -r /sys/class/dmi/id/product_name ]; then
        case "$(cat /sys/class/dmi/id/product_name)" in
            Jupiter) DECK_MODEL="Steam Deck LCD (Jupiter)" ;;
            Galileo) DECK_MODEL="Steam Deck OLED (Galileo)" ;;
        esac
    fi

    if [ -n "$DECK_MODEL" ]; then
        ok "$DECK_MODEL detected"
    elif [ "$FORCE" = 1 ]; then
        warn "Not a Steam Deck, but --force was given. The audio package and the"
        warn "panel transform are Deck-specific; on other hardware they are at"
        warn "best useless. You asked for it."
        DECK_MODEL="unknown hardware (--force)"
    else
        err "This is not a Steam Deck (/sys/class/dmi/id/product_name is not"
        err "Jupiter or Galileo). Re-run with --force to override."
        exit 1
    fi

    # Not fatal: the package work is plain pacman and the rotation only needs
    # Hyprland. But monitors.lua-as-Lua is an Omarchy 4 thing.
    if [ "$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")" != "omarchy" ]; then
        warn "/etc/os-release ID is not 'omarchy' - this is written for Omarchy 4."
    fi
}

# ------------------------------------------------------------------- repos --

reposPresent() {
    grep -qE '^[[:space:]]*\[(jupiter-staging|holo-staging)\]' "$PACMAN_CONF"
}

addRepos() {
    if reposPresent; then
        warn "SteamOS repos already present in $PACMAN_CONF - leaving them alone"
        return 0
    fi

    msg "Temporarily adding SteamOS repos (removed again when this script exits)"
    run_root cp -a "$PACMAN_CONF" "$PACMAN_CONF.$BACKUP_SUFFIX"
    msg "  backup: $PACMAN_CONF.$BACKUP_SUFFIX"

    # Both repos: steamdeck-dsp has moved between them across SteamOS releases,
    # and an empty extra repo costs one 404 on -Sy.
    if [ "$DRY_RUN" = 1 ]; then
        dry "append [jupiter-staging] and [holo-staging] ($STEAMOS_SIGLEVEL) to $PACMAN_CONF"
    else
        tmp="$(mktemp)"
        {
            cat "$PACMAN_CONF"
            printf '\n[jupiter-staging]\n%s\nServer = %s\n' "$STEAMOS_SIGLEVEL" "$STEAMOS_MIRROR"
            printf '\n[holo-staging]\n%s\nServer = %s\n' "$STEAMOS_SIGLEVEL" "$STEAMOS_MIRROR"
        } > "$tmp"
        run_root cp "$tmp" "$PACMAN_CONF"
        rm -f "$tmp"
    fi
    REPOS_ADDED=1
}

removeRepos() {
    if [ "$DRY_RUN" = 1 ]; then
        dry "remove [jupiter-staging]/[holo-staging] from $PACMAN_CONF"
        return 0
    fi
    reposPresent || return 0

    tmp="$(mktemp)"
    awk '
      /^[[:space:]]*\[(jupiter-staging|holo-staging)\][[:space:]]*$/ { skip=1; next }
      /^[[:space:]]*\[/ { skip=0 }
      !skip
    ' "$PACMAN_CONF" > "$tmp"

    # Refuse to install a file that lost the base repos - a botched edit here
    # leaves the machine unable to update itself.
    if ! grep -q '^\[core\]' "$tmp" || ! grep -q '^\[extra\]' "$tmp"; then
        err "Refusing to write $PACMAN_CONF: [core]/[extra] missing after edit."
        err "Your backup is at $PACMAN_CONF.$BACKUP_SUFFIX"
        rm -f "$tmp"
        return 1
    fi

    msg "Removing SteamOS repos from $PACMAN_CONF"
    run_root cp "$tmp" "$PACMAN_CONF"
    rm -f "$tmp"
    run_root rm -f /var/lib/pacman/sync/jupiter-staging.db \
                   /var/lib/pacman/sync/holo-staging.db
}

cleanup() {
    status=$?
    if [ "$REPOS_ADDED" = 1 ] && [ "$KEEP_REPOS" = 0 ]; then
        removeRepos || true
    elif [ "$REPOS_ADDED" = 1 ]; then
        warn "--keep-repos given: SteamOS repos left in $PACMAN_CONF."
        warn "They track Valve's *staging* channel. Remove them when done."
    fi
    exit $status
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------ report --

check() {
    label="$1"; state="$2"; detail="$3"
    case "$state" in
        good) printf '  %b[ ok ]%b %-22s %s\n' "$GREEN" "$RC" "$label" "$detail" ;;
        warn) printf '  %b[warn]%b %-22s %s\n' "$YELLOW" "$RC" "$label" "$detail" ;;
        bad)  printf '  %b[FAIL]%b %-22s %s\n' "$RED" "$RC" "$label" "$detail" ;;
    esac
}

# Query one field of the internal panel. Uses jq when available and falls back
# to python3, because grepping raw JSON happily matches the *external*
# monitor's fields instead.
panelField() {
    if command_exists jq; then
        hyprctl monitors -j 2>/dev/null \
            | jq -r --arg n "$INTERNAL" --arg f "$1" \
                'map(select(.name==$n))[0][$f] // empty' 2>/dev/null
    else
        hyprctl monitors -j 2>/dev/null | python3 -c '
import json,sys
name,field=sys.argv[1],sys.argv[2]
for m in json.load(sys.stdin):
    if m.get("name")==name:
        print(m.get(field,"")); break
' "$INTERNAL" "$1" 2>/dev/null
    fi
}

panelTransform() { panelField transform; }

# The Deck panel is 1280x800 physically but reports 800x1280; Hyprland shows
# the logical size, so a taller-than-wide internal panel means unrotated.
panelIsPortrait() {
    w="$(panelField width)"; h="$(panelField height)"
    [ -n "$w" ] && [ -n "$h" ] && [ "$h" -gt "$w" ]
}

sofCardPresent() {
    [ -r /proc/asound/cards ] && grep -qi 'sof\|acp\|vangogh' /proc/asound/cards
}

reportHardware() {
    msg "===== Steam Deck hardware on Omarchy ====="

    # --- display ---
    if ! command_exists hyprctl; then
        check "internal display" warn "hyprctl not found - is Hyprland running?"
    elif ! hyprctl monitors 2>/dev/null | grep -q "$INTERNAL"; then
        # Also what you see when the panel is switched off on purpose
        # (clamshell / omarchy's internal-monitor toggle). Not an error.
        check "internal display" warn "$INTERNAL not connected or disabled"
    else
        t="$(panelTransform)"
        if panelIsPortrait && [ "${t:-0}" = "0" ]; then
            check "internal display" bad \
                "$INTERNAL is 800x1280 with transform 0 - panel is sideways"
        else
            check "internal display" good "$INTERNAL transform=${t:-0}"
        fi
    fi

    # --- audio: the OLED speakers/mic run through the AMD SOF DSP ---
    if sofCardPresent; then
        check "speakers / mic" good "SOF audio card present"
    elif ! installed steamdeck-dsp; then
        check "speakers / mic" bad \
            "no SOF card and no steamdeck-dsp - this script installs it"
    elif lsmod 2>/dev/null | grep -q '^snd_sof_amd_vangogh'; then
        # SOF probes once, at boot. If steamdeck-dsp landed after that, the
        # firmware is on disk but the driver never retried -- reloading the
        # module is enough, no reboot needed.
        check "speakers / mic" warn \
            "firmware present but DSP not probed - run: sudo modprobe -r snd_sof_amd_vangogh && sudo modprobe snd_sof_amd_vangogh"
    else
        check "speakers / mic" warn "steamdeck-dsp installed but snd_sof_amd_vangogh not loaded - reboot"
    fi

    # --- the rest ---
    if lsmod 2>/dev/null | grep -q '^ath11k'; then
        check "wifi" good "ath11k loaded"
    else
        check "wifi" bad "ath11k not loaded"
    fi

    if [ -d /sys/class/backlight/amdgpu_bl1 ]; then
        check "screen brightness" good "amdgpu_bl1"
    else
        check "screen brightness" warn "no amdgpu backlight device"
    fi

    if [ -d /sys/class/power_supply/BAT1 ]; then
        check "battery" good "BAT1 present"
    else
        check "battery" warn "BAT1 not found"
    fi

    # Stock firmware is the *correct* state now: every blob the Deck loads is
    # in Arch's split linux-firmware-* packages.
    if installed linux-firmware-neptune; then
        check "firmware" warn \
            "linux-firmware-neptune installed - Neptune leftover, migration available"
    elif installed linux-firmware; then
        check "firmware" good "stock linux-firmware"
    else
        check "firmware" bad "NO firmware package installed"
    fi

    if installed linux-neptune-611; then
        check "kernel" warn \
            "$(uname -r) running, linux-neptune-611 installed - no longer needed"
    else
        check "kernel" good "$(uname -r) (mainline)"
    fi

    if reposPresent; then
        check "pacman repos" warn \
            "jupiter-staging/holo-staging left in $PACMAN_CONF (unstable channel)"
    elif grep -q 'SigLevel *= *Never' "$PACMAN_CONF" 2>/dev/null; then
        check "pacman repos" bad "'SigLevel = Never' set - unsigned packages accepted"
    else
        check "pacman repos" good "no staging repo, no disabled signature checking"
    fi

    printf '\n'
}

# ------------------------------------------------------------------- audio --

installAudio() {
    msg "===== OLED speakers / microphone (steamdeck-dsp) ====="

    if installed steamdeck-dsp; then
        ok "steamdeck-dsp $(pacman -Q steamdeck-dsp | cut -d' ' -f2) already installed"
        printf '\n'
        return 0
    fi

    warn "steamdeck-dsp is missing. It owns /usr/lib/firmware/amd/sof/sof-vangogh-*,"
    warn "the SOF topology and the OLED's sof-nau8821-max UCM. Nothing in Arch"
    warn "ships those; on an OLED Deck there is no sound without it."
    if ! confirm "Install steamdeck-dsp from Valve's SteamOS repo?"; then
        warn "Skipped."
        printf '\n'
        return 0
    fi

    addRepos

    msg "Refreshing package databases"
    run_root pacman -Sy

    # Exactly one package. No kernel, no firmware set, no full upgrade: this
    # script does not swap anything the running system boots from.
    msg "Installing steamdeck-dsp"
    # shellcheck disable=SC2046
    run_root pacman -S --needed $(pacman_confirm_flag) steamdeck-dsp

    if sofCardPresent; then
        ok "SOF card already up."
    elif lsmod 2>/dev/null | grep -q '^snd_sof_amd_vangogh'; then
        # Driver already probed (and failed) before the firmware existed.
        ok "Installed. snd_sof_amd_vangogh is loaded but found no firmware at boot:"
        msg "  sudo modprobe -r snd_sof_amd_vangogh && sudo modprobe snd_sof_amd_vangogh"
    else
        ok "Installed. SOF probes once, at boot - reboot for speakers and mic."
    fi
    printf '\n'
}

# ---------------------------------------------------------------- rotation --

BACKUP=""

# Everything between the markers is ours and nothing else is. Rerunning must
# replace exactly that range, never "every line mentioning deckarchy".
stripMarked() {
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
      $0 == b { skip=1 }
      !skip
      $0 == e { skip=0 }
    ' "$1"
}

# An hl.monitor rule for the internal panel that we did not write. Two rules
# for one output is last-one-wins in Hyprland, so appending ours would silently
# override a config the user maintains. Print theirs and stay out.
foreignPanelRules() {
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" -v n="\"$INTERNAL\"" '
      $0 == b { skip=1 }
      !skip && /^[[:space:]]*hl\.monitor\(/ && index($0, n) { printf "%d: %s\n", NR, $0 }
      $0 == e { skip=0 }
    ' "$1"
}

# Omarchy 4 parses Hyprland config as Lua, and "hyprctl keyword" refuses to run
# against a non-legacy parser ("keyword can't work with non-legacy parsers").
# So the only way to change a monitor is to write monitors.lua and reload.
writeTransform() {
    t="$1"
    if [ ! -f "$MONITORS_LUA" ]; then err "$MONITORS_LUA not found"; return 1; fi

    if [ "$DRY_RUN" = 1 ]; then
        dry "back up $MONITORS_LUA, then replace the $MARK_BEGIN block with:"
        printf '    hl.monitor({ output = "%s", mode = "preferred", position = "auto", scale = 1, transform = %s })\n' \
            "$INTERNAL" "$t"
        dry "hyprctl reload"
        return 0
    fi

    if [ -z "$BACKUP" ]; then
        BACKUP="$MONITORS_LUA.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$MONITORS_LUA" "$BACKUP"
        msg "Backed up $MONITORS_LUA -> $BACKUP"
    fi

    tmp="$(mktemp)"
    stripMarked "$MONITORS_LUA" > "$tmp"
    {
        cat "$tmp"
        printf '%s\n' "$MARK_BEGIN"
        printf -- '-- Steam Deck internal panel is mounted 90 deg rotated; without a\n'
        printf -- '-- transform Hyprland shows it as 800x1280 portrait. 1 = 90, 3 = 270.\n'
        printf -- '-- ONE line, literal values, no variables: omarchy-hyprland-monitor-\n'
        printf -- '-- clamshell re-reads this rule with sed, line by line, and rewrites\n'
        printf -- '-- what it cannot parse - a multi-line rule gets the panel moved\n'
        printf -- '-- within two seconds of a reload.\n'
        printf 'hl.monitor({ output = "%s", mode = "preferred", position = "auto", scale = 1, transform = %s })\n' \
            "$INTERNAL" "$t"
        printf '%s\n' "$MARK_END"
    } > "$MONITORS_LUA"
    rm -f "$tmp"

    hyprctl reload >/dev/null 2>&1 || true
    errs="$(hyprctl configerrors 2>/dev/null || true)"
    case "$errs" in
        ""|*"no errors"*) return 0 ;;
        *) err "Hyprland reported config errors:"; printf '%s\n' "$errs"
           warn "Restore with: cp '$BACKUP' '$MONITORS_LUA' && hyprctl reload"
           return 1 ;;
    esac
}

restoreRotation() {
    if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
        cp -a "$BACKUP" "$MONITORS_LUA"
        hyprctl reload >/dev/null 2>&1 || true
        warn "Reverted $MONITORS_LUA from $BACKUP"
    fi
}

fixRotation() {
    msg "===== internal panel rotation ====="

    command_exists hyprctl || { warn "Hyprland not running; skipping rotation."; printf '\n'; return 0; }

    if [ ! -f "$MONITORS_LUA" ]; then
        warn "$MONITORS_LUA not found; skipping rotation."
        printf '\n'
        return 0
    fi

    foreign="$(foreignPanelRules "$MONITORS_LUA")"
    if [ -n "$foreign" ]; then
        warn "$MONITORS_LUA already has its own $INTERNAL rule:"
        printf '%s\n' "$foreign" | sed 's/^/    /'
        warn "Not touching it. Set 'transform = 3' on that line yourself, or"
        warn "delete it and re-run."
        printf '\n'
        return 0
    fi

    if [ -n "$ROTATE" ]; then
        writeTransform "$ROTATE" && ok "Applied transform=$ROTATE."
        printf '\n'
        return 0
    fi

    if ! hyprctl monitors 2>/dev/null | grep -q "$INTERNAL"; then
        warn "$INTERNAL not connected; skipping rotation."
        printf '\n'
        return 0
    fi

    if [ "$(panelTransform)" != "0" ]; then
        ok "Internal panel already has transform=$(panelTransform) - leaving it."
        printf '\n'
        return 0
    fi

    warn "The internal panel reports 800x1280 (portrait). On a Steam Deck it"
    warn "should be landscape. Hyprland needs a 'transform' of 3 (270 deg) or"
    warn "1 (90 deg); 3 is correct on the units tested, but check your screen."
    printf '\n'

    # 3 first: verified right-side-up on Steam Deck OLED (Galileo).
    for t in 3 1; do
        writeTransform "$t" || { restoreRotation; printf '\n'; return 1; }
        printf "Applied transform=%s. Is the Deck screen the right way up? [y/N] " "$t"
        read -r reply
        case "$reply" in
            [Yy]*) ok "Kept transform=$t in $MONITORS_LUA."; printf '\n'; return 0 ;;
        esac
    done

    restoreRotation
    warn "Neither looked right. Set it by hand: ./deckarchy.sh --rotate N"
    printf '\n'
}

# --------------------------------------------------------------- migration --

# The old scripts installed Valve's kernel and firmware set. On Omarchy 4 with
# mainline linux none of it is needed. Each step is offered separately and
# never runs on its own: a firmware or kernel swap is exactly the kind of
# change nobody should discover after the fact.
migrate() {
    need_initramfs=0

    if ! installed linux-firmware-neptune && ! ucmFromValve &&
       ! installed linux-neptune-611 && ! installed linux-neptune-611-headers; then
        return 0
    fi

    msg "===== migration back to stock ====="
    warn "Neptune leftovers found. steamdeck-dsp is kept either way - it is"
    warn "still the only source of the OLED DSP firmware."
    printf '\n'

    if installed linux-firmware-neptune; then
        msg "linux-firmware-neptune is installed. Stock linux-firmware ships every"
        msg "blob this hardware loads (ath11k, qca BT, amdgpu vangogh)."
        if confirm "Replace linux-firmware-neptune with stock linux-firmware?"; then
            # No -Rdd first: the two Conflict/Replace each other, so pacman
            # offers the swap itself and the machine is never left without
            # firmware if something fails halfway.
            # shellcheck disable=SC2046
            run_root pacman -S $(pacman_confirm_flag) linux-firmware
            need_initramfs=1
        else
            warn "Skipped."
        fi
        printf '\n'
    fi

    if ucmFromValve; then
        msg "alsa-ucm-conf came from Valve's repo. Upstream alsa-ucm-conf has"
        msg "shipped the Deck's UCM profiles since 1.2.11."
        if confirm "Reinstall stock alsa-ucm-conf from [extra]?"; then
            # shellcheck disable=SC2046
            run_root pacman -S $(pacman_confirm_flag) extra/alsa-ucm-conf
        else
            warn "Skipped."
        fi
        printf '\n'
    fi

    KPKGS=""
    # Plain "a && b" would abort the script under set -e when a is false.
    if installed linux-neptune-611; then KPKGS="linux-neptune-611"; fi
    if installed linux-neptune-611-headers; then KPKGS="${KPKGS:+$KPKGS }linux-neptune-611-headers"; fi
    if [ -n "$KPKGS" ]; then
        msg "Neptune kernel installed: $KPKGS"
        msg "You are running $(uname -r). Removing it frees /boot and stops the"
        msg "extra initramfs builds; keep it if you still boot it sometimes."
        if confirm "Remove $KPKGS?"; then
            # Plain -R. Never -Rdd: dependency checks are the only thing
            # standing between "remove a kernel" and "remove its modules while
            # something still needs them".
            # shellcheck disable=SC2086
            run_root pacman -R $(pacman_confirm_flag) $KPKGS
            need_initramfs=1
        else
            warn "Skipped."
        fi
        printf '\n'
    fi

    if [ "$need_initramfs" = 1 ]; then
        msg "Regenerating initramfs for the remaining kernels"
        run_root mkinitcpio -P
        if installed limine-mkinitcpio-hook; then
            ok "limine-mkinitcpio-hook regenerated the Limine boot entries."
        else
            warn "limine-mkinitcpio-hook is not installed - check /boot/limine.conf"
            warn "for a stale Neptune entry by hand."
        fi
        printf '\n'
    fi
}

# -------------------------------------------------------------------- main --

checkArch
checkPackageManager
checkDistro
if [ "$CHECK_ONLY" = 0 ]; then
    checkEscalationTool
    checkSuperUser
    # Everything the script shells out to later, resolved up front rather than
    # failing halfway through a package swap.
    ensureCommands awk:gawk grep:grep sed:sed mktemp:coreutils jq:jq mkinitcpio:mkinitcpio
fi

detectSteamDeck
printf '\n'

reportHardware

if [ "$CHECK_ONLY" = 1 ]; then
    exit 0
fi

# --rotate is a targeted fix ("put the panel at N"), not a modifier on a full
# run: nobody typing it wants a pacman prompt.
if [ -n "$ROTATE" ]; then
    fixRotation
    exit 0
fi

installAudio
fixRotation
migrate

ok "Done."
