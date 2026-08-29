<div align="center">
<img src="https://i.imgur.com/Dd1UJYI.png" alt="deckarchy" border="0" width="80%">
</div>

---

# deckarchy

Steam Deck support script for [Omarchy](https://omarchy.org) 4 (Quattro).

⚠️ **EXPERIMENTAL** — tested on Steam Deck OLED (Galileo) + Omarchy 4.0.1.
The LCD model (Jupiter) should work by the same reasoning, but is untested.

Omarchy 4 installs from [its own ISO](https://omarchy.org) — there is no
"vanilla Arch first" step anymore ([manual](https://omarchy.org/manual/)).
Install Omarchy on the Deck the normal way, boot it, then run this.

```
flash ISO → install Omarchy → boot → clone this repo → ./deckarchy.sh
```

## What's actually missing from a vanilla install

Almost nothing. Mainline `linux` (7.x) drives the whole Deck, and stock
`linux-firmware` ships every file the hardware loads — verified per file
against Arch's split firmware packages:

| Hardware | Firmware | Stock package |
|---|---|---|
| Wi-Fi | `ath11k/QCA2066/hw2.1/*` | `linux-firmware-atheros` ✅ |
| Bluetooth | `qca/hpbtfw21.tlv`, `qca/hpnv21g.309` | `linux-firmware-atheros` ✅ |
| GPU | `amdgpu/vangogh_*` | `linux-firmware-amdgpu` ✅ |
| LCD Deck audio UCM | `acp5x` / `Valve-Jupiter-1` | `alsa-ucm-conf` ✅ (upstreamed) |
| **OLED speakers/mic DSP** | `amd/sof/sof-vangogh-*` + UCM | **nothing** ❌ |

Two things remain, and they are all `deckarchy.sh` does:

1. **`steamdeck-dsp`** from Valve's SteamOS repo — SOF vangogh DSP firmware,
   topology, and the OLED's `sof-nau8821-max` UCM. Without it the OLED has no
   speakers or microphone. The script adds Valve's repo *temporarily*
   (`SigLevel = Optional TrustAll`, removed again on exit via trap), installs
   just that one package, and cleans up.
2. **Panel rotation** — the internal panel is mounted 90° rotated, which
   Omarchy can't guess. The script writes a `transform = 3` `hl.monitor` rule
   for `eDP-1` into `~/.config/hypr/monitors.lua` as a clearly marked block.
   Omarchy 4 parses Hyprland config as Lua, so `hyprctl keyword` doesn't work —
   editing `monitors.lua` is the only way. If your `monitors.lua` already has
   its own `eDP-1` rule, the script refuses to touch it.

## Install

Clone it — do **not** pipe it to a shell. The script sources
`common-script.sh` from its own directory, so it needs to exist on disk.

```bash
git clone https://github.com/sslava/deckarchy
cd deckarchy
./deckarchy.sh --check    # hardware report only, changes nothing
./deckarchy.sh            # full run, prompting before each change
```

### Flags

```
deckarchy.sh
  (no args)      full run: hardware report → install steamdeck-dsp if missing
                 → offer rotation fix → offer migration if Neptune leftovers found
  --check        hardware report only
  --dry-run      print every command, change nothing
  --yes          pass --noconfirm to pacman (unattended)
  --rotate N     set internal panel transform to N (0-3) non-interactively
  --keep-repos   leave the Valve repo in pacman.conf afterwards
  --force        run on non-Deck hardware anyway
```

## Coming from the old scripts / a Neptune install

Earlier versions of this repo (and this repo's upstream) installed Valve's
Neptune kernel and firmware set. On Omarchy 4 + mainline 7.x none of that is
needed anymore:

| Package | Verdict |
|---|---|
| `linux-neptune-611` (+ headers) | not needed — mainline covers the hardware |
| `linux-firmware-neptune` | not needed — and it `Replaces` stock `linux-firmware` |
| `alsa-ucm-conf` (jupiter build) | not needed — upstream ships the Deck UCM now |
| `steamdeck-dsp` | **keep** — still the only source of the OLED DSP |

`./deckarchy.sh` detects the leftovers and offers a step-by-step migration
back to stock: swap `linux-firmware` back in over `linux-firmware-neptune`,
reinstall stock `alsa-ucm-conf`, optionally remove the Neptune kernel, then
`mkinitcpio -P`.

## Safety notes

The script deliberately avoids the things that make Deck scripts dangerous:

1. **No `SigLevel = Never`.** Valve's repo is added with
   `SigLevel = Optional TrustAll`. `Never` disables signature checking
   permanently for every future `pacman -Syu`, not just the install.
2. **Repos are temporary.** They are removed again when the script exits
   (an `EXIT`/`INT`/`TERM` trap, so it happens on Ctrl-C too). Valve's staging
   repos track an *unstable* channel — you do not want them wired into your
   system permanently. Use `--keep-repos` to opt out.
3. **No `pacman -Rdd`.** Package swaps go through pacman's normal
   `Replaces`/`Conflicts` resolution. Force-removing firmware leaves the
   machine with *no* firmware at all if anything fails in between.
4. **Backups + sanity checks.** `/etc/pacman.conf` is backed up before it is
   touched, and the script refuses to write it back if `[core]` or `[extra]`
   went missing. `monitors.lua` is backed up before the rotation block is
   written.

## Credits

Helper-script structure adapted from
[Chris Titus Tech's LinUtil](https://github.com/ChrisTitusTech/linutil).
Forked from [aorumbayev/deckarchy](https://github.com/aorumbayev/deckarchy).

## License

MIT — see [LICENSE](LICENSE).
