# SunairiesOS

<p align="center"><img src="SunairiesOS.jpg" alt="SunairiesOS" width="256"></p>

SunairiesOS is Debian stable without systemd, as an immutable system.

- **Init:** [SystemG (System Generic)](https://github.com/augo23/systemg)
  replaces systemd, with dinit as PID 1. Debian's packages, unit files,
  `systemctl` and D-Bus clients keep working unchanged.
- **Updates:** the root filesystem is a stack of read-only layers. Updates
  arrive as OCI images and are applied as a whole, and the previous version
  stays bootable.
- **apt:** `apt`, `apt-get`, `dpkg` and the graphical software centres (KDE
  Discover, GNOME Software, Synaptic) work exactly as on Debian. Each change
  they make becomes a new read-only version.

This repository holds the parts that do that, on top of plain Debian:

| Directory | What it is |
|---|---|
| `systemg/` | Files SystemG adds to Debian (paths as installed): the dinit services that boot the system, the apt pin that keeps systemd out, and the glue that stands in for systemd's own pieces |
| `elogind/` | Debian's elogind, rebuilt with one patch (`session-by-scope.patch`) |
| `eudev/` | eudev built from Alpine Linux's recipe, packaged as Debian's `udev` and `libudev1` |
| `sunairies/` | The immutable layer: `sunairies-*` tools, the apt/dpkg wrapper, and the initramfs that assembles the root |

The SystemG programs themselves (`systemctl`, the unit translator,
`libsystemd` shim, D-Bus service) are in the
[systemg](https://github.com/augo23/systemg) repository.

## What changes in Debian

Everything not listed here is Debian, unchanged: the same packages from
`deb.debian.org`, the same versions, maintainer scripts and configuration
files.

### 1. No systemd: SystemG on dinit

**Packages from systemd's source are never installed.**
`systemg/etc/apt/preferences.d/systemg` pins every one of them to priority -1,
as Devuan does. That covers `systemd`, `systemd-sysv`, `libpam-systemd`,
`udev`, `libudev1`, `systemd-resolved`, `systemd-timesyncd` and the rest, so
apt cannot pull them back in through any dependency. Two kinds are still
allowed:
- `libsystemd0`, the client library many programs link to; SystemG answers
  its calls;
- the standalone `systemd-sysusers` and `systemd-tmpfiles` tools that
  packages call while they install.

**PID 1 is dinit.** The kernel starts `/usr/bin/dinit`, which runs the services in
`systemg/etc/dinit.d/`:
- `early` mounts `/proc`, `/sys`, `/dev` and `/run`, as systemd does before
  `sysinit.target`;
- `sysinit` brings up local filesystems and `udevd`;
- `boot` is the default target (systemd's `multi-user.target`); services you
  enable are linked into `boot.d/`.

**Debian's unit files are translated, not rewritten.** `systemctl` is SystemG's.
`systemctl daemon-reload` reads every `.service`, `.socket` and `.target`
unit Debian's packages ship and writes the matching dinit service. It's run
after every package change, the way systemd's packaging hooks run it
(`systemg/etc/apt/apt.conf.d/80systemg`, `systemg/usr/libexec/systemg/apt-hook`).
`systemctl enable/disable/start/stop/status` act on those services, and
`deb-systemd-helper` and `deb-systemd-invoke` work unmodified.

**`invoke-rc.d` and `service`** are diverted with `dpkg-divert`, Debian's own
mechanism, to SystemG's `systemg/usr/libexec/systemg/invoke-rc.d`. That way,
maintainer scripts start a daemon through dinit, not a second copy of it.

**`Type=notify` daemons** (`sd_notify`) are started under `sg-notify-proxy`,
which relays `READY=1` to dinit's readiness pipe. `elogind` is one of them
(`systemg/etc/dinit.d/elogind`).

**D-Bus:**
- `org.freedesktop.systemd1` is answered by `compatd`
  (`systemg/etc/dinit.d/compatd`,
  `systemg/usr/share/dbus-1/system.d/org.freedesktop.systemd1.conf`), so
  programs that ask systemd over D-Bus get answers.
- D-Bus activation goes through dinit (`systemg/usr/libexec/systemg/dbus-activate`),
  as `SystemdService=` does under systemd.

**Per-user services** (`systemd --user`):
- At login, `pam_exec` starts SystemG's per-user manager
  (`systemg/usr/share/pam-configs/systemg-user`,
  `systemg/usr/libexec/systemg/user-session`, `user-manager`).
- It provides the session bus at `$XDG_RUNTIME_DIR/bus`, as
  `dbus-user-session` does with systemd
  (`systemg/etc/X11/Xsession.d/20systemg_user-bus`).
- It runs the user units that desktops rely on: PipeWire, WirePlumber,
  portals and GNOME's services.

**logind is elogind, patched** (`elogind/`). Debian's elogind places each
session in `user.slice/user-UID.slice/session-ID.scope`, but it never
registers that scope. So it finds the session only for the session's leader,
and every other process in it gets `NoSessionForPID`. Then a rootless Xorg or
gnome-shell can't get the screen and keyboard. The patch looks the session up
by the ID in the scope's name. `build-elogind` builds Debian's own source
package with it, and the result is held (`apt-mark hold`), so a Debian update
can't bring the bug back.

**udev is eudev** (`eudev/`). Debian's `udev` and `libudev1` are built from
systemd's source tree. `build-eudev` builds eudev from Alpine Linux's package
recipe, with Alpine's version, patches and checksums, as Debian packages. They
`Provide` `udev` and `libudev1` at Debian's versions, so everything that
depends on them installs unchanged. The initramfs hooks are the same ones
Debian's udev ships.

**podman** runs without systemd: cgroups are managed directly, and events and
logs go to files (`sunairies/etc/containers/containers.conf.d/50-sunairies.conf`).

### 2. An immutable root filesystem

The disk has an EFI system partition (GRUB) and one ext4 partition labelled
`sunairies-data`:

| On `sunairies-data` | What it is |
|---|---|
| `sunairies/layers/<sha256>.erofs` | one read-only erofs image per layer, shared between versions |
| `sunairies/versions/<id>/` | one bootable system: its list of layers, kernel, initramfs, origin |
| `sunairies/grubenv` | `current`, `staged`, `tried`: the only state GRUB reads |
| `etc/`, `var/` | this machine's writable layers over the image's `/etc` and `/var` |
| `home/`, `root/`, `containers/` | user data and podman's storage |

**Assembling the root.** The initramfs (`sunairies/initramfs-tools/`,
`boot=sunairies`) builds the root at every start:
- It mounts each layer with erofs and stacks them read-only with overlayfs as
  `/`.
- It puts this machine's writable layers over `/etc` and `/var`, and mounts
  `/home`, `/root` and `/var/lib/containers` from the data partition.
- `/usr` stays read-only. Over it sits one more layer, emptied at every start,
  where `sunairies-apply` writes what apt installs, so new programs work right
  away.
- The package database (`/var/lib/dpkg`) always comes from the version, never
  from the machine's `/var`.

**Updates** (`sunairies-update`):
1. `sunairies-fetch` pulls the new OS image with podman and converts only the
   layers not on the disk yet to erofs.
2. The packages you added with apt are installed onto it again, as a new
   layer.
3. `sunairies-stage` stages the result for the next start.

**Rollback:**
- GRUB boots a staged version once.
- If that boot is healthy (`sunairies-check`: the boot target and the display
  manager came up), `sunairies-commit` makes it current and removes older
  versions and unused layers.
- If not, the next start goes back to the current version.
- `sunairies-rollback` drops a staged version by hand.

### 3. apt, unchanged in use, on an immutable system

`apt`, `apt-get` and `dpkg` are Debian's, renamed to `apt.debian`,
`apt-get.debian` and `dpkg.debian` with `dpkg-divert`. In their place is one
small wrapper (`sunairies/lib/apt`) that makes a single decision: does this
command change the installed system?

- **No** (`search`, `show`, `policy`, `update`, `download`, `dpkg -l`, ...):
  Debian's tool runs directly.
- **Yes** (`install`, `remove`, `upgrade`, `full-upgrade`, `dpkg -i`, ...):
  the same command, with the same arguments, runs through `sunairies-layer`.

**`sunairies-layer`** mounts the current version's layers with an empty
writable layer on top, and runs the command in it with `podman run --rootfs`.
That's Debian's own resolver, prompts, debconf questions and maintainer
scripts. What the command changes becomes one more erofs layer: a new version,
staged for the next start. `sunairies-apply` writes its `/usr` changes into
the running system at once, as dpkg would. Programs start right away, and
desktops show the new applications, icons and file types immediately. The
names of the packages you installed or removed are kept in
`/etc/sunairies/packages`, and every OS update installs them again.

**Programs that use apt's library instead of the command.** PackageKit (so KDE
Discover and GNOME Software), Synaptic and unattended-upgrades work out the
change themselves, then run dpkg several times. apt's own hooks (`DPkg::Pre-Invoke` and
`DPkg::Post-Invoke`, `sunairies/etc/apt/apt.conf.d/80sunairies`) and the
dpkg wrapper send all of those dpkg runs into one writable layer
(`sunairies-txn begin`, `dpkg`, `end`). At the end, that layer becomes a new
version the same way. If the change didn't finish (dpkg failed, the program
was killed), it is dropped and nothing changed.

