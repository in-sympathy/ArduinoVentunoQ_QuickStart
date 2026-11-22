# ArduinoVentunoQ_QuickStart

Post-flash provisioning script for Arduino VENTUNO Q boards. Run it after
flashing (or reflashing) a board and it brings the board up to the
standard lab setup — shell configured, tools installed, sudo
passwordless, a GitHub key ready, and a `~/Code` folder of your own — and
then, as its last step, moves the whole system onto an NVMe SSD and boots
from it, with a way back to the eMMC whenever you need one.

There's no default run: nothing happens unless you name it. Run the
script without flags and it lists every flag, numbered, and asks which
ones to use. Every stage checks its own work first and skips anything
already applied, so re-running any of it is always safe.

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Flags](#flags)
- [Examples](#examples)
- [Moving to the NVMe](#moving-to-the-nvme)
- [Keeping the NVMe root bootable](#keeping-the-nvme-root-bootable)
- [Going back to the eMMC](#going-back-to-the-emmc)
- [Checking where the next boot goes](#checking-where-the-next-boot-goes)
- [Why some of this exists](#why-some-of-this-exists)
- [Extending it](#extending-it)
- [Known things worth knowing](#known-things-worth-knowing)
- [License](#license)

## Requirements

- **Run as your normal user — not root, not via `sudo`.** The script
  calls `sudo` itself wherever it needs privilege. The boot-root flags
  (`--nvme-switch`, `--emmc-rollback`, `--status`) are root work from
  start to finish, so for those it re-runs its own file under `sudo`.
- **Run it from a file** (the git clone), not piped into `bash`: that
  `sudo` re-run needs the script's path.
- **A terminal** for the no-flags list and for confirmations. Both read
  the terminal itself, not stdin; with no terminal the list isn't shown,
  and nothing that needs confirming is ever confirmed. It works the same
  over SSH as from a desktop terminal.
- The VENTUNO Q's stock **Ubuntu** image (24.04); Debian works too. The
  boot-root flags expect the stock layout: the eMMC root on
  `/dev/mmcblk0p71`, GRUB loading from the eMMC with `/boot` on that root
  filesystem, and — for `--nvme-switch` — an NVMe SSD in the M.2 slot at
  `/dev/nvme0n1`. The device paths are constants at the top of the
  script's boot section if yours differ.
- `--nvme-switch` needs room on the NVMe for everything used on the eMMC
  root, plus 1 GiB. It installs `rsync` and `fdisk` (for `sfdisk`) first
  if the image lacks them.

## Quick start

```bash
mkdir -p ~/Code && cd ~/Code
git clone https://github.com/in-sympathy/ArduinoVentunoQ_QuickStart.git
cd ArduinoVentunoQ_QuickStart
chmod +x ArduinoVentunoQ_QuickStart.sh
./ArduinoVentunoQ_QuickStart.sh
```

Clone over HTTPS on a fresh board: it has no GitHub SSH key yet (the
`--github-ssh` stage sets that up), and some networks block SSH's port 22.

Without flags you get this list:

```
No flags given -- pick what to run. There is no default: only what you pick runs.

Setup stages (any combination; always run in this order):
   1)  --code-dir       Create ~/Code, owned by you, for git clones
   2)  --zsh            zsh + plugins as your login shell, deploy .zshrc
   3)  --tools          Full upgrade + fastfetch, sysbench, btop, flashrom, speedtest
   4)  --sudo           Passwordless sudo for you (validated sudoers.d drop-in)
   5)  --github-ssh     ed25519 key for GitHub, SSH via port 443, setup steps

Boot root (at most one; always runs after the setup stages):
   6)  --nvme-switch    Copy this eMMC root to the NVMe and boot it (run last)
   7)  --emmc-rollback  Boot the eMMC root next (turns the NVMe boot sync off)
   8)  --status         Show where the next boot goes and the boot-sync state

Modifiers:
   9)  -n, --dry-run    With a switch/rollback: verify only, change nothing
  10)  -y, --yes        With a switch/rollback: skip y/N (never a typed yes)
  11)  --reboot         Reboot when everything is done (never after a dry run)

Flags or their numbers, separated by spaces ("?" lists them again, q quits):
```

Answer with numbers, flag names or both, separated by spaces or commas —
`1 2 3 4 5 6 11`, `--zsh --tools`, `zsh tools`. An empty answer just asks
again (there's no default), anything invalid says why and asks again, and
`q` quits without running anything. Once you've picked, the script prints
the same choice as a command line, so next time you can skip the list.

A freshly flashed board, all in one go — everything set up on the eMMC,
then the whole system copied to the NVMe and booted from there:

```bash
./ArduinoVentunoQ_QuickStart.sh --code-dir --zsh --tools --sudo --github-ssh --nvme-switch --reboot
```

## Flags

### Setup stages

Any combination. They always run in this order, whatever order the flags
come in.

| Flag | What it does |
|------|--------------|
| `--code-dir` | Creates `~/Code`, owned by you, not root: the working folder for git clones and board files. If it already exists but belongs to someone else — say a `sudo` command created it — only the folder itself is handed back to you; what's inside is left alone. |
| `--zsh` | Installs `zsh` + `zsh-autosuggestions` + `zsh-syntax-highlighting`, makes it your login shell, and deploys `.zshrc`: the `adam1` prompt with the full hostname, shared history, menu completion, and the NIVROKU banner from `~/NivrokuGreeter.txt` once per boot if that file exists. |
| `--tools` | Finishes any half-configured packages (`dpkg --configure -a`), then `apt update && full-upgrade` (kernel included), plus `fastfetch` (the latest arm64 `.deb` from its GitHub releases), `sysbench`, `btop`, `flashrom`, and the Ookla Speedtest CLI. Waits for unattended-upgrades first if it's busy, and prints a heads-up whenever the upgrade changes the kernel. |
| `--sudo` | Passwordless `sudo` for the invoking user, via a `/etc/sudoers.d/` drop-in that's syntax-validated with `visudo -c` *before* it's ever installed. |
| `--github-ssh` | Generates (or reuses) an `ed25519` SSH key for this board and prints the public key with the steps to add it to GitHub. Never touches GitHub itself. Always routes `github.com`'s SSH over GitHub's port 443 (`ssh.github.com`), which gets through networks that block port 22, so `git@github.com:…` remotes work on any network. Safe to re-run any time just to get the public key back on screen. |

### Boot root

At most one per run. It always runs after the setup stages.

| Flag | What it does |
|------|--------------|
| `--nvme-switch` | Copies this eMMC root onto the NVMe — partitioning and formatting the drive if needed — and boots the NVMe root from the next boot on. The last thing to do on the eMMC root: reboot right after it. See [Moving to the NVMe](#moving-to-the-nvme). |
| `--emmc-rollback` | Boots the eMMC root again and turns the NVMe's boot sync off. See [Going back to the eMMC](#going-back-to-the-emmc). |
| `--status` | Shows which root is running, where the next boot goes, and the state of the boot sync. Changes nothing. |

### Modifiers

| Flag | What it does |
|------|--------------|
| `-n`, `--dry-run` | `--nvme-switch` / `--emmc-rollback` check everything and change nothing. Refused next to setup stages: they have no dry-run mode and would change the board for real. |
| `-y`, `--yes` | Skips the y/N question of `--nvme-switch` / `--emmc-rollback`. Never skips the typed `yes` asked before overwriting data already on the NVMe. |
| `--reboot` | Reboots once the run has finished successfully. Never after a dry run, a declined confirmation or a failure. |
| `-h`, `--help` | Shows the flag list and exits. |

Flags also work without the leading `--` (`nvme-switch` is the same as
`--nvme-switch`). `-n`, `-y` and `--reboot` only modify a run: on their
own they aren't one, and the script says so.

## Examples

```bash
./ArduinoVentunoQ_QuickStart.sh                                 # numbered list, pick what to run
./ArduinoVentunoQ_QuickStart.sh --code-dir --zsh --tools --sudo --github-ssh --nvme-switch --reboot
                                                                # fresh flash: set up, move to the NVMe, boot it
./ArduinoVentunoQ_QuickStart.sh --tools                         # just the packages
./ArduinoVentunoQ_QuickStart.sh --zsh --github-ssh              # any combination of setup stages
./ArduinoVentunoQ_QuickStart.sh --github-ssh                    # print this board's GitHub key again
./ArduinoVentunoQ_QuickStart.sh --status                        # where does the next boot go?
./ArduinoVentunoQ_QuickStart.sh --nvme-switch --dry-run         # check the move, change nothing
./ArduinoVentunoQ_QuickStart.sh --nvme-switch --reboot          # move to the NVMe, reboot into it
./ArduinoVentunoQ_QuickStart.sh --emmc-rollback -y --reboot     # back to the eMMC, no y/N
```

## Moving to the NVMe

The VENTUNO Q loads GRUB, the kernel and the initrd from the eMMC — GRUB
can't read the NVMe — so the eMMC stays part of every boot. What moves to
the NVMe is the root filesystem: the eMMC's `grub.cfg` decides whether
the kernel mounts the eMMC root (`/dev/mmcblk0p71`) or the NVMe root
(`/dev/nvme0n1p1`).

Run from the eMMC root, `--nvme-switch` does the whole move:

1. **Checks, changing nothing:** what's on the NVMe drive, room for the
   copy, the `grub.cfg` the NVMe root will boot with, and that the
   default kernel can mount an NVMe root at all — NVMe driver built in,
   or in its initramfs. `--dry-run` stops here.
2. **Asks** — what depends on what's on the drive; see the table below.
3. **Holds the eMMC root still:** stops Docker and the automatic apt runs
   (`apt-daily.timer`, `apt-daily-upgrade.timer`) and waits out any apt
   that's already running, so nothing changes under the copy.
4. **Prepares the drive:** a blank (or wiped) drive gets one GPT
   partition across the whole drive, formatted ext4 and labelled
   `nvme-root`. An NVMe root from an earlier switch is reused in place,
   keeping its filesystem and UUID.
5. **Copies the eMMC root filesystem onto it** with `rsync -aHAXx` —
   hard links, ACLs, xattrs and file capabilities included — in two
   passes, checks what still differs, and points the copy's `/etc/fstab`
   at the NVMe.
6. **Switches the boot:** every kernel line in the eMMC `grub.cfg` gets
   `root=UUID=<NVMe> rootdelay=30`, every `search` line keeps the eMMC's
   UUID, and the NVMe root gets what keeps it bootable — see
   [Keeping the NVMe root bootable](#keeping-the-nvme-root-bootable).

| The NVMe holds | What `--nvme-switch` does | Confirmation |
|----------------|---------------------------|--------------|
| Nothing (blank drive) | Partitions, formats, copies | y/N — `-y` skips it |
| An interrupted copy from an earlier run | Finishes the copy | y/N — `-y` skips it |
| The NVMe root from an earlier switch | Copies over it in place; files that exist only on the NVMe are deleted | typed `yes` — `-y` never skips it |
| Anything else — other partitions, other filesystems, a block-level copy carrying the eMMC's UUID | Wipes the whole drive, then as for a blank one | typed `yes` — `-y` never skips it |

### It's the last thing you do on the eMMC root

The NVMe root is a copy of the eMMC root *as of the switch*. Anything
installed, updated or changed on the eMMC root afterwards never reaches
the NVMe — and a kernel or GRUB upgrade there runs `update-grub`, which
points the next boot straight back at the eMMC. So:

- `--nvme-switch` always runs after every setup stage in the same run,
  and the run ends with a warning to reboot now. Give `--reboot` and it
  reboots by itself.
- Docker and the automatic apt runs stay stopped until that reboot.
- Until the reboot, the script refuses to run setup stages on the eMMC
  root: it sees that the next boot already goes to the NVMe and tells you
  to reboot and run them there. `--status` and `--emmc-rollback` still
  work, and `--emmc-rollback` cancels the switch.

After the reboot, check where you are:

```bash
findmnt -n -o SOURCE /                       # /dev/nvme0n1p1
./ArduinoVentunoQ_QuickStart.sh --status
```

### What's copied, and what isn't

The root filesystem, all of it — read through a **read-only bind mount of
`/`**, which shows the root filesystem on its own. Whatever is mounted
over it (`/proc`, `/run`, `/boot/efi`, a USB stick) isn't copied, and
nothing can write to the eMMC through it. Mount points come across as
empty folders.

Other eMMC partitions this root mounts — the ESP at `/boot/efi`, say —
aren't copied: the NVMe root's `fstab` is a copy of this one, so it keeps
mounting them from the eMMC. The run lists them. If your image keeps
`/home` on a partition of its own, that's one of them, and both roots
share it.

### Safety nets

- **Nothing is written before the checks pass and you've confirmed.** It
  refuses outright if the NVMe is in use (mounted, active swap,
  LVM/RAID/crypt), too small, or if the default kernel has no NVMe driver
  either built in or in its initramfs.
- **The boot only changes once the copy is complete.** If the copy is cut
  short — Ctrl+C, a power cut, an `rsync` error — the board still boots
  the eMMC, Docker and the apt timers come back, and the next
  `--nvme-switch` finds the unfinished copy and carries on with it.
- **It won't switch to a copy that's still moving.** If more than 500
  paths still differ after two passes, something keeps writing to the
  eMMC root: it stops, and re-running after you've stopped the writer
  resumes the copy.
- **`grub.cfg` changes are checked and reversible.** Every rewrite is
  verified before it's written and again after, swapped in atomically,
  and the previous file is backed up to `/var/backups/ventuno-boot/` on
  the eMMC root — and restored automatically if the second check fails.

Run `--nvme-switch` from the NVMe root and it copies nothing (that root is
in use); it only re-applies the boot config.

## Keeping the NVMe root bootable

GRUB keeps loading the kernel and initrd from the eMMC's `/boot`, but
kernel upgrades now happen on the NVMe root. `--nvme-switch` installs
three things on the NVMe root so the two stay in step:

- **The boot sync** — `/usr/local/sbin/sync-boot-emmc`, run by an apt
  hook (`/etc/apt/apt.conf.d/99-sync-boot-emmc`) after every dpkg run and
  by `sync-boot-emmc.service` at shutdown and reboot. It mirrors the NVMe
  `/boot` to the eMMC — new files first, `grub.cfg` swapped in
  atomically, stale files deleted last — writes the eMMC copy of
  `grub.cfg` with the eMMC's UUID on its `search` lines, and refuses to
  sync a config that wouldn't boot the NVMe root.
- **A GRUB drop-in** — `/etc/default/grub.d/zz-nvme-root.cfg` adds
  `root=UUID=<NVMe> rootdelay=30` to the kernel command line, so
  `update-grub` on the NVMe root keeps pointing at it. `rootdelay` gives
  the NVMe time to show up before the initramfs looks for the root.
- **A guard for GRUB upgrades** — a GRUB package upgrade runs
  `grub-install`, which points the ESP's stub `grub.cfg` at the
  filesystem holding `/boot`: the NVMe, which GRUB can't see. The sync
  script points it back at the eMMC. It only ever touches a stub that
  names the NVMe.

`--status` shows whether the sync's shutdown unit, apt hook and script
are in place and current.

## Going back to the eMMC

```bash
./ArduinoVentunoQ_QuickStart.sh --emmc-rollback --reboot
```

`--emmc-rollback` points every kernel line of the eMMC `grub.cfg` back at
the eMMC root (dropping `rootdelay`), copies in the kernel modules the
eMMC root lacks for kernels that came over from the NVMe, and turns the
boot sync on the NVMe root off. It works from either root.

It doesn't copy the NVMe root back: you get the eMMC root as it was when
`--nvme-switch` copied it, plus any newer kernels the sync brought over.
After booting it, regenerate its `grub.cfg` from its own packages:

```bash
findmnt -n -o SOURCE /                       # /dev/mmcblk0p71
sudo update-grub 2>&1 | grep -v 'improperly nested'
```

Running `--nvme-switch` again later copies the eMMC root over the NVMe
root again — whatever changed on the NVMe root since is lost, which is
why that case asks for the typed `yes`.

## Checking where the next boot goes

```
$ ./ArduinoVentunoQ_QuickStart.sh --status
[2026-11-22 10:15:02] Running: ArduinoVentunoQ_QuickStart.sh --status
[2026-11-22 10:15:02] Starting stage 'status' -- Show where the next boot goes and the boot-sync state
[2026-11-22 10:15:03] Boot status
    Running root : /dev/nvme0n1p1
    eMMC root    : /dev/mmcblk0p71  (UUID 8c1e5f2a-…)
    NVMe root    : /dev/nvme0n1p1  (UUID 3f9a0b6d-…)
    Next boot    : (eMMC grub.cfg; the last root= on each kernel line wins)
      5 kernel entries -> NVMe root
    Boot sync    : shutdown unit on, apt hook on, script executable, current
[2026-11-22 10:15:03] Finished stage 'status' in 1s
```

## Why some of this exists

- **There's no default run** — and no `--only`/`--skip` either. On a board
  where one flag can wipe a drive, nothing runs unless you named it.
  Every stage has its own flag, and a fresh board's full setup is one
  explicit command line.
- **`--nvme-switch` is a full copy, not just a boot switch.** That way the
  NVMe root is always exactly the system you've just set up — the
  fresh-board command above ends with that system booted from the NVMe —
  rather than whatever was left on the drive from before.
- **A typed `yes` for data, a y/N for the rest.** A destructive step must
  never be confirmed by default, so `-y` covers a blank drive or a
  rollback, but replacing or wiping what's already on the NVMe always
  needs someone at the terminal typing `yes` — and fails closed when
  there's no terminal.
- **The boot actions re-run the script under `sudo`** instead of putting
  `sudo` in front of every line: they mount both roots, rewrite
  `grub.cfg` and run `systemctl --root`, all of it root work. The re-run
  does only the boot action and logs into the same run log.
- **`--tools` upgrades the kernel.** No holds: the kernel comes from the
  image's own apt sources, built for this SoC, and on the NVMe root the
  boot sync carries each new kernel over to the eMMC `/boot` that GRUB
  loads from. `--tools` still prints a heads-up whenever an upgrade
  changes the kernel, so it's the first thing you think of if hardware
  behaves differently afterwards.
- **`--tools` falls back to Ookla's Ubuntu 22.04 build of `speedtest`.**
  Ookla stopped publishing before Ubuntu 24.04: their packagecloud repo
  sets itself up for `noble`, but has no `speedtest` package there. The
  binary is static, so on an Ubuntu release with no candidate the stage
  points the repo at `jammy` instead.
- **The package stages wait for unattended-upgrades.** Ubuntu runs it soon
  after boot — a fresh board's first boot especially — and while `apt`
  waits 120 s for the package locks, `dpkg` and `apt-get` don't wait at
  all. The stages wait up to 15 minutes instead of failing.
- **`--sudo` grants full passwordless access, deliberately.** This is
  written for a single-technician, physically-controlled lab board, not a
  shared or internet-facing system — anyone with physical access to a
  board here can already do far more than "run a command as root." If you
  reuse this script on a different kind of deployment, reconsider this
  stage specifically.
- **`--github-ssh` generates a passphrase-free key, on purpose.** Same
  reasoning as the `--sudo` stage: a passphrase prompt on every
  `git fetch` is friction without a matching benefit here. Only the public
  key is ever printed or logged.

## Extending it

Every setup stage is a self-contained `stage_<name>()` function with its
own `local` variables, so adding one doesn't risk colliding with any other
stage's state. To add a stage:

1. Write `stage_<name>()` near the others in the script.
2. Add its id to the `SETUP_STAGE_IDS` array, in the position you want it
   to run.
3. Add one line each to the `STAGE_DESCRIPTIONS` and `STAGE_FUNCS`
   associative arrays.

Its `--<id>` flag, its number in the no-flags list, `--help` and the
runner all pick it up from there — nothing else to wire up. It always runs
before the boot-root action.

For any stage that writes a file, use the existing `write_if_changed`
helper instead of writing directly: it only touches the file (with a
timestamped backup) when the content actually changed, which is what keeps
re-runs no-ops.

The script can also be `source`d — to test one function in isolation —
without starting a run.

## Known things worth knowing

- **After reflashing the eMMC,** the board boots the fresh eMMC root again
  (the flash replaces the eMMC `grub.cfg`). Set it up and run
  `--nvme-switch` to copy the new system over the old NVMe root — that
  asks for the typed `yes`, since the old NVMe root gets replaced.
- Try `--nvme-switch --dry-run` first on a new board: it shows what's on
  the NVMe, the plan, the space check and the NVMe-driver check.
- After `--nvme-switch`, Docker and the automatic apt runs stay stopped
  until you reboot.
- The very first real `speedtest` run needs interactive license
  acceptance. Non-interactively: `speedtest --accept-license --accept-gdpr`.
- `--github-ssh` doesn't add the key to GitHub for you — copy the printed
  public key to <https://github.com/settings/ssh/new> yourself, then
  verify with `ssh -T git@github.com`. It also adds a small managed block
  to `~/.ssh/config` (`StrictHostKeyChecking accept-new` for `github.com`)
  so that first connection doesn't hang on a host-key prompt; anything
  else already in that file is left untouched.
- Some networks block outbound SSH on port 22: `git clone git@github.com:…`
  then hangs and ends in `ssh: connect to host github.com port 22:
  Connection timed out`. That's the network, not your key — a key problem
  gets connected first and then fails with `Permission denied (publickey)`.
  So `--github-ssh` always adds a second managed block sending `github.com`
  to `ssh.github.com` port 443, GitHub's official SSH-over-HTTPS-port
  endpoint, which works on any network that allows HTTPS. A route like that
  you've set up by hand is detected and left alone. If your own
  `github.com` settings earlier in `~/.ssh/config` set a `HostName` or
  `Port`, they win (ssh takes the first value it finds), and the stage
  warns you.
- Keep the script's line endings as LF. A copy saved with Windows (CRLF)
  line endings won't run under bash at all.
- Full log of each run: `~/.ventuno-q-deploy/logs/` (`--tools` also keeps
  its apt output there, as `updates.log`). `grub.cfg` backups go to
  `/var/backups/ventuno-boot/` on the eMMC root; the NVMe root keeps its
  own pre-switch config there too, as `grub.cfg.nvme.*`.

## License

MIT — see [LICENSE](LICENSE).
