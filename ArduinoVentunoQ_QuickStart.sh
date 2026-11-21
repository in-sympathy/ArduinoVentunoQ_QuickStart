#!/usr/bin/env bash
#
# ArduinoVentunoQ_QuickStart.sh
# https://github.com/in-sympathy/ArduinoVentunoQ_QuickStart
#
# Post-flash provisioning for the Arduino VENTUNO Q boards in the NIVROKU
# lab, plus switching which root filesystem the board boots: the eMMC or
# an NVMe SSD.
#
# There is NO default run: nothing happens unless you name it. Run the
# script with no flags at all and it lists every flag and asks which ones
# to use. Every stage checks its own work first and skips anything
# already applied, so re-running any flag is always safe.
#
# Setup stages -- any combination; they always run in this order, whatever
# order the flags come in:
#   --code-dir       Create ~/Code, owned by you: the working folder for
#                    git clones and board files.
#   --zsh            Install zsh + zsh-autosuggestions + zsh-syntax-
#                    highlighting, make it the login shell, deploy .zshrc.
#   --tools          apt update && full-upgrade (kernel included), install
#                    fastfetch, sysbench, btop, flashrom, and Ookla
#                    Speedtest CLI.
#   --sudo           Passwordless sudo for the invoking user, via a
#                    validated /etc/sudoers.d/ drop-in.
#   --github-ssh     Generate (or reuse) an ed25519 key for GitHub access,
#                    print the public key with setup steps. Never touches
#                    GitHub itself.
#
# Boot root -- at most one; always runs AFTER the setup stages (see BOOT
# ROOT below for why):
#   --nvme-switch    Copy this eMMC root onto the NVMe (partitioning and
#                    formatting it if needed) and boot the NVMe root from
#                    the next boot on. The last thing to do on the eMMC
#                    root: reboot right after it.
#   --emmc-rollback  Boot the eMMC root again (turns the boot sync off).
#   --status         Show where the next boot goes and the sync state.
#
# Modifiers:
#   -n, --dry-run    Make --nvme-switch / --emmc-rollback check everything
#                    and change nothing. Refused next to setup stages:
#                    they have no dry-run mode and would change the board.
#   -y, --yes        Skip the y/N question of --nvme-switch /
#                    --emmc-rollback. Never skips the typed "yes" asked
#                    before overwriting data already on the NVMe.
#       --reboot     Reboot once everything has finished (never after a
#                    dry run).
#
# Flags also work without the leading "--" (nvme-switch = --nvme-switch).
#
# REQUIREMENTS
#   * Run as your normal user -- NOT as root, NOT via sudo. The script
#     calls sudo itself wherever it needs privilege. A boot-root action is
#     root work from start to finish, so for that one it re-runs this same
#     file under sudo (see run_boot_action()).
#   * Run it from a file (a git clone), not piped into bash: that re-run
#     needs the script's own path.
#   * The no-flags list needs a terminal to ask on. Without one, the
#     script prints the flags and exits without doing anything.
#   * Written for the VENTUNO Q's stock Ubuntu image; Debian works too.
#
# USAGE
#   git clone https://github.com/in-sympathy/ArduinoVentunoQ_QuickStart.git
#   cd ArduinoVentunoQ_QuickStart && chmod +x ArduinoVentunoQ_QuickStart.sh
#   ./ArduinoVentunoQ_QuickStart.sh                    # list the flags, ask which to use
#   ./ArduinoVentunoQ_QuickStart.sh --code-dir --zsh --tools --sudo --github-ssh
#   ./ArduinoVentunoQ_QuickStart.sh --code-dir --zsh --tools --sudo --github-ssh --nvme-switch --reboot
#                                                      # fresh flash: set up, move to the NVMe, boot it
#   ./ArduinoVentunoQ_QuickStart.sh --status           # where does the next boot go?
#   ./ArduinoVentunoQ_QuickStart.sh --nvme-switch -n   # verify the switch, change nothing
#   ./ArduinoVentunoQ_QuickStart.sh --nvme-switch --reboot
#   ./ArduinoVentunoQ_QuickStart.sh --emmc-rollback -y --reboot
#   ./ArduinoVentunoQ_QuickStart.sh --help
#
# BOOT ROOT
#   GRUB, the kernel and the initrd always load from the eMMC; the eMMC
#   grub.cfg decides whether the kernel then mounts the eMMC root
#   (/dev/mmcblk0p71) or the NVMe root (/dev/nvme0n1p1).
#   * --nvme-switch, run from the eMMC root, is the whole migration:
#       1. Checks, changing nothing: what's on the NVMe drive, room for
#          the copy, the grub.cfg the NVMe root will boot with, and that
#          the default kernel can mount an NVMe root at all (NVMe driver
#          built in or in its initramfs). --dry-run stops here.
#       2. Asks. A blank NVMe gets a y/N (-y skips it). Anything that
#          destroys data already on the NVMe -- replacing the NVMe root an
#          earlier switch made, or wiping whatever else is on the drive --
#          needs a typed "yes", which -y never skips.
#       3. Stops Docker and the automatic apt runs until the reboot, and
#          waits out any apt already running, so the eMMC root holds still.
#       4. Gives a blank (or wiped) drive one GPT partition, formatted ext4
#          and labelled nvme-root; an NVMe root from an earlier switch is
#          reused in place, keeping its UUID.
#       5. Copies the eMMC root filesystem onto it -- rsync -aHAXx through
#          a read-only bind mount of /, two passes, resumable if cut short
#          -- and points the copy's /etc/fstab at the NVMe. Other eMMC
#          partitions this root mounts (the ESP at /boot/efi, say) aren't
#          copied: the NVMe root keeps mounting them from the eMMC.
#       6. Boot config: the eMMC grub.cfg gets root=UUID=<NVMe> rootdelay=30
#          on every kernel line and the eMMC UUID on every search line,
#          because GRUB can only read the eMMC. On the NVMe root it installs
#          the boot sync -- /usr/local/sbin/sync-boot-emmc, run by a shutdown
#          unit and by an apt DPkg::Post-Invoke hook -- which keeps
#          mirroring the NVMe /boot to the eMMC, so a kernel upgraded on the
#          NVMe root is the one GRUB loads (and re-points the ESP's GRUB stub
#          at the eMMC if a GRUB upgrade's grub-install aimed it at the
#          NVMe); plus a GRUB drop-in that keeps update-grub on the NVMe root
#          writing root=UUID=<NVMe>.
#     It's the last thing a run does, and must be the last thing done on
#     the eMMC root: nothing changed there afterwards reaches the NVMe, and
#     an update-grub there would point the next boot back at the eMMC. So
#     reboot right after it (or give --reboot); until then the script
#     refuses to run setup stages on the eMMC root.
#     Run from the NVMe root, --nvme-switch copies nothing (that root is in
#     use) and only re-applies the boot config.
#   * --emmc-rollback points every kernel line of the eMMC grub.cfg back
#     at the eMMC root, copies in the kernel modules the eMMC root lacks
#     for kernels that came over from the NVMe, and turns the sync off. It
#     doesn't copy the NVMe root back: the eMMC root comes back as it was
#     when --nvme-switch copied it.
#   * Both back the old grub.cfg up under /var/backups/ventuno-boot/ on the
#     eMMC root, swap the new one in atomically, verify it again, and
#     restore the backup if that check fails.
#   * The boot action runs after the setup stages so that nothing a setup
#     stage does -- an update-grub during --tools, say -- can overwrite it
#     in the same run.
#
# ADDING A NEW STAGE
#   1. Write a function stage_<name>() below, near the others. Keep its
#      tunables as `local` variables inside the function so they can't
#      collide with other stages' variables as more get added.
#   2. Add its id to SETUP_STAGE_IDS, in the position you want it to run.
#   3. Add one line each to STAGE_DESCRIPTIONS and STAGE_FUNCS.
#   Its --<id> flag, its number in the no-flags list, --help and the
#   runner all pick it up from there -- nothing else to wire up.
#
# This file can also be `source`d (e.g. to test one function in
# isolation) without triggering a run -- see the guard at the very bottom.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "ArduinoVentunoQ_QuickStart.sh needs bash. Run: bash ArduinoVentunoQ_QuickStart.sh" >&2
  exit 1
fi

# -E (errtrace) is required for the ERR trap below to fire on failures
# that happen inside a function -- which is where all our real work
# lives. Without it, `set -e` still aborts correctly, but the trap that
# prints *why* silently never runs.
set -Eeuo pipefail

# ============================================================
# Global config
# ============================================================

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# This file's own absolute path -- run_boot_action() re-runs it under sudo.
# Empty when the script didn't come from a file (piped into bash).
SELF_PATH="$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null || true)"
readonly SELF_PATH

LOG_DIR="${LOG_DIR:-$HOME/.ventuno-q-deploy/logs}"
RUN_LOG=""   # set by init_run_log() once the flags are settled

# The working folder for git clones and board files (see stage_code_dir).
readonly CODE_DIR="$HOME/Code"

# Exit status of the root re-run when its confirmation prompt gets
# anything but y -- lets the main run tell "declined" apart from "failed".
readonly EXIT_DECLINED=3

CURRENT_STAGE=""
APT_UPDATED=0
SUDO_KEEPALIVE_PID=""

# What this run does -- filled in by parse_flags().
SELECTED_STAGES=()
BOOT_ACTION=""
DRY_RUN=0
ASSUME_YES=0
DO_REBOOT=0
CANONICAL_FLAGS=()
PARSE_ERROR=""

# ============================================================
# Logging
# ============================================================

# Prints a line and appends it to the run log. Until the run log exists
# (flag errors, the no-flags list) it only prints.
emit() {
  if [[ -n "$RUN_LOG" ]]; then
    printf '%s\n' "$1" | tee -a "$RUN_LOG"
  else
    printf '%s\n' "$1"
  fi
}

log() {
  emit "[$(date '+%F %T')] $*"
}

warn() {
  log "WARN: $*" >&2
}

error() {
  log "ERROR: $*" >&2
}

die() {
  error "$*"
  exit 1
}

# Plain, un-timestamped, copy-pasteable tip -- still saved to the log.
hint() {
  emit "    $*"
}

init_run_log() {
  mkdir -p "$LOG_DIR"
  RUN_LOG="$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log"
}

# ============================================================
# Error handling / cleanup
# ============================================================

on_error() {
  local exit_code=$? line_no="$1"
  # shellcheck disable=SC2016  # the single quotes are literal text inside a double-quoted string
  error "command failed (exit $exit_code) at line $line_no${CURRENT_STAGE:+, during stage '$CURRENT_STAGE'}"
}

start_sudo_keepalive() {
  (
    set +e
    while kill -0 "$$" 2>/dev/null; do
      sudo -n true 2>/dev/null
      sleep 60
    done
  ) &
  SUDO_KEEPALIVE_PID=$!
}

stop_sudo_keepalive() {
  if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
}

# ============================================================
# Small helpers
# ============================================================

contains() {
  local needle="$1" straw
  shift
  for straw in "$@"; do
    [[ "$straw" == "$needle" ]] && return 0
  done
  return 1
}

# Refresh the apt index at most once per run, so stages that need it
# (and any future ones) don't each pay for their own `apt update`.
ensure_apt_index_fresh() {
  if [[ "$APT_UPDATED" -eq 1 ]]; then
    log "Package index already refreshed this run, skipping apt update"
    return 0
  fi
  log "Updating package index"
  sudo apt update -qq
  APT_UPDATED=1
}