**Accounts.** Packages create system users (`sddm`, `colord`, ...), but the
machine's own `/etc/passwd`, which holds your users, sits on top of each
version's copy and would hide them. Package changes therefore run with the
machine's real accounts, so packages see the users and groups the machine
has, with their IDs, and new ones get free IDs. The accounts a change creates
go into the machine's `/etc` as well. The layer itself keeps only system
accounts, never your users or their passwords (`sunairies/lib/sunairies.sh`).

**Default applications.** Debian chooses the default browser with an
alternative (`x-www-browser`: Firefox ESR above Konqueror and Chromium), but
desktops don't read alternatives. Without a `mimeapps.list`, each desktop
picks whichever browser it finds first, and that changes as packages come and
go. `sunairies/lib/default-apps` writes Debian's choice to
`/usr/share/applications/mimeapps.list` after every package change, for every
desktop. A choice you make yourself still comes first.

**tasksel.** Debian's "standard system utilities" task installs every package
of standard priority or higher that isn't installed yet. That includes
`systemd-sysv` and `init`, which would bring systemd or another init system
back. SunairiesOS diverts Debian's task list, again with `dpkg-divert`, and
gives that task its own package list (`sunairies/lib/tasksel-standard`):
Debian's, less what SystemG replaces.

## License

GPL-3.0 (see `LICENSE`).