# write_if_changed <dest_path> <tmp_content_path> [sudo]
#
# The idempotency primitive every stage below uses for the files it
# deploys: compares tmp_content_path (already-written new content)
# against dest_path byte-for-byte.
#   * Identical (dest exists and matches)  -> leaves dest alone, returns 1.
#   * Different or dest doesn't exist yet  -> backs up any existing dest
#     (timestamped), installs the new content, returns 0.
# Pass "sudo" as the third argument when dest needs root to read/write.
# Callers use the return value to decide what to log and whether any
# dependent action (systemctl reload, etc.) is actually necessary.
write_if_changed() {
  local dest="$1" tmp="$2" use_sudo="${3:-}"
  local as=()
  [[ "$use_sudo" == "sudo" ]] && as=(sudo)

  if "${as[@]}" test -f "$dest" && "${as[@]}" cmp -s "$tmp" "$dest"; then
    return 1
  fi
  if "${as[@]}" test -f "$dest"; then
    "${as[@]}" cp "$dest" "$dest.bak.$(date +%Y%m%d%H%M%S)"
  fi
  "${as[@]}" cp "$tmp" "$dest"
  return 0
}

# Ubuntu runs unattended-upgrades, which can hold the package locks for
# minutes right after a boot -- a fresh board's first boot especially.
# `apt` waits up to 120 s for them; dpkg and apt-get don't wait at all and
# fail with "dpkg frontend lock was locked by another process". So the
# stages that install packages wait here first, up to 15 minutes.
wait_for_package_locks() {
  command -v lslocks >/dev/null 2>&1 || return 0
  local waited=0 limit=900 locks as=()
  [[ "$EUID" -eq 0 ]] || as=(sudo)   # the boot actions call this as root
  while :; do
    locks="$("${as[@]}" lslocks -n -o PATH 2>/dev/null || true)"
    grep -qxE '/var/lib/dpkg/lock-frontend|/var/lib/apt/lists/lock' <<< "$locks" || break
    if (( waited == 0 )); then
      log "Another package manager is running (unattended-upgrades after boot, most likely) -- waiting for it to finish"
    fi
    (( waited < limit )) || die "The package locks are still held after $((limit / 60)) minutes. See who holds them: sudo lslocks | grep -E 'dpkg|apt'"
    sleep 5
    waited=$((waited + 5))
  done
  if (( waited > 0 )); then
    log "Package locks free after ${waited}s"
  fi
}

# Version apt would install for package $1, or nothing if there's none.
apt_candidate() {
  local cand
  cand="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
  [[ "$cand" == "(none)" ]] || printf '%s' "$cand"
}

# ============================================================
# Preflight
# ============================================================

preflight_checks() {
  command -v sudo >/dev/null 2>&1 || die "sudo is required but not found on PATH."

  # Missing disks are caught here, before the setup stages take their
  # time, rather than in the boot action at the very end.
  if [[ -n "$BOOT_ACTION" ]]; then
    [[ -n "$SELF_PATH" && -f "$SELF_PATH" ]] || die "Boot-root flags re-run this script under sudo, so it has to run from a file (git clone), not piped into bash."
    [[ -b "$EMMC_DEV" ]] || die "$EMMC_DEV (the eMMC root) not found -- is this a VENTUNO Q? Nothing was changed."
    if [[ "$BOOT_ACTION" == "nvme-switch" && ! -b "$NVME_DISK" ]]; then
      die "No NVMe drive found ($NVME_DISK). Nothing was changed."
    fi
  fi

  # Try `sudo -n true` first: once the sudo stage has set up passwordless
  # sudo, it succeeds without a prompt. `sudo -v` alone would still ask,
  # because sudoers' default verifypw=all wants NOPASSWD on *every* rule
  # matching you, and the image's own %sudo rule doesn't have it.
  if ! sudo -n true 2>/dev/null; then
    log "Requesting sudo access (you may be prompted for your password)"
    sudo -v || die "Could not obtain sudo privileges."
  fi
  start_sudo_keepalive

  # The boot actions copy with rsync and partition with sfdisk (Ubuntu's
  # "fdisk" package); a minimal image can lack either. A dry run only
  # reads, so it doesn't install anything.
  if [[ "$BOOT_ACTION" == "nvme-switch" || "$BOOT_ACTION" == "emmc-rollback" ]] && (( ! DRY_RUN )); then
    local need=() tool
    for tool in rsync sfdisk; do
      command -v "$tool" >/dev/null 2>&1 || [[ -x "/usr/sbin/$tool" || -x "/sbin/$tool" ]] || need+=("$tool")
    done
    if (( ${#need[@]} )); then
      local pkgs=("${need[@]/sfdisk/fdisk}")
      wait_for_package_locks
      ensure_apt_index_fresh
      log "Installing what the boot actions need: ${pkgs[*]}"
      sudo apt install -y "${pkgs[@]}"
    fi
  fi
}

# True while a --nvme-switch made from the eMMC root hasn't been booted into
# yet: the eMMC root still runs, but the next boot goes to its NVMe copy.
nvme_switch_pending() {
  local nvme_uuid kernel_lines
  [[ "$(findmnt -n -o SOURCE / 2>/dev/null || true)" == "$EMMC_DEV" && -b "$NVME_DEV" ]] || return 1
  nvme_uuid="$(sudo blkid -p -s UUID -o value "$NVME_DEV" 2>/dev/null || true)"
  [[ -n "$nvme_uuid" ]] || return 1
  kernel_lines="$(sudo grep -E '^[[:space:]]*linux[[:space:]]' /boot/grub/grub.cfg 2>/dev/null || true)"
  grep -q "root=UUID=${nvme_uuid}" <<< "$kernel_lines"
}

# ============================================================
# Stage: code-dir
# ============================================================
#
# ~/Code is the working folder on every lab board: git clones go there,
# and so do board-specific files. It has to belong to you, not root, so
# git and editors work in it without sudo. If it already exists but
# belongs to someone else (e.g. a sudo command created it), only the
# folder itself is handed back to you; what's inside is left as it is.

stage_code_dir() {
  local me owner
  me="$(id -un):$(id -gn)"
  if [[ -e $CODE_DIR && ! -d $CODE_DIR ]]; then
    die "$CODE_DIR exists but isn't a folder -- move it aside and re-run."
  fi
  if [[ ! -d $CODE_DIR ]]; then
    mkdir -p "$CODE_DIR"
    log "Created $CODE_DIR"
    return 0
  fi
  owner="$(stat -c '%U:%G' "$CODE_DIR")"
  if [[ $owner != "$me" ]]; then
    sudo chown "$me" "$CODE_DIR"
    log "Gave $CODE_DIR back to $me (it belonged to $owner); its contents were left as they are"
  else
    log "$CODE_DIR already exists and belongs to $me"
  fi
}

# ============================================================
# Stage: zsh
# ============================================================

stage_zsh() {
  local zsh_packages=(zsh zsh-common zsh-autosuggestions zsh-syntax-highlighting)

  # Checks each package's actual Status field, not `dpkg -s`'s exit code:
  # dpkg -s exits 0 for any package it merely has a record of, including
  # half-configured/unpacked-but-not-configured ones -- exactly what a
  # reboot mid-upgrade leaves behind -- and the stage would then skip the
  # apt install that finishes configuring them.
  local zsh_all_installed=1
  local pkg status
  for pkg in "${zsh_packages[@]}"; do
    status="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
    [[ "$status" == "install ok installed" ]] || { zsh_all_installed=0; break; }
  done

  if [[ "$zsh_all_installed" -eq 1 ]]; then
    log "zsh and plugins already installed, skipping apt install"
  else
    wait_for_package_locks
    ensure_apt_index_fresh
    log "Installing zsh and plugins"
    sudo apt install -y "${zsh_packages[@]}"
  fi

  local target_user zsh_path current_shell
  target_user="$(id -un)"
  zsh_path="$(command -v zsh)"
  current_shell="$(getent passwd "$target_user" | cut -d: -f7)"

  if [[ "$current_shell" != "$zsh_path" ]]; then
    log "Setting login shell to $zsh_path for $target_user"
    sudo chsh -s "$zsh_path" "$target_user"
  else
    log "Login shell for $target_user is already $zsh_path"
  fi

  # NOTE: the banner-suppression flag inside this file uses the literal
  # text "#{UID}", not the shell parameter ${UID}. That's kept exactly as
  # given -- but as written it will NOT be expanded by sh/zsh, so every
  # user/session shares one flag file ("/tmp/.nivroku_#{UID}") instead of
  # getting a per-UID one. Change it to ${UID} below if that's not what
  # you want.
  local zshrc="$HOME/.zshrc"
  local tmp_zshrc
  tmp_zshrc="$(mktemp)"
  cat > "$tmp_zshrc" <<'ZSHRC_CONTENT'
# Load autosuggestions
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh

# Load syntax highlighting
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# Set up the prompt

autoload -Uz promptinit
promptinit
prompt adam1

# adam1's built-in hostname field is %m (short hostname, up to the first
# '.'), not %M (full hostname). It sets $base_prompt once at setup time
# and its precmd hook re-reads that same variable on every prompt draw,
# so mutating it here -- after the theme is loaded -- is enough; no need
# to touch the hook or the theme file itself. The backslash before %m is
# required: zsh's pattern matcher treats a bare % as special and it
# silently fails to match without it.
base_prompt="${base_prompt//\%m/%M}"

setopt histignorealldups sharehistory

# Use emacs keybindings even if our EDITOR is set to vi
bindkey -e

# Keep 1000 lines of history within the shell and save it to ~/.zsh_history:
HISTSIZE=1000
SAVEHIST=1000
HISTFILE=~/.zsh_history

# Use modern completion system
autoload -Uz compinit
compinit -u

zstyle ':completion:*' auto-description 'specify: %d'
zstyle ':completion:*' completer _expand _complete _correct _approximate
zstyle ':completion:*' format 'Completing %d'
zstyle ':completion:*' group-name ''
zstyle ':completion:*' menu select=2
eval "$(dircolors -b)"
zstyle ':completion:*:default' list-colors ${(s.:.)LS_COLORS}
zstyle ':completion:*' list-colors ''
zstyle ':completion:*' list-prompt %SAt %p: Hit TAB for more, or the character to insert%s
zstyle ':completion:*' matcher-list '' 'm:{a-z}={A-Z}' 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=* l:|=*'
zstyle ':completion:*' menu select=long
zstyle ':completion:*' select-prompt %SScrolling active: current selection at %p%s
zstyle ':completion:*' use-compctl false
zstyle ':completion:*' verbose true

zstyle ':completion:*:*:kill:*:processes' list-colors '=(#b) #([0-9]#)*=0=01;31'
zstyle ':completion:*:kill:*' command 'ps -u $USER -o pid,%cpu,tty,cputime,cmd'

# Show NIVROKU banner
[[ $- != *i* ]] && return

banner="$HOME/NivrokuGreeter.txt"
flag="/tmp/.nivroku_#{UID}"

if [[ -r "$banner" && ! -e "$flag" ]]; then
 cat "$banner"
 : > "$flag"
fi
ZSHRC_CONTENT

  if write_if_changed "$zshrc" "$tmp_zshrc"; then
    log "Wrote $zshrc"
  else
    log "$zshrc already up to date, skipping"
  fi
  rm -f "$tmp_zshrc"
}

# ============================================================
# Stage: tools
# ============================================================

stage_tools() {
  : > "$LOG_DIR/updates.log"
  log "apt/install output also being teed to $LOG_DIR/updates.log"
  wait_for_package_locks

  # Finish configuring anything dpkg left half-done. A board that's been
  # rebooted mid-upgrade can easily have a package stuck "unpacked but
  # not configured" from an interrupted dpkg run -- this repairs that
  # before anything else touches the package database. Safe and fast
  # when there's nothing pending.
  log "Repairing any half-configured packages (dpkg --configure -a)"
  sudo dpkg --configure -a 2>&1 | tee -a "$LOG_DIR/updates.log"

  # Kernel packages are NOT held here -- the kernel this board boots comes
  # from the image's own apt sources, built for this SoC, so a kernel bump
  # is an update like any other. On the NVMe root, the boot sync's apt
  # hook mirrors a new kernel to the eMMC /boot that GRUB loads from. If
  # anything left a kernel package held, release it so full-upgrade
  # actually updates it like everything else.
  local kernel_pkgs
  kernel_pkgs="$(dpkg-query -W -f='${Package}\n' 'linux-image*' 'linux-headers*' 'linux-modules*' 2>/dev/null || true)"
  if [[ -n "$kernel_pkgs" ]]; then
    local already_held pkg held_now=()
    already_held="$(apt-mark showhold 2>/dev/null || true)"
    while IFS= read -r pkg; do
      [[ -z "$pkg" ]] && continue
      grep -qxF "$pkg" <<< "$already_held" && held_now+=("$pkg")
    done <<< "$kernel_pkgs"

    if (( ${#held_now[@]} )); then
      log "Releasing kernel package hold(s): ${held_now[*]}"
      sudo apt-mark unhold "${held_now[@]}" >/dev/null
    fi
  fi

  log "apt update & full-upgrade"
  sudo apt update 2>&1 | tee -a "$LOG_DIR/updates.log"

  # Not a block, just a heads-up: print it plainly if this upgrade
  # includes a kernel version change, so it's the first thing you think
  # of if display/hardware behavior looks different afterward.
  if [[ -n "$kernel_pkgs" ]]; then
    local pkg cur cand
    while IFS= read -r pkg; do
      [[ -z "$pkg" ]] && continue
      cur="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
      cand="$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/{print $2}')"
      if [[ -n "$cur" && -n "$cand" && "$cur" != "$cand" ]]; then
        warn "This upgrade includes a kernel change: $pkg $cur -> $cand"
      fi
    done <<< "$kernel_pkgs"
  fi

  sudo apt full-upgrade -y 2>&1 | tee -a "$LOG_DIR/updates.log"
  APT_UPDATED=1

  log "Ensuring sysbench, btop, flashrom, fastfetch, and speedtest are installed"

  local pkg
  for pkg in sysbench btop flashrom; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
      sudo apt install -y "$pkg" 2>&1 | tee -a "$LOG_DIR/updates.log"
    fi
  done

  if ! command -v fastfetch >/dev/null; then
    local fastfetch_url="https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-aarch64.deb"
    curl -fL --retry 3 "$fastfetch_url" -o "$LOG_DIR/fastfetch.deb" 2>&1 | tee -a "$LOG_DIR/updates.log"
    sudo dpkg -i "$LOG_DIR/fastfetch.deb" 2>&1 | tee -a "$LOG_DIR/updates.log" || true
    sudo apt -f install -y 2>&1 | tee -a "$LOG_DIR/updates.log"
    rm -f "$LOG_DIR/fastfetch.deb"
  fi

  # Ookla's own repo, not a distro-packaged tool -- installed via their
  # official packagecloud script. Two independent things to check before
  # doing anything, so re-runs (and --tools on its own) stay cheap:
  #   1. is the package already installed
  #   2. is the repo already registered (so we don't re-fetch+re-run a
  #      root shell script off the network for no reason)
  if command -v speedtest >/dev/null 2>&1; then
    log "Ookla Speedtest CLI already installed, skipping"
  else
    local ookla_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
    local ookla_repo_list="/etc/apt/sources.list.d/ookla_speedtest-cli.list"
    if [[ -f "$ookla_repo_list" ]]; then
      log "Ookla repository already registered, skipping repo-install script"
    else
      log "Adding the Ookla Speedtest repository"
      curl -fsSL "$ookla_script" | sudo bash
    fi

    # Ookla stopped publishing before Ubuntu 24.04 (noble): packagecloud
    # happily sets the repo up for noble, but there's no speedtest
    # package in it. Their binary is static, so on an Ubuntu release with
    # no candidate the repo is pointed at the jammy (22.04) build instead
    # -- the same binary.
    if [[ -z "$(apt_candidate speedtest)" ]] && grep -qx 'ID=ubuntu' /etc/os-release; then
      log "Ookla's repo has no speedtest for this Ubuntu release -- using their jammy (22.04) build, a static binary that runs unchanged"
      curl -fsSL "$ookla_script" | sudo env os=ubuntu dist=jammy bash
    fi
    [[ -n "$(apt_candidate speedtest)" ]] || die "Ookla's repo ($ookla_repo_list) has no speedtest package for this release."

    log "Installing speedtest"
    sudo apt-get install -y speedtest 2>&1 | tee -a "$LOG_DIR/updates.log"
  fi

  hint "First real run needs license acceptance: speedtest --accept-license --accept-gdpr"
}

# ============================================================
# Stage: sudo
# ============================================================
#
# Passwordless sudo for the invoking user. This is a single-technician
# lab devboard, not a shared system -- anyone with physical access to it
# can already do far more than "run a command as root" (this whole lab
# exists to do BGA/eMMC/PMIC level work, which is a much lower bar to
# clear than "knows the sudo password"), so the password prompt on every
# sudo call is friction without a matching benefit here.
#
# This writes to /etc/sudoers.d/, which is exactly the kind of file
# where a mistake is expensive (a bad edit can break sudo entirely), so
# the content is validated with `visudo -c` BEFORE it's ever installed,
# never after.

stage_sudo() {
  local target_user
  target_user="$(id -un)"

  # visudo lives in /usr/sbin, which a non-root user's PATH commonly does
  # NOT include (that's the whole reason this script insists on running
  # as a normal user rather than root) -- `command -v visudo` fails there
  # even though the binary is sitting right there. Check the well-known
  # locations directly instead of trusting PATH for this one.
  local visudo_bin="" candidate
  for candidate in /usr/sbin/visudo /sbin/visudo /usr/local/sbin/visudo; do
    if [[ -x "$candidate" ]]; then
      visudo_bin="$candidate"
      break
    fi
  done
  [[ -n "$visudo_bin" ]] || visudo_bin="$(command -v visudo || true)"
  [[ -n "$visudo_bin" ]] || die "visudo not found (checked /usr/sbin, /sbin, /usr/local/sbin, and \$PATH) -- it ships with the sudo package, which must already be installed for this script to have gotten this far. Refusing to install an unvalidated sudoers file."

  local sudoers_file="/etc/sudoers.d/${target_user}-nopasswd"
  local tmp_sudoers
  tmp_sudoers="$(mktemp)"
  cat > "$tmp_sudoers" <<SUDOERS_CONTENT
# Auto-generated by ArduinoVentunoQ_QuickStart.sh (sudo stage). Passwordless sudo for
# $target_user -- see the comment above stage_sudo() in the script for why.
$target_user ALL=(ALL) NOPASSWD: ALL
SUDOERS_CONTENT
  chmod 0440 "$tmp_sudoers"

  local check_output
  if ! check_output="$("$visudo_bin" -c -f "$tmp_sudoers" 2>&1)"; then
    rm -f "$tmp_sudoers"
    die "Generated sudoers content failed validation, refusing to install it: $check_output"
  fi

  if write_if_changed "$sudoers_file" "$tmp_sudoers" sudo; then
    sudo chown root:root "$sudoers_file"
    sudo chmod 0440 "$sudoers_file"
    log "Wrote $sudoers_file -- $target_user no longer needs a password for sudo"
  else
    log "$sudoers_file already up to date, skipping"
  fi
  rm -f "$tmp_sudoers"

  hint "Verify: sudo -k && sudo whoami   (should run with no password prompt)"
}

# ============================================================
# Stage: github-ssh
# ============================================================
#
# Generates (or reuses) an SSH key for this board to authenticate to
# GitHub, and prints the public key plus the steps to register it.
# Doesn't touch GitHub itself -- adding the key to the account at
# https://github.com/settings/ssh/new is a manual step every time, on
# every board, so this stage is idempotent on the *key material* (skip
# generation if a key already exists) but always re-prints the public
# key and instructions, since re-running it just to get the key back on
# screen is a legitimate use on its own.
#
# ed25519, no passphrase: consistent with this lab's passwordless-sudo
# posture elsewhere in this script -- a single-technician, physically
# controlled devboard, where a passphrase prompt on every git fetch is
# friction without a matching benefit. If you reuse this on a different
# kind of deployment, reconsider this (and the sudo stage) specifically.

# github_port_open <host> <port>
# Succeeds if <host> accepts a TCP connection on <port> within 5 seconds.
github_port_open() {
  # shellcheck disable=SC2016  # $0/$1 are for the inner bash to expand
  timeout 5 bash -c '</dev/tcp/$0/$1' "$1" "$2" 2>/dev/null
}

stage_github_ssh() {
  local ssh_dir="$HOME/.ssh"
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"

  # Prefer an existing key over generating a second one, checked in this
  # order. (id_dsa is deliberately not checked -- GitHub stopped
  # accepting DSA keys years ago, so finding one isn't a reason to skip
  # generating a key that will actually work.)
  local key_types=(ed25519 ecdsa rsa)
  local key_type priv_key="" pub_key=""
  for key_type in "${key_types[@]}"; do
    if [[ -f "$ssh_dir/id_$key_type" ]]; then
      priv_key="$ssh_dir/id_$key_type"
      pub_key="$priv_key.pub"
      break
    fi
  done

  if [[ -n "$priv_key" ]]; then
    log "Existing SSH key found ($(basename "$priv_key")), skipping generation"
    if [[ ! -f "$pub_key" ]]; then
      warn "$pub_key is missing even though $priv_key exists -- regenerating the public half from it"
      ssh-keygen -y -f "$priv_key" > "$pub_key"
    fi
  else
    priv_key="$ssh_dir/id_ed25519"
    pub_key="$priv_key.pub"
    local comment
    comment="$(id -un)@$(hostname)-ventuno-q"
    log "No existing SSH key found, generating a new ed25519 key"
    ssh-keygen -t ed25519 -f "$priv_key" -N "" -C "$comment" -q
  fi
  chmod 600 "$priv_key"
  chmod 644 "$pub_key"

  # Non-interactive-friendly default for future git/ssh calls to GitHub:
  # accept the host key on first contact instead of prompting (and
  # hanging, if nothing's there to answer it). Only touches ~/.ssh/config
  # when this exact block isn't already present -- anything else in that
  # file, including a github.com entry you wrote by hand, is left alone.
  # (If you do have your own github.com block already, ssh_config takes
  # the first value it finds for each setting, so appending ours after
  # yours is safe either way: yours wins on anything it sets, ours just
  # fills in StrictHostKeyChecking if yours didn't.)
  local config_file="$ssh_dir/config"
  local marker_begin="# >>> ArduinoVentunoQ_QuickStart.sh managed block: github.com >>>"
  local marker_end="# <<< ArduinoVentunoQ_QuickStart.sh managed block: github.com <<<"

  if [[ -f "$config_file" ]] && grep -qF -e "$marker_begin" "$config_file"; then
    log "$config_file already has a github.com block, skipping"
  else
    log "Adding a github.com entry to $config_file (StrictHostKeyChecking accept-new)"
    touch "$config_file"
    chmod 600 "$config_file"
    # shellcheck disable=SC2094  # -s only checks the size, before anything is appended
    {
      [[ -s "$config_file" ]] && echo
      echo "$marker_begin"
      echo "Host github.com"
      echo "    StrictHostKeyChecking accept-new"
      echo "$marker_end"
    } >> "$config_file"
  fi

  # Some networks block outbound port 22 (the lab's Uzhgorod connection
  # does), so `ssh git@github.com` hangs until it times out. GitHub also
  # serves SSH on port 443 at ssh.github.com. If 22 gets no answer but 443
  # does, route github.com there in a second managed block, so
  # git@github.com:... remotes keep working unchanged. Port 443 works on
  # every network, so the block stays even if the board moves somewhere
  # that allows 22. A github.com -> port 443 setting you added yourself is
  # detected via `ssh -G` and left as it is.
  local p443_begin="# >>> ArduinoVentunoQ_QuickStart.sh managed block: github.com over port 443 >>>"
  local p443_end="# <<< ArduinoVentunoQ_QuickStart.sh managed block: github.com over port 443 <<<"
  local eff_host eff_port
  eff_host="$(ssh -G github.com 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')"
  eff_port="$(ssh -G github.com 2>/dev/null | awk '$1 == "port" {print $2; exit}')"
  if [[ $eff_host == "ssh.github.com" && $eff_port == "443" ]]; then
    log "github.com already goes over port 443 (ssh.github.com)"
  elif github_port_open github.com 22; then
    log "GitHub answers on port 22 here -- no port change needed"
  elif github_port_open ssh.github.com 443; then
    log "Port 22 to GitHub gets no answer on this network -- routing github.com over port 443 (ssh.github.com) in $config_file"
    {
      echo
      echo "$p443_begin"
      echo "Host github.com"
      echo "    HostName ssh.github.com"
      echo "    Port 443"
      echo "    User git"
      echo "$p443_end"
    } >> "$config_file"
  else
    warn "GitHub answers on neither port 22 nor port 443 (ssh.github.com) right now. Check this board's internet connection, then re-run: $SCRIPT_NAME --github-ssh"
  fi

  log "Public key ($(basename "$pub_key")):"
  hint "$(cat "$pub_key")"
  hint "Add it at:  https://github.com/settings/ssh/new"
  hint "Then test:  ssh -T git@github.com"
  hint "Git remotes need the SSH form for this key to be used: git@github.com:user/repo.git (not https://github.com/...)"
}

# ============================================================
# Boot root: nvme-switch / emmc-rollback / status
# ============================================================
#
# Chooses which root filesystem the VENTUNO Q boots -- see BOOT ROOT at
# the top for the design. Everything from root_boot_main() down runs as
# root, in the "--_root-boot" re-run of this file that run_boot_action()
# starts; the main, normal-user run only calls run_boot_action().

readonly EMMC_DEV="/dev/mmcblk0p71"
readonly NVME_DISK="/dev/nvme0n1"
readonly NVME_DEV="/dev/nvme0n1p1"
readonly NVME_LABEL="nvme-root"      # filesystem label --nvme-switch gives a new NVMe root
readonly ROOTDELAY=30
readonly WORK="/run/ventuno-boot"
readonly BACKUPS="/var/backups/ventuno-boot"
readonly SVC="sync-boot-emmc.service"
readonly SCRIPT_REL="usr/local/sbin/sync-boot-emmc"
readonly SYNC_VERSION_TAG="# sync-boot-emmc v2"
readonly HOOK_REL="etc/apt/apt.conf.d/99-sync-boot-emmc"
readonly UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
# Left in the NVMe root's top folder while a copy is running; a re-run that
# finds it resumes that copy.
readonly CLONE_MARKER=".ventuno-nvme-copy-in-progress"
readonly CLONE_HEADROOM=$((1024 * 1024 * 1024))   # bytes to leave free on the NVMe after the copy
readonly CLONE_MAX_LIVE_DIFFS=500                  # paths allowed to still differ after the copy

# Filled in by boot_init() and the actions, in the root re-run only.
EMMC_UUID=""
NVME_UUID=""
CURRENT_ROOT=""
NEW_CFG=""
CLONE_PLAN=""         # format | erase | mirror | resume -- see boot_clone_plan()
STOPPED_UNITS=()      # what boot_quiesce_emmc() stopped
SWITCH_APPLIED=0      # 1 once the eMMC grub.cfg points at the NVMe root

# ---------------------------------------------------------------- main-run side

# Everything a boot action does is root work -- mounting both roots,
# rewriting grub.cfg, systemctl --root -- so rather than sudo on every
# line, this file is re-run under sudo with --_root-boot, which does just
# the boot action and exits. It logs into this run's log; its exit status
# is 0, EXIT_DECLINED (answered no at the prompt), or a failure.
run_boot_action() {
  local args=("$BOOT_ACTION")
  if (( DRY_RUN )); then args+=(--dry-run); fi
  if (( ASSUME_YES )); then args+=(--yes); fi
  sudo -- "$BASH" "$SELF_PATH" --_root-boot "$RUN_LOG" "${args[@]}"
}

# ---------------------------------------------------------------- root side

# root_boot_main <run_log> <action> [--dry-run] [--yes]
root_boot_main() {
  trap 'on_error "$LINENO"' ERR
  [[ "$EUID" -eq 0 ]] || die "--_root-boot is internal: give a boot-root flag (e.g. --status) and the script runs it under sudo itself."
  (( $# >= 2 )) || die "--_root-boot needs <run_log> <action>."
  RUN_LOG="$1"
  BOOT_ACTION="$2"
  shift 2
  # Log into the main run's log, which already exists -- never create a
  # root-owned file in your log folder.
  [[ -f "$RUN_LOG" ]] || RUN_LOG=""
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=1 ;;
      --yes)     ASSUME_YES=1 ;;
      *)         die "--_root-boot: unknown option '$arg'." ;;
    esac
  done
  CURRENT_STAGE="$BOOT_ACTION"
  trap boot_cleanup EXIT

  boot_init
  case "$BOOT_ACTION" in
    status)        boot_status ;;
    emmc-rollback) boot_rollback ;;
    nvme-switch)   boot_switch ;;
    *)             die "--_root-boot: unknown action '$BOOT_ACTION'." ;;
  esac
}

boot_init() {
  [ -b "$EMMC_DEV" ] || die "$EMMC_DEV not found."
  EMMC_UUID=$(blkid -s UUID -o value "$EMMC_DEV" 2>/dev/null || true)
  [ -n "$EMMC_UUID" ] || die "Cannot read the UUID of $EMMC_DEV."
  NVME_UUID=""
  # -p probes the device itself: blkid's cache can still hold the UUID of
  # a filesystem an earlier run has since replaced.
  if [ -b "$NVME_DEV" ]; then NVME_UUID=$(blkid -p -s UUID -o value "$NVME_DEV" 2>/dev/null || true); fi
  CURRENT_ROOT=$(findmnt -n -o SOURCE /)
  mkdir -p "$WORK"
}

boot_cleanup() {
  local d
  rm -f "${NEW_CFG:-}" 2>/dev/null || true
  for d in "$WORK/src" "$WORK/nvme" "$WORK/emmc"; do
    if mountpoint -q "$d" 2>/dev/null; then umount "$d" 2>/dev/null || true; fi
    rmdir "$d" 2>/dev/null || true
  done
  rmdir "$WORK" 2>/dev/null || true
  # The switch didn't happen, so the eMMC root stays the one that boots:
  # give it back what was stopped for the copy.
  if [ "$SWITCH_APPLIED" -eq 0 ] && (( ${#STOPPED_UNITS[@]} )); then
    systemctl start "${STOPPED_UNITS[@]}" 2>/dev/null || true
    log "The switch didn't happen -- started again: ${STOPPED_UNITS[*]}"
  fi
}

# boot_root_dir VAR DEV NAME [OPTS]: sets VAR to the directory holding
# DEV's filesystem -- "" when DEV is the running root, otherwise a mount
# of it under $WORK/NAME. Returns 1, leaving VAR alone, if the mount fails.
boot_root_dir() {
  local _var="$1" _dev="$2" _opts="${4:-rw}" _dir="$WORK/$3"
  if [ "$CURRENT_ROOT" = "$_dev" ]; then printf -v "$_var" '%s' ""; return 0; fi
  mkdir -p "$_dir"
  if ! mountpoint -q "$_dir"; then
    mount -o "$_opts" "$_dev" "$_dir" || return 1
  fi
  printf -v "$_var" '%s' "$_dir"
}

# Asks on the terminal (not stdin) and fails closed: no terminal, or any
# answer but y/Y, ends the re-run with EXIT_DECLINED before anything is
# touched.
boot_confirm() {
  if [ "$ASSUME_YES" -eq 1 ]; then return 0; fi
  local ans=""
  { printf '%s [y/N] ' "$1" > /dev/tty && read -r ans < /dev/tty; } 2>/dev/null || true
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    log "Aborted; nothing changed."
    exit "$EXIT_DECLINED"
  fi
}

# For steps that destroy data: succeeds only on a typed "yes", and --yes
# does NOT skip it -- a destructive step must never be confirmed by
# default. Same rules as boot_confirm() otherwise.
boot_confirm_typed() {
  local reply=""
  { printf '\n%s\nType yes to continue: ' "$1" > /dev/tty && read -r reply < /dev/tty; } 2>/dev/null || true
  if [[ "$reply" != "yes" ]]; then
    log "Aborted; nothing changed."
    exit "$EXIT_DECLINED"
  fi
}

# ---------------------------------------------------------------- grub.cfg helpers
boot_count_linux() { grep -cE '^[[:space:]]*linux[[:space:]]' "$1" || true; }

# boot_make_cfg IN OUT ROOT_UUID [ROOTDELAY]: every kernel line boots
# ROOT_UUID, search lines use the eMMC UUID
boot_make_cfg() {
  local in="$1" out="$2" uuid="$3" delay="${4:-}"
  sed -E -e "s/root=UUID=[0-9a-fA-F-]+/root=UUID=${uuid}/g" \
         -e 's/[[:space:]]+rootdelay=[0-9]+//g' \
         -e "/^[[:space:]]*search[[:space:]]/ s/${UUID_RE}/${EMMC_UUID}/g" "$in" > "$out"
  if [ -n "$delay" ]; then
    sed -i -E "/^[[:space:]]*linux[[:space:]]/ s/[[:space:]]*\$/ rootdelay=${delay}/" "$out"
  fi
}

# boot_verify_cfg FILE ROOT_UUID WANT_DELAY(0|1)
boot_verify_cfg() {
  local f="$1" uuid="$2" want_delay="$3" nl no ns nso nd
  nl=$(boot_count_linux "$f"); [ "$nl" -gt 0 ] || return 1
  no=$(grep -E '^[[:space:]]*linux[[:space:]]' "$f" | grep -c "root=UUID=${uuid}" || true)
  [ "$no" -eq "$nl" ] || return 1
  [ "$(grep -oE 'root=UUID=[0-9a-fA-F-]+' "$f" | sort -u)" = "root=UUID=${uuid}" ] || return 1
  ns=$(grep -cE '^[[:space:]]*search[[:space:]]' "$f" || true); [ "$ns" -gt 0 ] || return 1
  nso=$(grep -E '^[[:space:]]*search[[:space:]]' "$f" | grep -c "${EMMC_UUID}" || true)
  [ "$nso" -eq "$ns" ] || return 1
  if [ "$want_delay" = 1 ]; then
    nd=$(grep -E '^[[:space:]]*linux[[:space:]]' "$f" | grep -c "rootdelay=${ROOTDELAY}" || true)
    [ "$nd" -eq "$nl" ] || return 1
  else
    ! grep -q 'rootdelay=' "$f" || return 1
  fi
  return 0
}

# boot_check_files CFG ROOT_DIR: every kernel and initrd named in CFG
# exists under ROOT_DIR
boot_check_files() {
  local f="$1" rd="$2" p missing=0
  while read -r p; do
    if [ ! -e "$rd$p" ]; then error "grub.cfg references $p but it is missing under ${rd:-/}."; missing=1; fi
  done < <(awk '/^[[:space:]]*(linux|initrd)[[:space:]]/ {print $2}' "$f" | sort -u)
  return "$missing"
}

# boot_ensure_modules CFG TARGET_ROOT SOURCE_ROOT|NONE: copy missing
# /usr/lib/modules/<ver> trees
boot_ensure_modules() {
  local f="$1" tgt="$2" src="$3" p ver
  while read -r p; do
    ver="${p##*/vmlinuz-}"
    if [ -d "$tgt/usr/lib/modules/$ver" ]; then continue; fi
    if [ "$src" != "NONE" ] && [ -d "$src/usr/lib/modules/$ver" ]; then
      log "Copying kernel modules $ver to the target root..."
      rsync -a "$src/usr/lib/modules/$ver/" "$tgt/usr/lib/modules/$ver/"
    else
      warn "No kernel modules for $ver on either root: that kernel would boot without drivers."
    fi
  done < <(awk '/^[[:space:]]*linux[[:space:]]/ {print $2}' "$f" | sort -u)
}

# boot_check_initrd_nvme CFG ROOT_DIR: the default kernel in CFG must be
# able to mount an NVMe root -- NVMe driver built in, or in its initramfs.
# Dies only on a definite no; if the initramfs can't be listed it says so
# and goes on.
boot_check_initrd_nvme() {
  local f="$1" rd="$2" kernel initrd ver listing
  kernel=$(awk '/^[[:space:]]*linux[[:space:]]/ {print $2; exit}' "$f")
  initrd=$(awk '/^[[:space:]]*initrd[[:space:]]/ {print $2; exit}' "$f")
  ver="${kernel##*/vmlinuz-}"
  if grep -qs '/nvme\.ko$' "$rd/usr/lib/modules/$ver/modules.builtin"; then
    log "Default kernel $ver has the NVMe driver built in."
    return 0
  fi
  local rc=1
  if command -v lsinitramfs >/dev/null 2>&1 && [ -n "$initrd" ]; then
    rc=0; listing=$(lsinitramfs "$rd$initrd" 2>/dev/null) || rc=$?
  fi
  # A listing that names nvme.ko is enough even if lsinitramfs then
  # complained; only a complete listing without it counts as a no.
  if grep -q '/nvme\.ko' <<< "${listing:-}"; then
    log "Default kernel $ver: the NVMe driver is in its initramfs."
    return 0
  fi
  if [ "$rc" -ne 0 ] || [ -z "${listing:-}" ]; then
    warn "Couldn't list ${initrd:-the initramfs} to check it has the NVMe driver -- going on without that check."
    return 0
  fi
  die "Default kernel $ver has no NVMe driver built in and none in $initrd, so it couldn't mount an NVMe root. Add nvme to /etc/initramfs-tools/modules, run sudo update-initramfs -u, then re-run. Nothing was changed."
}

# boot_apply_cfg NEW TARGET ROOT_DIR ROOT_UUID WANT_DELAY: backup, atomic
# swap, re-verify. A target that already matches NEW is left alone, so a
# repeated switch/rollback doesn't pile up identical backups.
boot_apply_cfg() {
  local new="$1" tgt="$2" rd="$3" uuid="$4" delay="$5" bk
  if cmp -s "$new" "$tgt"; then
    log "${tgt#"$rd"} already has exactly this content -- left as it is."
    return 0
  fi
  bk="$rd$BACKUPS/grub.cfg.$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$(dirname "$bk")"
  cp -a "$tgt" "$bk"
  cp "$new" "$tgt.new"
  chmod --reference="$tgt" "$tgt.new"
  mv -f "$tgt.new" "$tgt"
  sync
  if ! boot_verify_cfg "$tgt" "$uuid" "$delay"; then
    cp -a "$bk" "$tgt"
    die "Verification of the written $tgt failed; the previous file was restored."
  fi
  log "Backup of the previous config: ${bk#"$rd"}"
}

# ---------------------------------------------------------------- boot sync (lives on the NVMe root)
boot_sctl() { local rd="$1"; shift; if [ -z "$rd" ]; then systemctl "$@"; else systemctl --root="$rd" "$@"; fi; }

boot_write_sync_script() {
  cat > "$1" <<'SYNC_EOF'
#!/usr/bin/env bash
# sync-boot-emmc v2 -- installed by ArduinoVentunoQ_QuickStart.sh --nvme-switch
set -euo pipefail
EMMC_DEV="/dev/mmcblk0p71"
SYNC_MNT="/run/emmc_boot_sync"
# 1. Only execute if currently booted on NVMe
CURRENT_ROOT=$(findmnt -n -o SOURCE /)
if [[ "$CURRENT_ROOT" != *"nvme"* ]]; then
  echo "[sync-boot-emmc] Not running on NVMe ($CURRENT_ROOT). Skipping sync."
  exit 0
fi
# 2. Verify if eMMC root partition is present
if [ ! -b "$EMMC_DEV" ]; then
  echo "[-] ERROR: eMMC partition $EMMC_DEV not found!" >&2
  exit 1
fi
NVME_UUID=$(findmnt -n -o UUID /)
EMMC_UUID=$(blkid -s UUID -o value "$EMMC_DEV")
# 2b. A grub package upgrade on this root runs grub-install, which points the
#     ESP's stub grub.cfg at the filesystem holding /boot -- the NVMe, which
#     GRUB can't see. Point any such stub back at the eMMC root.
for stub in /boot/efi/EFI/*/grub.cfg; do
  if [ -f "$stub" ] && grep -q "$NVME_UUID" "$stub"; then
    sed -i "s/${NVME_UUID}/${EMMC_UUID}/g" "$stub"
    echo "[+] Pointed $stub back at the eMMC root."
  fi
done
GRUB_TMP=$(mktemp /run/grub.cfg.XXXXXX)
cleanup() {
  rm -f "$GRUB_TMP"
  if mountpoint -q "$SYNC_MNT"; then
    umount "$SYNC_MNT" || true
  fi
  rmdir "$SYNC_MNT" 2>/dev/null || true
}
trap cleanup EXIT ERR INT TERM
# 3. Build the eMMC copy of grub.cfg. GRUB can only read the eMMC, so the
#    'search' lines must use the eMMC UUID; root= keeps the NVMe UUID.
sed -E "/^[[:space:]]*search /s/${NVME_UUID}/${EMMC_UUID}/g" /boot/grub/grub.cfg > "$GRUB_TMP"
# 4. Refuse to sync a config that would not boot the NVMe root. Nothing is touched.
if ! grep -q "root=UUID=${NVME_UUID}" "$GRUB_TMP"; then
  echo "[-] ERROR: grub.cfg has no root=UUID=${NVME_UUID}. Run 'sudo update-grub' first." >&2
  exit 1
fi
if ! grep -Eq "^[[:space:]]*search .*${EMMC_UUID}" "$GRUB_TMP"; then
  echo "[-] ERROR: no search line with the eMMC UUID in grub.cfg. Refusing to sync." >&2
  exit 1
fi
echo "[+] Syncing /boot from NVMe to eMMC..."
mkdir -p "$SYNC_MNT"
mount "$EMMC_DEV" "$SYNC_MNT"
# Pass 1: add/update files, no deletions; grub.cfg is handled separately
rsync -ax --delay-updates --exclude=/grub/grub.cfg /boot/ "$SYNC_MNT/boot/"
# Swap in the new grub.cfg atomically, now that the kernels it names are in place
cp "$GRUB_TMP" "$SYNC_MNT/boot/grub/grub.cfg.new"
mv "$SYNC_MNT/boot/grub/grub.cfg.new" "$SYNC_MNT/boot/grub/grub.cfg"
# Pass 2: remove stale files last
rsync -ax --delete-delay --exclude=/grub/grub.cfg /boot/ "$SYNC_MNT/boot/"
sync
echo "[+] Successfully synced /boot to eMMC."
SYNC_EOF
}

boot_write_unit() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'UNIT_EOF'
[Unit]
Description=Sync /boot to eMMC before reboot/shutdown
DefaultDependencies=no
Before=reboot.target shutdown.target halt.target poweroff.target
RequiresMountsFor=/boot

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sync-boot-emmc
TimeoutSec=60

[Install]
WantedBy=reboot.target shutdown.target poweroff.target
UNIT_EOF
}

boot_write_hook() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'HOOK_EOF'
DPkg::Post-Invoke {
    "if [ -x /usr/local/sbin/sync-boot-emmc ]; then /usr/local/sbin/sync-boot-emmc; fi";
};
HOOK_EOF
}

boot_write_dropin() { # root_dir
  local f="$1/etc/default/grub.d/zz-nvme-root.cfg"
  mkdir -p "$(dirname "$f")"
  # shellcheck disable=SC2016  # ${GRUB_CMDLINE_LINUX} is meant literally: grub's own shell expands it
  printf '# Dragonwing NVMe root handoff\nGRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} root=UUID=%s rootdelay=%s"\n' "$NVME_UUID" "$ROOTDELAY" > "$f"
}

boot_install_sync() { # root_dir: install the current script if it is missing or an older version
  local p="$1/$SCRIPT_REL"
  if [ "$(boot_sync_script_state "$p")" != "current" ]; then
    if [ -f "$p" ] && [ ! -e "$p.orig" ]; then cp -a "$p" "$p.orig"; fi
    mkdir -p "$(dirname "$p")"
    boot_write_sync_script "$p"
    log "Installed the current sync script on the NVMe root."
  fi
  chmod +x "$p"
}

# boot_sync_script_state FILE: how the sync script at FILE compares.
boot_sync_script_state() {
  if [ ! -f "$1" ]; then echo "missing"
  elif grep -qF "$SYNC_VERSION_TAG" "$1"; then echo "current"
  elif grep -q 'GRUB_TMP' "$1"; then echo "older (will be replaced)"
  else echo "ORIGINAL, unpatched (will be replaced)"; fi
}

boot_sync_on() { # root_dir
  local rd="$1"
  [ -f "$rd/$SCRIPT_REL" ] || die "No sync script at $rd/$SCRIPT_REL."
  chmod +x "$rd/$SCRIPT_REL"
  if [ -f "$rd/$HOOK_REL.disabled" ]; then mv -f "$rd/$HOOK_REL.disabled" "$rd/$HOOK_REL"
  elif [ -f "$rd/root/99-sync-boot-emmc.disabled" ]; then mv -f "$rd/root/99-sync-boot-emmc.disabled" "$rd/$HOOK_REL"
  elif [ ! -f "$rd/$HOOK_REL" ]; then boot_write_hook "$rd/$HOOK_REL"; fi
  if [ ! -f "$rd/etc/systemd/system/$SVC" ]; then boot_write_unit "$rd/etc/systemd/system/$SVC"; fi
  boot_sctl "$rd" enable "$SVC" >/dev/null 2>&1 || true
  log "Boot sync enabled on the NVMe root."
}

boot_sync_off() { # root_dir
  local rd="$1"
  if [ -f "$rd/etc/systemd/system/$SVC" ]; then boot_sctl "$rd" disable "$SVC" >/dev/null 2>&1 || true; fi
  if [ -f "$rd/$HOOK_REL" ]; then mv -f "$rd/$HOOK_REL" "$rd/$HOOK_REL.disabled"; fi
  if [ -f "$rd/$SCRIPT_REL" ]; then chmod -x "$rd/$SCRIPT_REL"; fi
  log "Boot sync disabled on the NVMe root."
}

# ---------------------------------------------------------------- actions
boot_status() {
  local E N cfg summary n u label s_unit s_hook s_script
  boot_root_dir E "$EMMC_DEV" emmc ro || die "Cannot mount $EMMC_DEV."
  cfg="$E/boot/grub/grub.cfg"
  [ -f "$cfg" ] || die "$cfg not found."
  log "Boot status"
  hint "Running root : $CURRENT_ROOT"
  hint "eMMC root    : $EMMC_DEV  (UUID $EMMC_UUID)"
  if [ -n "$NVME_UUID" ]; then hint "NVMe root    : $NVME_DEV  (UUID $NVME_UUID)"
  elif [ -b "$NVME_DISK" ]; then hint "NVMe root    : none yet -- $NVME_DISK has no filesystem on partition 1 (--nvme-switch makes one)"
  else hint "NVMe root    : no NVMe drive ($NVME_DISK)"; fi
  summary=$(grep -E '^[[:space:]]*linux[[:space:]]' "$cfg" | sed -nE 's/.*root=UUID=([0-9a-fA-F-]+).*/\1/p' | sort | uniq -c || true)
  hint "Next boot    : (eMMC grub.cfg; the last root= on each kernel line wins)"
  if [ -z "$summary" ]; then
    hint "  no kernel entries found"
  else
    while read -r n u; do
      if [ "$u" = "$EMMC_UUID" ]; then label="eMMC root"
      elif [ -n "$NVME_UUID" ] && [ "$u" = "$NVME_UUID" ]; then label="NVMe root"
      else label="unknown root $u"; fi
      hint "  $n kernel entries -> $label"
    done <<< "$summary"
  fi
  if [ -n "$NVME_UUID" ]; then
    if boot_root_dir N "$NVME_DEV" nvme ro; then
      s_unit="off"; s_hook="off"; s_script="missing"
      if [ -L "$N/etc/systemd/system/shutdown.target.wants/$SVC" ]; then s_unit="on"; fi
      if [ -f "$N/$HOOK_REL" ]; then s_hook="on"; fi
      if [ -f "$N/$SCRIPT_REL" ]; then
        if [ -x "$N/$SCRIPT_REL" ]; then s_script="executable"; else s_script="NOT executable"; fi
        s_script="$s_script, $(boot_sync_script_state "$N/$SCRIPT_REL")"
      fi
      hint "Boot sync    : shutdown unit $s_unit, apt hook $s_hook, script $s_script"
    else
      hint "Boot sync    : couldn't mount $NVME_DEV to check"
    fi
  fi
}

boot_rollback() {
  local E N cfg
  boot_root_dir E "$EMMC_DEV" emmc || die "Cannot mount $EMMC_DEV."
  N="NONE"
  if [ -n "$NVME_UUID" ] && ! boot_root_dir N "$NVME_DEV" nvme; then
    N="NONE"
    warn "Cannot mount $NVME_DEV: its boot sync stays as it is (it only ever runs while the NVMe root is booted), and no kernel modules can be copied from it."
  fi
  cfg="$E/boot/grub/grub.cfg"
  [ -f "$cfg" ] || die "$cfg not found."
  NEW_CFG=$(mktemp /run/ventuno-grub.XXXXXX)
  boot_make_cfg "$cfg" "$NEW_CFG" "$EMMC_UUID" ""
  boot_verify_cfg "$NEW_CFG" "$EMMC_UUID" 0 || die "The rewritten grub.cfg failed verification. Nothing was changed."
  boot_check_files "$NEW_CFG" "$E" || exit 1
  log "grub.cfg verified: $(boot_count_linux "$NEW_CFG") kernel entries, all root=UUID=$EMMC_UUID, no rootdelay."
  if [ "$DRY_RUN" -eq 1 ]; then log "Dry run: nothing was changed."; return 0; fi
  boot_confirm "Boot the eMMC root next time and turn the NVMe boot sync off?"
  boot_ensure_modules "$NEW_CFG" "$E" "$N"
  if [ "$N" != "NONE" ]; then boot_sync_off "$N"; fi
  rm -f "$E/etc/default/grub.d/zz-nvme-root.cfg"
  boot_apply_cfg "$NEW_CFG" "$cfg" "$E" "$EMMC_UUID" 0
  log "Done: the next boot uses the eMMC root ($EMMC_DEV)."
  hint "After booting: findmnt -n -o SOURCE /   (expect $EMMC_DEV)"
  hint "Then:          sudo update-grub 2>&1 | grep -v 'improperly nested'"
}

boot_switch() {
  [ -b "$NVME_DISK" ] || die "No NVMe drive found ($NVME_DISK)."
  local E
  boot_root_dir E "$EMMC_DEV" emmc || die "Cannot mount $EMMC_DEV."
  if [ "$CURRENT_ROOT" = "$NVME_DEV" ]; then
    log "Already running from the NVMe root: it's in use, so nothing is copied onto it -- only its boot config is re-applied."
    boot_switch_config "$E" "" ask
    return 0
  fi
  boot_clone_and_switch "$E"
}

# boot_switch_config E N ask|go: points the eMMC grub.cfg at the NVMe root
# in N and sets up the boot sync on it. "ask" also stops for --dry-run and
# asks first; "go" is for boot_clone_and_switch(), which already did both.
boot_switch_config() {
  local E="$1" N="$2" mode="$3" ncfg ecfg
  if [ ! -f "$N/etc/fstab" ] || [ ! -x "$N/usr/lib/systemd/systemd" ]; then
    die "$NVME_DEV does not look like a root filesystem."
  fi
  ncfg="$N/boot/grub/grub.cfg"; ecfg="$E/boot/grub/grub.cfg"
  [ -f "$ncfg" ] || die "$ncfg not found on the NVMe root."
  [ -f "$ecfg" ] || die "$ecfg not found on the eMMC root."
  rm -f "${NEW_CFG:-}"
  NEW_CFG=$(mktemp /run/ventuno-grub.XXXXXX)
  boot_make_cfg "$ncfg" "$NEW_CFG" "$NVME_UUID" "$ROOTDELAY"
  boot_verify_cfg "$NEW_CFG" "$NVME_UUID" 1 || die "The rewritten grub.cfg failed verification -- the next boot still uses the eMMC root."
  boot_check_files "$NEW_CFG" "$N" || exit 1
  log "grub.cfg verified: $(boot_count_linux "$NEW_CFG") kernel entries, all root=UUID=$NVME_UUID rootdelay=$ROOTDELAY, search lines on the eMMC."
  log "Sync script on the NVMe root: $(boot_sync_script_state "$N/$SCRIPT_REL")"
  if [ "$mode" = ask ]; then
    if [ "$DRY_RUN" -eq 1 ]; then log "Dry run: nothing was changed."; return 0; fi
    boot_confirm "Re-apply the NVMe boot config (the NVMe /boot is mirrored to the eMMC)?"
  fi
  boot_install_sync "$N"
  boot_write_dropin "$N"
  boot_sync_on "$N"
  # Same order as the sync: copy new files, swap the config, delete stale files last.
  rsync -ax --delay-updates --exclude=/grub/grub.cfg "$N/boot/" "$E/boot/"
  boot_apply_cfg "$NEW_CFG" "$ecfg" "$E" "$NVME_UUID" 1
  SWITCH_APPLIED=1
  rsync -ax --delete-delay --exclude=/grub/grub.cfg "$N/boot/" "$E/boot/"
  sync
  boot_check_files "$ecfg" "$E" || die "The eMMC /boot is missing files that grub.cfg references."
  # Keep the NVMe-side config consistent so the shutdown sync accepts it.
  if ! cmp -s "$NEW_CFG" "$ncfg"; then
    mkdir -p "$N$BACKUPS"
    cp -a "$ncfg" "$N$BACKUPS/grub.cfg.nvme.$(date +%Y%m%d-%H%M%S)"
    cp "$NEW_CFG" "$ncfg.new"; chmod --reference="$ncfg" "$ncfg.new"; mv -f "$ncfg.new" "$ncfg"
  fi
  log "Done: the next boot uses the NVMe root ($NVME_DEV)."
  hint "After booting: findmnt -n -o SOURCE /   (expect $NVME_DEV)"
  hint "Then:          $SELF_PATH --status"
}

# ---------------------------------------------------------------- copying the eMMC root to the NVMe

boot_nvme_layout() {
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$NVME_DISK" 2>/dev/null || true
}

# Dies if anything on the NVMe drive is in use: mounted, active swap, or
# under LVM/RAID/crypt. A leftover mount of our own from a killed run is
# simply undone.
boot_nvme_check_unused() {
  local busy dev name
  if mountpoint -q "$WORK/nvme"; then umount "$WORK/nvme"; fi
  busy="$(lsblk -nro MOUNTPOINTS "$NVME_DISK" 2>/dev/null | grep -v '^$' || true)"
  for dev in "$NVME_DISK" "$NVME_DISK"p*; do
    [ -b "$dev" ] || continue
    if [ -n "$(findmnt -rn -S "$dev" 2>/dev/null || true)" ]; then busy="mounted"; fi
    name="$(basename "$(readlink -f "$dev")")"
    if [ -n "$(ls -A "/sys/class/block/$name/holders" 2>/dev/null || true)" ]; then busy="held by another device"; fi
  done
  if [ -n "$busy" ]; then
    error "$NVME_DISK is in use:"
    boot_nvme_layout >&2
    die "Unmount it (or swapoff / deactivate whatever uses it), then re-run. Nothing was changed."
  fi
}

# boot_clone_plan NV: decides how the NVMe gets its copy, changing nothing.
# NV is a read-only mount of nvme0n1p1 when that holds a usable ext4, else "".
#   format -- the drive is blank: give it one GPT partition, format it
#   resume -- an earlier run's copy was interrupted: carry on with it
#   mirror -- partition 1 holds a root filesystem (an earlier switch's):
#             copy over it in place, keeping its filesystem and UUID
#   erase  -- anything else: wipe the whole drive, then as for format
# Sets CLONE_PLAN, and NVME_UUID to the UUID the NVMe root is going to have.
boot_clone_plan() {
  local nv="$1" sigs kids
  sigs="$(wipefs --no-act --noheadings "$NVME_DISK" 2>/dev/null || true)"
  kids="$(lsblk -nro NAME "$NVME_DISK" 2>/dev/null | sed 1d || true)"
  if [ -z "$sigs" ] && [ -z "$kids" ] && [ ! -b "$NVME_DEV" ]; then
    CLONE_PLAN=format
  elif [ -n "$nv" ] && [ -e "$nv/$CLONE_MARKER" ]; then
    CLONE_PLAN=resume
  elif [ -n "$nv" ] && [ -f "$nv/etc/fstab" ] && [ -x "$nv/usr/lib/systemd/systemd" ]; then
    CLONE_PLAN=mirror
  else
    CLONE_PLAN=erase
  fi
  if [ "$CLONE_PLAN" = format ] || [ "$CLONE_PLAN" = erase ]; then
    NVME_UUID="$(cat /proc/sys/kernel/random/uuid)"
  fi
}

# Lists the other eMMC partitions the running eMMC root has mounted (the ESP
# at /boot/efi, say). They aren't copied: the NVMe root's fstab -- a copy of
# this one -- keeps mounting them from the eMMC.
boot_list_shared_mounts() {
  local shared line
  shared="$(findmnt -rn -o TARGET,SOURCE | awk -v d="${EMMC_DEV%p*}p" -v w="$WORK" \
    'index($2, d) == 1 && $1 != "/" && index($1, w) != 1 {print $1 "  (" $2 ")"}')"
  [ -n "$shared" ] || return 0
  log "Not copied -- the NVMe root keeps mounting these from the eMMC, as this root does:"
  while IFS= read -r line; do hint "$line"; done <<< "$shared"
}

# The copy is of the running eMMC root, so nothing should write to it from
# here until the reboot: stops Docker and the automatic apt runs (started
# again if the switch doesn't happen after all), and waits out a running apt.
boot_quiesce_emmc() {
  local u
  for u in docker.socket docker.service apt-daily.timer apt-daily-upgrade.timer; do
    if systemctl is-active --quiet "$u" 2>/dev/null; then
      systemctl stop "$u"
      STOPPED_UNITS+=("$u")
    fi
  done
  if (( ${#STOPPED_UNITS[@]} )); then log "Stopped for the copy: ${STOPPED_UNITS[*]}"; fi
  wait_for_package_locks
}

# One GPT partition across the whole NVMe drive, formatted ext4 with the
# UUID boot_clone_plan() picked, so grub.cfg could be checked against it
# before anything was touched.
boot_make_nvme_fs() {
  local tries=40
  log "Wiping $NVME_DISK and giving it one GPT partition"
  wipefs -a -q "$NVME_DISK"
  printf 'label: gpt\nname=%s, type=L\n' "$NVME_LABEL" | sfdisk -q --wipe always --wipe-partitions always "$NVME_DISK"
  if command -v udevadm >/dev/null 2>&1; then udevadm settle --timeout=20 || true; fi
  # Up to 20 s for the kernel and udev to show the new partition.
  while (( tries-- > 0 )); do
    if [ -b "$NVME_DEV" ] && blockdev --getsize64 "$NVME_DEV" >/dev/null 2>&1; then break; fi
    sleep 0.5
  done
  [ -b "$NVME_DEV" ] || die "$NVME_DEV didn't show up after partitioning $NVME_DISK."
  log "Formatting $NVME_DEV as ext4 (UUID $NVME_UUID, label $NVME_LABEL)"
  mkfs.ext4 -F -q -U "$NVME_UUID" -L "$NVME_LABEL" "$NVME_DEV"
}

# boot_fstab_set_root FILE UUID: the "/" entry of FILE mounts UUID=<UUID>;
# every other line stays exactly as it is.
boot_fstab_set_root() {
  local f="$1" uuid="$2" before tmp
  if [ ! -f "$f" ]; then warn "No $f on the NVMe root to point at it."; return 0; fi
  before="$(awk '!/^[[:space:]]*#/ && $2 == "/" {print $1; exit}' "$f")"
  if [ -z "$before" ]; then
    log "The copied fstab has no / entry (the kernel's root= decides) -- left as it is."
    return 0
  fi
  tmp="$(mktemp)"
  awk -v dev="UUID=$uuid" '!done && !/^[[:space:]]*#/ && $2 == "/" { sub(/[^[:space:]]+/, dev); done = 1 } { print }' "$f" > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
  log "NVMe root's /etc/fstab: / now mounts UUID=$uuid (was $before)"
}

# boot_copy_root E DST: makes DST, the mounted NVMe root, an exact copy of
# the eMMC root filesystem, then points the copy's fstab at the NVMe.
# Resumable: CLONE_MARKER stays in DST until the copy is complete.
boot_copy_root() {
  local E="$1" dst="$2" src pass rc diffs ndiffs t0=$SECONDS
  local opts=(-aHAXx --numeric-ids --delete --exclude=/lost+found --exclude="/$CLONE_MARKER")
  : > "$dst/$CLONE_MARKER"
  if [ -z "$E" ]; then
    # The running root goes through a read-only bind mount: that shows the
    # root filesystem alone, without what's mounted over it (/proc, /run,
    # /boot/efi, ...), and nothing can write to the eMMC through it.
    src="$WORK/src"
    mkdir -p "$src"
    mountpoint -q "$src" || mount --bind / "$src"
    mount -o remount,bind,ro "$src"
  else
    src="$E"
  fi
  for pass in 1 2; do
    log "Copying the eMMC root to the NVMe, pass $pass of 2$([ "$pass" = 2 ] && echo ' (what changed during pass 1)')"
    rc=0
    if [ "$pass" = 1 ]; then
      rsync "${opts[@]}" --info=progress2 "$src/" "$dst/" || rc=$?
    else
      rsync "${opts[@]}" "$src/" "$dst/" || rc=$?
    fi
    # 24 = some files vanished during the copy: normal on a running system.
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 24 ]; then
      die "rsync failed (exit $rc). The next boot still uses the eMMC root; re-run --nvme-switch to resume the copy."
    fi
  done
  diffs=$(rsync "${opts[@]}" -n --itemize-changes "$src/" "$dst/" || true)
  ndiffs=$(grep -c . <<< "$diffs" || true)
  if [ "$ndiffs" -gt "$CLONE_MAX_LIVE_DIFFS" ]; then
    log "First of the paths that still differ:"
    printf '%s\n' "$diffs" | head -n 40 | sed 's/^/    /'
    die "$ndiffs paths still differ after two passes -- something keeps writing to the eMMC root. Stop it and re-run --nvme-switch (the copy resumes); the next boot still uses the eMMC root."
  elif [ "$ndiffs" -gt 0 ]; then
    log "$ndiffs path(s) changed during the copy (live system files -- expected)"
  else
    log "Copy verified: no differences"
  fi
  boot_fstab_set_root "$dst/etc/fstab" "$NVME_UUID"
  rm -f "$dst/$CLONE_MARKER"
  sync
  log "Copy finished in $((SECONDS - t0))s: $(df -h --output=used "$dst" | tail -n1 | xargs) used on the NVMe root"
}

# boot_clone_and_switch E: --nvme-switch from the eMMC root, start to end.
# Everything up to the confirmation only reads, so --dry-run stops there.
boot_clone_and_switch() {
  local E="$1" NV="" model used cap cfg line after
  boot_nvme_check_unused
  if [ -n "$NVME_UUID" ] && [ "$NVME_UUID" = "$EMMC_UUID" ]; then
    warn "$NVME_DEV has the same filesystem UUID as the eMMC root (a block-level copy?), so the two can't be told apart at boot -- it gets reformatted."
  elif [ -n "$NVME_UUID" ] && [ "$(blkid -p -s TYPE -o value "$NVME_DEV" 2>/dev/null || true)" = "ext4" ]; then
    boot_root_dir NV "$NVME_DEV" nvme ro || NV=""
  fi
  boot_clone_plan "$NV"

  model="$(lsblk -dno MODEL,SIZE "$NVME_DISK" 2>/dev/null | xargs || true)"
  log "NVMe drive $NVME_DISK${model:+ ($model)} now:"
  while IFS= read -r line; do hint "$line"; done < <(boot_nvme_layout)
  case "$CLONE_PLAN" in
    format) log "Plan: the drive is blank -- give it one GPT partition, format it ext4, copy this eMMC root onto it, boot it" ;;
    erase)  log "Plan: the drive holds something other than an NVMe root -- wipe it, give it one GPT partition, format it ext4, copy this eMMC root onto it, boot it" ;;
    mirror) log "Plan: $NVME_DEV holds an NVMe root from an earlier switch -- replace its contents with a copy of this eMMC root (same filesystem, same UUID), boot it" ;;
    resume) log "Plan: $NVME_DEV holds an interrupted copy from an earlier run -- finish it, boot it" ;;
  esac
  if [ -z "$E" ]; then boot_list_shared_mounts; fi

  used=$(df -B1 --output=used "${E:-/}" | tail -n1 | tr -d ' ')
  if [ -n "$NV" ] && { [ "$CLONE_PLAN" = mirror ] || [ "$CLONE_PLAN" = resume ]; }; then
    cap=$(df -B1 --output=size "$NV" | tail -n1 | tr -d ' ')
  else
    cap=$(( $(blockdev --getsize64 "$NVME_DISK") * 95 / 100 ))
  fi
  if (( used + CLONE_HEADROOM > cap )); then
    die "Not enough room: the eMMC root holds $(numfmt --to=iec "$used"), the NVMe takes about $(numfmt --to=iec "$cap") and $(numfmt --to=iec "$CLONE_HEADROOM") should stay free. Nothing was changed."
  fi
  log "Space check OK: $(numfmt --to=iec "$used") to copy, room for about $(numfmt --to=iec "$cap") on the NVMe"

  # The NVMe /boot is about to be a copy of the eMMC /boot, so the grub.cfg
  # the NVMe root will boot from can be built and checked right now.
  cfg="$E/boot/grub/grub.cfg"
  [ -f "$cfg" ] || die "$cfg not found."
  NEW_CFG=$(mktemp /run/ventuno-grub.XXXXXX)
  boot_make_cfg "$cfg" "$NEW_CFG" "$NVME_UUID" "$ROOTDELAY"
  boot_verify_cfg "$NEW_CFG" "$NVME_UUID" 1 || die "The grub.cfg for the NVMe root failed verification. Nothing was changed."
  boot_check_files "$NEW_CFG" "$E" || exit 1
  boot_check_initrd_nvme "$NEW_CFG" "$E"
  log "grub.cfg checked: $(boot_count_linux "$NEW_CFG") kernel entries will boot root=UUID=$NVME_UUID rootdelay=$ROOTDELAY, search lines stay on the eMMC."
  if [ "$DRY_RUN" -eq 1 ]; then log "Dry run: nothing was changed."; return 0; fi

  after="Afterwards, change nothing on this eMMC root -- reboot straight into the NVMe root."
  case "$CLONE_PLAN" in
    format) boot_confirm "Partition and format the blank NVMe, copy this eMMC root onto it and boot it from the next boot on? $after" ;;
    resume) boot_confirm "Finish the interrupted copy onto $NVME_DEV and boot it from the next boot on? $after" ;;
    mirror) boot_confirm_typed "About to REPLACE everything on $NVME_DEV -- the NVMe root from an earlier switch, $(df -h --output=used "$NV" | tail -n1 | xargs) used -- with a copy of this eMMC root. Files that exist only on the NVMe are deleted. $after" ;;
    erase)  boot_confirm_typed "About to ERASE the whole NVMe drive $NVME_DISK${model:+ ($model)} -- everything listed above is lost -- then partition and format it and copy this eMMC root onto it. $after" ;;
  esac

  if [ -z "$E" ]; then boot_quiesce_emmc; fi
  case "$CLONE_PLAN" in
    format|erase)
      if mountpoint -q "$WORK/nvme"; then umount "$WORK/nvme"; fi
      boot_make_nvme_fs
      boot_root_dir NV "$NVME_DEV" nvme || die "Cannot mount the new $NVME_DEV."
      ;;
    mirror|resume)
      mount -o remount,rw "$WORK/nvme"
      ;;
  esac
  boot_copy_root "$E" "$NV"
  boot_switch_config "$E" "$NV" go

  if [ -z "$E" ]; then
    warn "Until you reboot, do NOT install, update or change anything on this eMMC root: none of it would be on the NVMe root, and an update-grub here would point the next boot back at the eMMC."
    if (( ${#STOPPED_UNITS[@]} )); then warn "Left stopped until the reboot for the same reason: ${STOPPED_UNITS[*]}"; fi
    hint "Reboot now:  sudo reboot"
  fi
}

# ============================================================
# Stage registry -- add new setup stages here
# ============================================================

# Setup stages, in the order they run.
SETUP_STAGE_IDS=(code-dir zsh tools sudo github-ssh)

# Boot-root actions: at most one per run, always after the setup stages.
BOOT_ACTION_IDS=(nvme-switch emmc-rollback status)

# Modifiers, in the order --help and the no-flags list show them.
MODIFIER_FLAGS=(--dry-run --yes --reboot)

declare -A STAGE_DESCRIPTIONS=(
  [code-dir]="Create ~/Code, owned by you, for git clones"
  [zsh]="zsh + plugins as your login shell, deploy .zshrc"
  [tools]="Full upgrade + fastfetch, sysbench, btop, flashrom, speedtest"
  [sudo]="Passwordless sudo for you (validated sudoers.d drop-in)"
  [github-ssh]="Make/reuse an ed25519 key for GitHub, print setup steps"
  [nvme-switch]="Copy this eMMC root to the NVMe and boot it (run last)"
  [emmc-rollback]="Boot the eMMC root next (turns the NVMe boot sync off)"
  [status]="Show where the next boot goes and the boot-sync state"
)

declare -A STAGE_FUNCS=(
  [code-dir]=stage_code_dir
  [zsh]=stage_zsh
  [tools]=stage_tools
  [sudo]=stage_sudo
  [github-ssh]=stage_github_ssh
)

declare -A MODIFIER_LABELS=(
  [--dry-run]="-n, --dry-run"
  [--yes]="-y, --yes"
  [--reboot]="--reboot"
)

declare -A MODIFIER_DESCRIPTIONS=(
  [--dry-run]="With a switch/rollback: verify only, change nothing"
  [--yes]="With a switch/rollback: skip y/N (never a typed yes)"
  [--reboot]="Reboot when everything is done (never after a dry run)"
)

# What each number in the no-flags list stands for -- the same order
# print_flag_table() prints them in.
MENU_FLAGS=("${SETUP_STAGE_IDS[@]/#/--}" "${BOOT_ACTION_IDS[@]/#/--}" "${MODIFIER_FLAGS[@]}")

# ============================================================
# CLI
# ============================================================

# flag_row <number or ""> <label> <description>
flag_row() {
  if [[ -n "$1" ]]; then
    printf '  %3s  %-16s %s\n' "$1)" "$2" "$3"
  else
    printf '  %-17s %s\n' "$2" "$3"
  fi
}

# print_flag_table [numbered]
# The flag list behind both --help and the no-flags list, built from the
# registry above, so a new stage shows up in both.
print_flag_table() {
  local numbered="${1:-}" n=0 id flag
  echo "Setup stages (any combination; always run in this order):"
  for id in "${SETUP_STAGE_IDS[@]}"; do
    n=$((n + 1))
    flag_row "${numbered:+$n}" "--$id" "${STAGE_DESCRIPTIONS[$id]}"
  done
  echo
  echo "Boot root (at most one; always runs after the setup stages):"
  for id in "${BOOT_ACTION_IDS[@]}"; do
    n=$((n + 1))
    flag_row "${numbered:+$n}" "--$id" "${STAGE_DESCRIPTIONS[$id]}"
  done
  echo
  echo "Modifiers:"
  for flag in "${MODIFIER_FLAGS[@]}"; do
    n=$((n + 1))
    flag_row "${numbered:+$n}" "${MODIFIER_LABELS[$flag]}" "${MODIFIER_DESCRIPTIONS[$flag]}"
  done
}

usage() {
  cat <<USAGE
Usage: ./$SCRIPT_NAME FLAG [FLAG...]
       ./$SCRIPT_NAME            (no flags: lists them and asks which to use)

Post-flash setup for the Arduino VENTUNO Q lab image, plus switching the
board between its eMMC root and an NVMe root. There is no default run:
only the flags you give run. Run as your normal user (not root/sudo) --
the script calls sudo itself where needed. Every stage checks its own
work first and skips anything already applied, so re-running is safe.

USAGE
  print_flag_table
  flag_row "" "-h, --help" "Show this help and exit"
  cat <<USAGE

Flags also work without the leading -- (nvme-switch = --nvme-switch).
--dry-run can't be combined with setup stages: they have no dry-run mode.

--nvme-switch copies this eMMC root onto the NVMe and makes the next boot
use it. Run it last and reboot right after: nothing changed on the eMMC
root afterwards reaches the NVMe. A blank NVMe gets a y/N; overwriting
anything already on it needs a typed yes, which -y doesn't skip.

Examples:
  ./$SCRIPT_NAME --code-dir --zsh --tools --sudo --github-ssh --nvme-switch --reboot
                          Fresh flash: set everything up, move it all to the NVMe, boot it
  ./$SCRIPT_NAME --status                  Where does the next boot go?
  ./$SCRIPT_NAME --nvme-switch --dry-run   Verify the NVMe switch, change nothing
  ./$SCRIPT_NAME --nvme-switch --reboot    Switch to the NVMe root, reboot into it
  ./$SCRIPT_NAME --emmc-rollback -y --reboot
USAGE
}

# parse_flags FLAG...
#
# Settles what this run does: SELECTED_STAGES (in run order), BOOT_ACTION,
# DRY_RUN, ASSUME_YES, DO_REBOOT, and CANONICAL_FLAGS (the same choice
# spelled as a command line). Returns 1 with PARSE_ERROR set rather than
# dying, so the no-flags list can simply ask again.
parse_flags() {
  SELECTED_STAGES=(); BOOT_ACTION=""; DRY_RUN=0; ASSUME_YES=0; DO_REBOOT=0
  CANONICAL_FLAGS=(); PARSE_ERROR=""
  local arg id picked=()
  for arg in "$@"; do
    case "$arg" in
      -n|--dry-run|dry-run) DRY_RUN=1;    continue ;;
      -y|--yes|yes)         ASSUME_YES=1; continue ;;
      --reboot|reboot)      DO_REBOOT=1;  continue ;;
    esac
    id="${arg#--}"
    if contains "$id" "${SETUP_STAGE_IDS[@]}"; then
      contains "$id" "${picked[@]}" || picked+=("$id")
    elif contains "$id" "${BOOT_ACTION_IDS[@]}"; then
      if [[ -n "$BOOT_ACTION" && "$BOOT_ACTION" != "$id" ]]; then
        PARSE_ERROR="Pick only one of --nvme-switch, --emmc-rollback and --status."
        return 1
      fi
      BOOT_ACTION="$id"
    else
      PARSE_ERROR="Unknown flag: '$arg'."
      return 1
    fi
  done

  for id in "${SETUP_STAGE_IDS[@]}"; do
    if contains "$id" "${picked[@]}"; then SELECTED_STAGES+=("$id"); fi
  done

  if (( ${#SELECTED_STAGES[@]} == 0 )) && [[ -z "$BOOT_ACTION" ]]; then
    PARSE_ERROR="Nothing to run: pick at least one setup stage or boot-root action (-n, -y and --reboot only modify a run)."
    return 1
  fi
  if (( DRY_RUN )) && (( ${#SELECTED_STAGES[@]} )); then
    PARSE_ERROR="--dry-run only verifies --nvme-switch / --emmc-rollback. The setup stages have no dry-run mode and would change the board for real -- run them without --dry-run."
    return 1
  fi

  CANONICAL_FLAGS=("${SELECTED_STAGES[@]/#/--}")
  [[ -z "$BOOT_ACTION" ]] || CANONICAL_FLAGS+=("--$BOOT_ACTION")
  (( DRY_RUN == 0 ))      || CANONICAL_FLAGS+=(--dry-run)
  (( ASSUME_YES == 0 ))   || CANONICAL_FLAGS+=(--yes)
  (( DO_REBOOT == 0 ))    || CANONICAL_FLAGS+=(--reboot)
  return 0
}

# No flags given: list them all, numbered, and ask which to use until the
# answer is a valid run. There is deliberately no default -- an empty
# answer just asks again. Reads the terminal itself (not stdin), and with
# no terminal to ask on, prints the flags and exits without doing anything.
pick_flags_interactively() {
  if ! { : < /dev/tty; } 2>/dev/null; then
    usage >&2
    die "No flags given and no terminal to ask on -- pass the flags on the command line (listed above). There is no default run."
  fi

  local reply tok n bad
  local tokens=() args=()
  {
    echo
    echo "No flags given -- pick what to run. There is no default: only what you pick runs."
    echo
    print_flag_table numbered
  } > /dev/tty

  while :; do
    printf '\n' > /dev/tty
    if ! read -e -r -p 'Flags or their numbers, separated by spaces ("?" lists them again, q quits): ' reply < /dev/tty 2> /dev/tty; then
      printf '\n' > /dev/tty
      die "No answer (end of input) -- nothing was run."
    fi
    read -r -a tokens <<< "${reply//,/ }"

    if (( ${#tokens[@]} == 0 )); then
      echo "Nothing picked, and there is no default -- pick at least one, or q to quit." > /dev/tty
      continue
    fi
    if (( ${#tokens[@]} == 1 )); then
      case "${tokens[0]}" in
        q|Q|quit|exit)
          echo "Nothing was run."
          exit 0
          ;;
        '?'|h|help|-h|--help)
          print_flag_table numbered > /dev/tty
          continue
          ;;
      esac
    fi

    args=()
    bad=""
    for tok in "${tokens[@]}"; do
      if [[ "$tok" =~ ^[0-9]+$ ]]; then
        n=$((10#$tok))
        if (( n < 1 || n > ${#MENU_FLAGS[@]} )); then
          bad="$tok"
          break
        fi
        args+=("${MENU_FLAGS[n - 1]}")
      else
        args+=("$tok")
      fi
    done
    if [[ -n "$bad" ]]; then
      echo "There's no number $bad in the list (1-${#MENU_FLAGS[@]})." > /dev/tty
      continue
    fi

    if parse_flags "${args[@]}"; then
      return 0
    fi
    echo "$PARSE_ERROR" > /dev/tty
  done
}

# ============================================================
# Main
# ============================================================

main() {
  # The root re-run started by run_boot_action() -- see the boot section.
  if [[ "${1:-}" == "--_root-boot" ]]; then
    shift
    root_boot_main "$@"
    return
  fi

  trap 'on_error "$LINENO"' ERR
  trap stop_sudo_keepalive EXIT

  local arg interactive=0
  for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
      usage
      exit 0
    fi
  done

  # Checked before any question is asked, so a `sudo ./script` run stops
  # here rather than after you've picked flags.
  if [[ "$EUID" -eq 0 ]]; then
    die "Run this as your normal user, not root/sudo -- it calls sudo itself where needed, and the code-dir, zsh and github-ssh stages set up your own account."
  fi

  if (( $# == 0 )); then
    interactive=1
    pick_flags_interactively
  elif ! parse_flags "$@"; then
    die "$PARSE_ERROR  (see --help)"
  fi

  init_run_log
  log "Running: $SCRIPT_NAME ${CANONICAL_FLAGS[*]}"
  if (( interactive )); then
    hint "Next time, skip the list: ./$SCRIPT_NAME ${CANONICAL_FLAGS[*]}"
  fi

  preflight_checks

  # --nvme-switch is meant to be the last thing done on the eMMC root before
  # rebooting into its NVMe copy. Setup stages run now would change only the
  # eMMC root -- which no longer boots -- so they wait for the reboot.
  if (( ${#SELECTED_STAGES[@]} )) && nvme_switch_pending; then
    die "The next boot already goes to the NVMe root: --nvme-switch copied this eMMC root there, and the board hasn't rebooted since. Anything set up here now would never reach the NVMe root -- reboot first, then run the setup stages there. (--emmc-rollback cancels the switch instead.)"
  fi

  local script_start=$SECONDS
  local stage_id fn t0
  for stage_id in "${SELECTED_STAGES[@]}"; do
    fn="${STAGE_FUNCS[$stage_id]}"
    CURRENT_STAGE="$stage_id"
    log "Starting stage '$stage_id' -- ${STAGE_DESCRIPTIONS[$stage_id]}"
    t0=$SECONDS
    "$fn"
    log "Finished stage '$stage_id' in $((SECONDS - t0))s"
  done

  if [[ -n "$BOOT_ACTION" ]]; then
    local rc=0 note=""
    if (( DRY_RUN )) && [[ "$BOOT_ACTION" != "status" ]]; then note=" (dry run)"; fi
    CURRENT_STAGE="$BOOT_ACTION"
    log "Starting stage '$BOOT_ACTION'$note -- ${STAGE_DESCRIPTIONS[$BOOT_ACTION]}"
    t0=$SECONDS
    run_boot_action || rc=$?
    CURRENT_STAGE=""
    if (( rc == EXIT_DECLINED )); then
      warn "'$BOOT_ACTION' was not confirmed, so it changed nothing. Not rebooting."
      exit 1
    elif (( rc != 0 )); then
      die "Stage '$BOOT_ACTION' failed (exit $rc) -- see the messages above. Not rebooting."
    fi
    log "Finished stage '$BOOT_ACTION' in $((SECONDS - t0))s"
  fi
  CURRENT_STAGE=""

  log "All requested stages completed in $((SECONDS - script_start))s"
  log "Full log: $RUN_LOG"

  if [[ "$BOOT_ACTION" == "nvme-switch" ]] && (( ! DRY_RUN && ! DO_REBOOT )) \
     && [[ "$(findmnt -n -o SOURCE / 2>/dev/null || true)" == "$EMMC_DEV" ]]; then
    warn "Reboot now: sudo reboot -- and change nothing on this eMMC root before you do."
  fi

  if (( DO_REBOOT )); then
    if (( DRY_RUN )); then
      log "Dry run: not rebooting (--reboot ignored)."
    else
      log "Rebooting..."
      sudo systemctl reboot
      return 0
    fi
  fi

  if [[ -f /var/run/reboot-required ]]; then
    warn "A reboot is required to finish applying updates (/var/run/reboot-required present)."
  fi
}

# Only auto-run when executed directly -- lets this file be `source`d
# (e.g. `source ArduinoVentunoQ_QuickStart.sh` then call a single stage_*
# function by hand) without triggering a run.
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi
